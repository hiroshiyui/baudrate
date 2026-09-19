defmodule Baudrate.Federation.ObjectIdentityTest do
  @moduledoc """
  Acceptance gate for [ADR 0050](../../../doc/adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md):
  every AP object this instance mints has a URI a remote server can actually
  dereference, and the URI a peer already learned keeps working.

  Comments were stamped `<actor>#note-N` and polls `<article-uri>#poll`. A
  fragment never leaves the client, so both dereferenced to something else
  entirely — the Person document and the Article — and no peer could resolve,
  thread against or vote on either. The fix changes a **public identity**, and
  ActivityPub has no way to tell a peer that an object's id moved, so the old
  value is kept in `legacy_ap_id` and is load-bearing in both directions.

  Three properties, and each one is a way the change could have gone wrong:

    * **No new fragment ids.** A mint that goes back to `#note-N` is the
      regression, and it would be invisible until a Mastodon user tried to
      reply.
    * **The gate is the article's.** `/ap/comments/:id` is a new
      unauthenticated surface serving stored content; if it refuses less than
      `/ap/articles/:slug`, a private board's discussion leaks through it.
    * **Both ids resolve, and a withdrawal names both.** Otherwise the rewrite
      silently orphans every comment already delivered.
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.{Board, Comment, Poll}
  alias Baudrate.Federation
  alias Baudrate.Federation.{Publisher, RemoteActor}
  alias Baudrate.Repo
  alias Baudrate.Setup

  @activity_json "application/activity+json"

  setup do
    Setup.seed_roles_and_permissions()

    board = create_board()
    author = create_user()

    {:ok, %{article: article}} = create_article(author, board)
    {:ok, comment} = create_comment(article, author)
    poll = Content.get_poll_for_article(article.id)

    %{board: board, author: author, article: article, comment: comment, poll: poll}
  end

  describe "a minted id is dereferenceable" do
    test "a local comment's ap_id is a path, never a fragment", ctx do
      assert ctx.comment.ap_id == Federation.actor_uri(:comment, ctx.comment.id)

      refute String.contains?(ctx.comment.ap_id, "#"),
             "a fragment never reaches the server, so #{ctx.comment.ap_id} dereferences " <>
               "to the author's Person document and can never be threaded against"
    end

    test "a local poll's ap_id is a path, never a fragment", ctx do
      assert ctx.poll.ap_id == Federation.actor_uri(:poll, ctx.poll.id)
      refute String.contains?(ctx.poll.ap_id, "#")
    end

    test "no local comment or poll on file carries a fragment id" do
      # Cheap because the fixtures above are the whole table, but it is the
      # property the backfill exists to establish, stated as a property.
      for %{ap_id: ap_id} <- Repo.all(Comment), is_binary(ap_id) do
        refute String.contains?(ap_id, "#note-"), "comment ap_id #{ap_id} is a fragment"
      end

      for %{ap_id: ap_id} <- Repo.all(Poll), is_binary(ap_id) do
        refute String.contains?(ap_id, "#poll"), "poll ap_id #{ap_id} is a fragment"
      end
    end
  end

  describe "GET /ap/comments/:id refuses what the article refuses" do
    test "serves the Note for an article in a federated board", ctx do
      body = get_ap(ctx.comment.ap_id)

      assert body["type"] == "Note"
      assert body["id"] == ctx.comment.ap_id
      assert body["attributedTo"] == Federation.actor_uri(:user, ctx.author.username)
      assert body["content"] =~ "a comment"
    end

    test "404 when the board is not guest-readable", ctx do
      {:ok, _} = Content.update_board(ctx.board, %{min_role_to_view: "user"})
      assert_not_found(ctx.comment.ap_id)
    end

    test "404 when the board has federation turned off", ctx do
      {:ok, _} = Content.update_board(ctx.board, %{ap_enabled: false})
      assert_not_found(ctx.comment.ap_id)
    end

    test "404 once the comment is soft-deleted", ctx do
      {:ok, _} = Content.soft_delete_comment(ctx.comment, deleted_by: ctx.author.id)
      assert_not_found(ctx.comment.ap_id)
    end

    test "404 for a remote comment, whose id belongs to another host", ctx do
      actor = create_remote_actor()

      {:ok, remote_comment} =
        Content.create_remote_comment(%{
          body: "from elsewhere",
          body_html: "<p>from elsewhere</p>",
          ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
          article_id: ctx.article.id,
          remote_actor_id: actor.id
        })

      # Serving it here would assert our host as the origin of somebody else's
      # Note — the identity claim ADR 0046 refuses.
      assert_not_found(Federation.actor_uri(:comment, remote_comment.id))
    end

    test "404 for an id that names no row", ctx do
      assert_not_found(Federation.actor_uri(:comment, ctx.comment.id + 100_000))
    end
  end

  describe "GET /ap/polls/:id" do
    test "serves the standalone Question with the same id the Article embeds", ctx do
      body = get_ap(ctx.poll.ap_id)

      assert body["type"] == "Question"
      assert body["id"] == ctx.poll.ap_id
      assert body["context"] == ctx.article.ap_id
      assert length(body["oneOf"]) == 2

      # The embedded copy and the standalone one are the same object.
      embedded =
        Federation.article_object(ctx.article)
        |> Map.fetch!("attachment")
        |> Enum.find(&(&1["type"] == "Question"))

      assert embedded["id"] == body["id"]
      assert embedded["oneOf"] == body["oneOf"]
    end

    test "a voter is still never named (ADR 0048)", ctx do
      body = get_ap(ctx.poll.ap_id)

      for option <- body["oneOf"] do
        assert Map.has_key?(option["replies"], "totalItems")
        refute Map.has_key?(option["replies"], "items")
        refute Map.has_key?(option["replies"], "orderedItems")
      end
    end

    test "404 when the board has federation turned off", ctx do
      {:ok, _} = Content.update_board(ctx.board, %{ap_enabled: false})
      assert_not_found(ctx.poll.ap_id)
    end
  end

  describe "the id a peer already knows keeps working" do
    test "a comment resolves by its current id and by its legacy id", ctx do
      legacy = "#{Federation.actor_uri(:user, ctx.author.username)}#note-#{ctx.comment.id}"
      rewrite_as_legacy(ctx.comment, legacy)

      assert Content.get_comment_by_ap_id(ctx.comment.ap_id).id == ctx.comment.id
      assert Content.get_comment_by_ap_id(legacy).id == ctx.comment.id
    end

    test "a poll resolves by its current id and by its legacy id", ctx do
      legacy = "#{ctx.article.ap_id}#poll"
      rewrite_as_legacy(ctx.poll, legacy)

      assert Content.get_poll_by_ap_id(ctx.poll.ap_id).id == ctx.poll.id
      assert Content.get_poll_by_ap_id(legacy).id == ctx.poll.id
    end

    test "an unknown id still resolves to nothing", ctx do
      refute Content.get_comment_by_ap_id("https://elsewhere.example/notes/1")
      refute Content.get_poll_by_ap_id("#{ctx.article.ap_id}#not-a-poll")
    end
  end

  describe "a withdrawal names every id the object has had" do
    test "a rewritten comment is deleted under both ids", ctx do
      legacy = "#{Federation.actor_uri(:user, ctx.author.username)}#note-#{ctx.comment.id}"
      comment = rewrite_as_legacy(ctx.comment, legacy)

      Repo.delete_all(Baudrate.Federation.DeliveryJob)
      follow_the_author(ctx.author)

      :ok = Publisher.publish_comment_deleted(comment, ctx.article)

      ids = delivered_object_ids()
      assert comment.ap_id in ids
      assert legacy in ids, "an instance that knew the old id is never told it was deleted"
    end

    test "a comment that was never rewritten is deleted once", ctx do
      Repo.delete_all(Baudrate.Federation.DeliveryJob)
      follow_the_author(ctx.author)

      :ok = Publisher.publish_comment_deleted(ctx.comment, ctx.article)

      assert delivered_object_ids() == [ctx.comment.ap_id]
    end
  end

  # --- helpers ---

  defp get_ap(uri) do
    path = URI.parse(uri).path

    build_conn()
    |> put_req_header("accept", @activity_json)
    |> get(path)
    |> json_response(200)
  end

  defp assert_not_found(uri) do
    path = URI.parse(uri).path

    conn =
      build_conn()
      |> put_req_header("accept", @activity_json)
      |> get(path)

    assert conn.status == 404, "#{path} answered #{conn.status}, expected 404"
  end

  # Puts a row back into the state the ADR 0050 backfill leaves behind:
  # the canonical id, plus the one peers learned before the rewrite.
  defp rewrite_as_legacy(row, legacy) do
    row |> Ecto.Changeset.change(legacy_ap_id: legacy) |> Repo.update!()
  end

  defp delivered_object_ids do
    Baudrate.Federation.DeliveryJob
    |> Repo.all()
    |> Enum.map(fn job ->
      job.activity_json |> Jason.decode!() |> get_in(["object", "id"])
    end)
    |> Enum.uniq()
  end

  # A Delete is only enqueued when there is somewhere to send it.
  defp follow_the_author(author) do
    actor = create_remote_actor()

    {:ok, _} =
      Federation.create_follower(
        Federation.actor_uri(:user, author.username),
        actor,
        "#{actor.ap_id}#follow-#{System.unique_integer([:positive])}"
      )

    actor
  end

  defp create_board do
    %Board{}
    |> Board.changeset(%{
      name: "Board",
      slug: "objid-#{System.unique_integer([:positive])}",
      ap_enabled: true
    })
    |> Repo.insert!()
  end

  defp create_user do
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "objid#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_article(user, board) do
    Content.create_article(
      %{
        title: "An article",
        body: "With a poll",
        slug: "objid-art-#{System.unique_integer([:positive])}",
        user_id: user.id
      },
      [board.id],
      poll: %{
        mode: "single",
        options: [%{text: "Option A", position: 0}, %{text: "Option B", position: 1}]
      }
    )
  end

  defp create_comment(article, user) do
    Content.create_comment(%{
      "body" => "a comment",
      "article_id" => article.id,
      "user_id" => user.id
    })
  end

  defp create_remote_actor do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/a#{n}",
      username: "a#{n}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/a#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
