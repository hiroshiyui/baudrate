defmodule Baudrate.Federation.InboxHandlerMalformedTest do
  @moduledoc """
  Remote JSON is attacker-shaped, and a handler that raises on it is worse
  than one that refuses it: `Inbound.process/1` marks an `{:error, _}` final,
  but retries a raise three times and holds back every later activity from the
  same actor meanwhile. Each case here once raised (review finding,
  2026-11-02); each must now return.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{AttachmentExtractor, InboxHandler, KeyStore, RemoteActor}
  alias Baudrate.Moderation.Report
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    board =
      %Board{}
      |> Board.changeset(%{
        name: "B",
        slug: "malformed-#{System.unique_integer([:positive])}",
        ap_accept_policy: "open"
      })
      |> Repo.insert!()

    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "malformed#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Local",
          body: "Body",
          slug: "malformed-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    n = System.unique_integer([:positive])

    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/m#{n}",
        username: "m#{n}",
        domain: "remote.example",
        public_key_pem: elem(KeyStore.generate_keypair(), 0),
        inbox: "https://remote.example/users/m#{n}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    %{board: board, user: user, article: article, actor: actor}
  end

  defp activity(actor, type, object) do
    %{
      "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
      "type" => type,
      "actor" => actor.ap_id,
      "object" => object
    }
  end

  defp note_id, do: "https://remote.example/notes/#{System.unique_integer([:positive])}"

  test "a Create(Note) with null and object entries in its addressing", ctx do
    note = %{
      "id" => note_id(),
      "type" => "Note",
      "content" => "<p>hi</p>",
      "attributedTo" => ctx.actor.ap_id,
      "inReplyTo" => ctx.article.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [nil, %{"id" => "https://remote.example/users/x/followers"}, 42]
    }

    assert :ok = InboxHandler.handle(activity(ctx.actor, "Create", note), ctx.actor, :shared)
  end

  test "a public note compacted to as:Public that names a local user is not a DM", ctx do
    note = %{
      "id" => note_id(),
      "type" => "Note",
      "content" => "<p>hello @someone</p>",
      "attributedTo" => ctx.actor.ap_id,
      "to" => ["as:Public", Federation.actor_uri(:user, ctx.user.username)]
    }

    InboxHandler.handle(activity(ctx.actor, "Create", note), ctx.actor, :shared)
    refute Baudrate.Messaging.get_message_by_ap_id(note["id"])
  end

  test "an Update(Question) whose id is a map", ctx do
    question = %{"id" => %{"nested" => true}, "type" => "Question"}
    assert :ok = InboxHandler.handle(activity(ctx.actor, "Update", question), ctx.actor, :shared)
  end

  test "a Create(Question) whose options are strings or carry list-valued replies", ctx do
    ap_id = "https://remote.example/questions/#{System.unique_integer([:positive])}"

    question = %{
      "id" => ap_id,
      "type" => "Question",
      "name" => "Odd poll",
      "content" => "<p>?</p>",
      "attributedTo" => ctx.actor.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [Federation.actor_uri(:board, ctx.board.slug)],
      "audience" => [Federation.actor_uri(:board, ctx.board.slug)],
      "oneOf" => [
        "not an option",
        %{"type" => "Note", "name" => "Fine", "replies" => []},
        %{"type" => "Note", "name" => "Also", "replies" => %{"totalItems" => 2}}
      ]
    }

    assert :ok = InboxHandler.handle(activity(ctx.actor, "Create", question), ctx.actor, :shared)

    poll = Content.get_poll_for_article(Content.get_article_by_ap_id(ap_id).id)
    assert Enum.map(poll.options, & &1.text) |> Enum.sort() == ["Also", "Fine"]
  end

  test "an Update(Note) with content over the size limit is refused, not raised", ctx do
    id = note_id()

    note = %{
      "id" => id,
      "type" => "Note",
      "content" => "<p>first</p>",
      "attributedTo" => ctx.actor.ap_id,
      "inReplyTo" => ctx.article.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    :ok = InboxHandler.handle(activity(ctx.actor, "Create", note), ctx.actor, :shared)

    huge = %{note | "content" => String.duplicate("a", 70_000)}
    result = InboxHandler.handle(activity(ctx.actor, "Update", huge), ctx.actor, :shared)

    assert match?({:error, _}, result)
    assert Content.get_comment_by_ap_id(id).body =~ "first"
  end

  test "an Update(Article) with a long title is stored truncated, not refused", ctx do
    ap_id = "https://remote.example/articles/#{System.unique_integer([:positive])}"
    board_uri = Federation.actor_uri(:board, ctx.board.slug)

    article = %{
      "id" => ap_id,
      "type" => "Article",
      "name" => "Short",
      "content" => "<p>v1</p>",
      "attributedTo" => ctx.actor.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => [board_uri],
      "audience" => [board_uri]
    }

    :ok = InboxHandler.handle(activity(ctx.actor, "Create", article), ctx.actor, :shared)

    edit = %{article | "name" => String.duplicate("t", 400), "content" => "<p>v2</p>"}
    assert :ok = InboxHandler.handle(activity(ctx.actor, "Update", edit), ctx.actor, :shared)

    stored = Content.get_article_by_ap_id(ap_id)
    assert stored.body =~ "v2"
    assert String.length(stored.title) <= 255
  end

  test "a Flag naming many objects only looks at the first twenty", ctx do
    filler = for i <- 1..25, do: "https://remote.example/nothing/#{i}"
    flag = activity(ctx.actor, "Flag", filler ++ [ctx.article.ap_id])

    assert :ok = InboxHandler.handle(flag, ctx.actor, :shared)

    refute Repo.exists?(from(r in Report, where: r.article_id == ^ctx.article.id)),
           "the 26th object is past the cap, so nothing local was named"
  end

  test "an attachment with a null mediaType or a numeric url" do
    object = %{
      "attachment" => [
        %{"type" => "Document", "mediaType" => nil, "url" => "https://remote.example/a.png"},
        %{"type" => "Document", "mediaType" => "video/mp4", "url" => [42]}
      ]
    }

    assert AttachmentExtractor.extract_image_attachments(object) == []
    assert AttachmentExtractor.extract_media_attachments(object) == []
  end
end
