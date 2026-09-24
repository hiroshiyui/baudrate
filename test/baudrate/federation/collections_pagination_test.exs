defmodule Baudrate.Federation.CollectionsPaginationTest do
  @moduledoc """
  Phase 8D: the ActivityPub collections page by row id (`?page=true`, then
  `max_id`, or `min_id` for replies), still answer the older `?page=N`, and
  list in the order they claim.

  The user outbox claimed newest-first and served oldest-first: its query
  joined boards with `distinct: a.id`, and Ecto's `DISTINCT ON (a.id)` puts
  `a.id` first in the `ORDER BY`, which replaced the requested order.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.{Content, Federation}
  alias Baudrate.Federation.{Collections, Follower, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    board =
      %Content.Board{}
      |> Content.Board.changeset(%{
        name: "Federated",
        slug: "pg-#{System.unique_integer([:positive])}",
        min_role_to_view: "guest",
        ap_enabled: true
      })
      |> Repo.insert!()

    %{board: board, user: BaudrateWeb.ConnCase.setup_user("user")}
  end

  defp post(user, board, n) do
    for i <- 1..n do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Article #{i}",
            body: "Body #{i}",
            slug: "pg-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      article
    end
  end

  # Follows `next` from `?page=true` to the end, returning every item.
  defp walk(fetch, first_params \\ %{"page" => "true"}, acc \\ []) do
    page = fetch.(first_params)
    acc = acc ++ page["orderedItems"]

    case page["next"] do
      nil ->
        acc

      next ->
        params = next |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
        walk(fetch, params, acc)
    end
  end

  defp remote_actor do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/r#{uid}",
      username: "r#{uid}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/r#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()
  end

  describe "the user outbox" do
    test "lists newest first", %{board: board, user: user} do
      articles = post(user, board, 3)
      page = Collections.user_outbox(user, %{"page" => "true"})

      assert Enum.map(page["orderedItems"], & &1["object"]["name"]) ==
               articles |> Enum.reverse() |> Enum.map(& &1.title)
    end

    test "walks every article once by max_id", %{board: board, user: user} do
      articles = post(user, board, 25)

      first = Collections.user_outbox(user, %{"page" => "true"})
      assert length(first["orderedItems"]) == 20
      assert first["next"] =~ "?page=true&max_id="

      items = walk(&Collections.user_outbox(user, &1))
      assert length(items) == 25

      assert Enum.map(items, & &1["object"]["name"]) ==
               articles |> Enum.reverse() |> Enum.map(& &1.title)
    end

    test "the root counts what the pages list, and links the keyset page", %{
      board: board,
      user: user
    } do
      post(user, board, 3)
      root = Collections.user_outbox(user)

      assert root["totalItems"] == 3
      assert root["first"] =~ "/outbox?page=true"
    end

    test "still answers ?page=N, in the same order", %{board: board, user: user} do
      articles = post(user, board, 22)
      page2 = Collections.user_outbox(user, %{"page" => "2"})

      assert page2["id"] =~ "?page=2"
      assert page2["prev"] =~ "?page=1"
      refute Map.has_key?(page2, "next")

      assert Enum.map(page2["orderedItems"], & &1["object"]["name"]) ==
               articles |> Enum.take(2) |> Enum.reverse() |> Enum.map(& &1.title)
    end

    test "a cursor that is not a positive id serves the first page", %{board: board, user: user} do
      post(user, board, 2)

      for bad <- ["abc", "-1", "0", "1e3", "99999999999999999999999"] do
        page = Collections.user_outbox(user, %{"page" => "true", "max_id" => bad})
        assert length(page["orderedItems"]) == 2, "max_id=#{bad}"
        assert page["id"] =~ ~r/\?page=true\z/
      end
    end

    test "an out-of-range ?page=N is an empty page, not an error", %{board: board, user: user} do
      post(user, board, 1)

      for page <- ["99999999999999999999", "1000001"] do
        result = Collections.user_outbox(user, %{"page" => page})
        assert result["orderedItems"] == []
        assert result["id"] =~ "?page=#{Baudrate.Pagination.max_page()}"
      end

      assert Collections.board_outbox(board, %{"page" => "99999999999999999999"})[
               "orderedItems"
             ] == []
    end

    test "is empty for a banned account", %{board: board, user: user} do
      post(user, board, 2)
      user = %{user | status: "banned"}

      assert Collections.user_outbox(user, %{"page" => "true"})["orderedItems"] == []
      assert Collections.user_outbox(user)["totalItems"] == 0
    end
  end

  test "the board outbox walks every arrival once, newest first", %{board: board, user: user} do
    articles = post(user, board, 23)
    items = walk(&Collections.board_outbox(board, &1))

    assert Enum.map(items, & &1["object"]) ==
             articles
             |> Enum.reverse()
             |> Enum.map(&Federation.actor_uri(:article, &1.slug))
  end

  test "followers walk once, newest first, and a pending request is not one", %{user: user} do
    actor_uri = Federation.actor_uri(:user, user.username)

    uris =
      for i <- 1..22 do
        ra = remote_actor()

        %Follower{}
        |> Follower.changeset(%{
          actor_uri: actor_uri,
          follower_uri: ra.ap_id,
          remote_actor_id: ra.id,
          activity_id: "https://remote.example/follows/#{i}-#{ra.id}",
          accepted_at: DateTime.utc_now(:second)
        })
        |> Repo.insert!()

        ra.ap_id
      end

    pending = remote_actor()

    %Follower{}
    |> Follower.changeset(%{
      actor_uri: actor_uri,
      follower_uri: pending.ap_id,
      remote_actor_id: pending.id,
      activity_id: "https://remote.example/follows/pending-#{pending.id}"
    })
    |> Repo.insert!()

    assert walk(&Collections.followers_collection(actor_uri, &1)) == Enum.reverse(uris)
  end

  test "a user's following lists remote and local follows in one order", %{user: user} do
    ra = remote_actor()
    {:ok, remote_follow} = Federation.create_user_follow(user, ra)
    Federation.accept_user_follow(remote_follow.ap_id)

    other = BaudrateWeb.ConnCase.setup_user("user")
    {:ok, _local} = Federation.create_local_follow(user, other)

    actor_uri = Federation.actor_uri(:user, user.username)
    page = Collections.following_collection(actor_uri, %{"page" => "true"})

    assert page["orderedItems"] == [Federation.actor_uri(:user, other.username), ra.ap_id]
  end

  describe "replies" do
    setup %{board: board, user: user} do
      [article] = post(user, board, 1)
      %{article: article}
    end

    test "read oldest first and continue by min_id", %{article: article, user: user} do
      comments =
        for i <- 1..23 do
          {:ok, c} =
            Content.create_comment(%{
              "body" => "comment #{i}",
              "article_id" => article.id,
              "user_id" => user.id
            })

          c
        end

      root = Collections.article_replies(article)
      assert root["totalItems"] == 23
      assert root["first"] =~ "/replies?page=true"
      refute Map.has_key?(root, "orderedItems")

      first = Collections.article_replies(article, %{"page" => "true"})
      assert first["next"] =~ "?page=true&min_id="

      items = walk(&Collections.article_replies(article, &1))
      assert Enum.map(items, & &1["content"]) == Enum.map(comments, & &1.body_html)
    end

    test "an old ?page=N is answered as the first page", %{article: article} do
      page = Collections.article_replies(article, %{"page" => "3"})
      assert page["id"] =~ ~r/\?page=true\z/
    end
  end
end
