defmodule Baudrate.Content.ArticleMoveTest do
  @moduledoc """
  Acceptance gate for moving articles between boards (Phase 7C, ADR 0075):
  who may move one, what each move publishes, emptying a board so it can be
  deleted, and ordering boards without typing a number.
  """

  use Baudrate.DataCase, async: false

  import BaudrateWeb.ConnCase, only: [setup_user: 1]

  alias Baudrate.{Content, Federation}
  alias Baudrate.Content.{Article, Board}
  alias Baudrate.Federation.{DeliveryJob, KeyStore, RemoteActor}

  defp uid, do: System.unique_integer([:positive])

  defp board(attrs) do
    id = uid()
    Repo.insert!(Board.changeset(%Board{}, Map.merge(%{name: "B#{id}", slug: "b-#{id}"}, attrs)))
  end

  defp remote_actor do
    id = uid()

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/r#{id}",
      username: "r#{id}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/r#{id}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()
  end

  defp followed_by_remote(board) do
    remote = remote_actor()

    {:ok, _} =
      Federation.create_follower(
        Federation.actor_uri(:board, board.slug),
        remote,
        "https://remote.example/follows/#{uid()}"
      )

    remote
  end

  defp article(author, boards) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Moving", body: "Body", slug: "moving-#{uid()}", user_id: author.id},
        Enum.map(boards, & &1.id)
      )

    Repo.preload(article, :boards, force: true)
  end

  defp queued?(type, inbox) do
    DeliveryJob
    |> where([j], j.inbox_url == ^inbox and j.status == "pending")
    |> Repo.all()
    |> Enum.any?(&(Jason.decode!(&1.activity_json)["type"] == type))
  end

  defp board_ids(article),
    do: Repo.preload(article, :boards, force: true).boards |> Enum.map(& &1.id)

  setup do
    previous = Application.get_env(:baudrate, :federation_async)
    Application.put_env(:baudrate, :federation_async, :discard)
    on_exit(fn -> Application.put_env(:baudrate, :federation_async, previous) end)

    author = setup_user("user")
    {:ok, author} = KeyStore.ensure_user_keypair(author)
    a = board(%{})
    b = board(%{})

    %{author: author, admin: setup_user("admin"), a: a, b: b}
  end

  describe "who may move an article" do
    test "staff, or a moderator of both boards — never the author alone", ctx do
      art = article(ctx.author, [ctx.a])
      mod_of_a = setup_user("user")
      mod_of_both = setup_user("user")
      {:ok, _} = Content.add_board_moderator(ctx.a.id, mod_of_a.id)
      {:ok, _} = Content.add_board_moderator(ctx.a.id, mod_of_both.id)
      {:ok, _} = Content.add_board_moderator(ctx.b.id, mod_of_both.id)

      for nobody <- [ctx.author, mod_of_a, nil] do
        assert {:error, :unauthorized} = Content.move_article_to_board(art, ctx.a, ctx.b, nobody)
      end

      assert {:ok, moved} = Content.move_article_to_board(art, ctx.a, ctx.b, mod_of_both)
      assert board_ids(moved) == [ctx.b.id]

      global = setup_user("moderator")
      assert {:ok, _} = Content.move_article_to_board(moved, ctx.b, ctx.a, global)
    end

    test "refuses what is not a move", ctx do
      art = article(ctx.author, [ctx.a, ctx.b])
      c = board(%{})

      assert {:error, :same_board} = Content.move_article_to_board(art, ctx.a, ctx.a, ctx.admin)

      assert {:error, :already_in_board} =
               Content.move_article_to_board(art, ctx.a, ctx.b, ctx.admin)

      assert {:error, :not_in_board} = Content.move_article_to_board(art, c, ctx.b, ctx.admin)

      {:ok, deleted} = Content.soft_delete_article(art, deleted_by: ctx.admin.id)
      assert {:error, :not_found} = Content.move_article_to_board(deleted, ctx.a, c, ctx.admin)
    end
  end

  describe "what a move publishes" do
    test "into a federated board: arrives there as a forward does, and nothing is withdrawn",
         ctx do
      from_follower = followed_by_remote(ctx.a)
      to_follower = followed_by_remote(ctx.b)
      art = article(ctx.author, [ctx.a])
      Repo.delete_all(DeliveryJob)

      {:ok, _} = Content.move_article_to_board(art, ctx.a, ctx.b, ctx.admin)

      assert queued?("Create", to_follower.inbox)
      assert queued?("Announce", to_follower.inbox)
      refute queued?("Delete", from_follower.inbox)
    end

    test "a local article that stops federating is withdrawn from its old audience", ctx do
      from_follower = followed_by_remote(ctx.a)
      private = board(%{min_role_to_view: "user"})
      art = article(ctx.author, [ctx.a])
      Repo.delete_all(DeliveryJob)

      {:ok, _} = Content.move_article_to_board(art, ctx.a, private, ctx.admin)

      assert queued?("Delete", from_follower.inbox)
      refute queued?("Announce", from_follower.inbox)
    end

    test "a board that does not federate sends nothing on arrival", ctx do
      quiet = board(%{ap_enabled: false})
      follower_of_quiet = followed_by_remote(quiet)
      art = article(ctx.author, [ctx.a, ctx.b])
      Repo.delete_all(DeliveryJob)

      {:ok, _} = Content.move_article_to_board(art, ctx.a, quiet, ctx.admin)

      refute queued?("Create", follower_of_quiet.inbox)
      refute queued?("Announce", follower_of_quiet.inbox)
    end

    test "a remote article is relinked here only: never withdrawn by us", ctx do
      from_follower = followed_by_remote(ctx.a)
      remote = remote_actor()
      private = board(%{min_role_to_view: "user"})

      {:ok, %{article: art}} =
        Content.create_remote_article(
          %{
            title: "Remote",
            body: "From elsewhere",
            slug: "remote-#{uid()}",
            ap_id: "https://remote.example/articles/#{uid()}",
            remote_actor_id: remote.id
          },
          [ctx.a.id]
        )

      Repo.delete_all(DeliveryJob)

      {:ok, moved} = Content.move_article_to_board(art, ctx.a, private, ctx.admin)

      assert board_ids(moved) == [private.id]
      refute queued?("Delete", from_follower.inbox)
      refute queued?("Update", from_follower.inbox)
    end
  end

  describe "move_board_articles/3" do
    test "empties a board so it can be deleted", ctx do
      one = article(ctx.author, [ctx.a])
      both = article(ctx.author, [ctx.a, ctx.b])
      gone = article(ctx.author, [ctx.a])
      {:ok, _} = Content.soft_delete_article(gone, deleted_by: ctx.admin.id)

      assert {:error, :has_articles} = Content.delete_board(ctx.a)
      assert {:error, :unauthorized} = Content.move_board_articles(ctx.a, ctx.b, ctx.author)

      assert {:ok, 3} = Content.move_board_articles(ctx.a, ctx.b, ctx.admin)

      for art <- [one, both, gone], do: assert(board_ids(art) == [ctx.b.id])
      assert {:ok, _} = Content.delete_board(ctx.a)
    end
  end

  describe "move_board/2" do
    test "swaps a board with its neighbour among its siblings only", ctx do
      parent = board(%{})
      [x, y, z] = for _ <- 1..3, do: board(%{parent_id: parent.id})

      # All three were appended in order.
      assert Enum.map(Content.list_sub_boards(parent), & &1.id) == [x.id, y.id, z.id]

      assert :ok = Content.move_board(z, :up)
      assert Enum.map(Content.list_sub_boards(parent), & &1.id) == [x.id, z.id, y.id]

      assert {:error, :at_edge} = Content.move_board(x, :up)
      assert {:error, :at_edge} = Content.move_board(Repo.reload(y), :down)

      # A top-level board is not one of parent's children.
      refute ctx.a.id in Enum.map(Content.list_sub_boards(parent), & &1.id)
    end

    test "boards that shared a position still move", _ctx do
      parent = board(%{})
      p = board(%{parent_id: parent.id, position: 5})
      q = board(%{parent_id: parent.id, position: 5})

      assert Enum.map(Content.list_sub_boards(parent), & &1.id) == [p.id, q.id]
      assert :ok = Content.move_board(q, :up)
      assert Enum.map(Content.list_sub_boards(parent), & &1.id) == [q.id, p.id]
    end
  end

  test "an article is never left in no board by a move", ctx do
    art = article(ctx.author, [ctx.a])
    {:ok, moved} = Content.move_article_to_board(art, ctx.a, ctx.b, ctx.admin)
    assert %Article{} = moved
    assert board_ids(moved) != []
  end
end
