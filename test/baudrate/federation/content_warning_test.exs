defmodule Baudrate.Federation.ContentWarningTest do
  @moduledoc """
  Acceptance gate for [ADR 0052](../../../doc/adr/0052-a-content-warning-is-a-field-not-a-prefix.md):
  a warning survives a round trip, and never becomes the thing it was warning
  about.

  The bug this replaces was quiet. An inbound `sensitive` object had its
  `summary` glued onto the front of the body as `[CW: …]`, which is a lossy
  one-way conversion: the warning and the content became one string, so
  nothing could render the body behind it, nothing could publish the warning
  back out, and the reader was shown the very thing they were being warned
  about with a label above it.

  Three properties, and each is a way it could go wrong again:

    * **The body is not touched.** A prefix is easy to reintroduce and looks
      harmless in a diff.
    * **`summary` is the warning and nothing else.** It used to carry a
      500-character excerpt of the body, and Mastodon maps `summary` to
      `spoiler_text` for *every* object type — so every article arrived there
      hidden behind a "content warning" that was its own opening paragraph.
    * **Video and audio are links.** Proxying them would mean this instance
      re-serving arbitrarily large files; embedding them would be the hotlink
      the media proxy exists to prevent (ADR 0006, ADR 0045).

  **Add a new surface that carries a warning here.**
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.{Board, ContentWarning}
  alias Baudrate.Federation
  alias Baudrate.Federation.{AttachmentExtractor, InboxHandler, ObjectBuilder, RemoteActor}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    board = create_board()
    user = create_user()
    actor = create_remote_actor()

    %{board: board, user: user, actor: actor}
  end

  describe "the shared rules (Content.ContentWarning)" do
    test "an empty warning is nil, never an empty string" do
      article = build_article(%{summary: "   "})
      assert article.summary == nil
      refute ContentWarning.warned?(article)
    end

    test "text implies the flag" do
      article = build_article(%{summary: "Spoilers"})
      assert article.sensitive
      assert ContentWarning.warned?(article)
    end

    test "the flag alone still warns, with no text" do
      article = build_article(%{sensitive: true})
      assert article.summary == nil
      assert ContentWarning.warned?(article)
    end

    test "a warning is bounded" do
      article = build_article(%{summary: String.duplicate("x", 5_000)})
      assert String.length(article.summary) == ContentWarning.max_length()
    end

    # Four schemas cast the pair, from three directions. If the rules were
    # per-schema, a renderer would have to know which table a row came from.
    test "every schema that carries a warning applies the same rules" do
      changesets = [
        Content.Article.changeset(%Content.Article{}, %{
          title: "t",
          body: "b",
          slug: "s",
          summary: "  Spoilers  "
        }),
        Content.Comment.changeset(%Content.Comment{}, %{
          body: "b",
          article_id: 1,
          user_id: 1,
          summary: "  Spoilers  "
        }),
        Federation.TimelineItem.changeset(%Federation.TimelineItem{}, %{
          remote_actor_id: 1,
          ap_id: "https://x/1",
          summary: "  Spoilers  "
        }),
        Federation.TimelineItemReply.changeset(%Federation.TimelineItemReply{}, %{
          timeline_item_id: 1,
          user_id: 1,
          body: "b",
          ap_id: "https://x/1",
          summary: "  Spoilers  "
        })
      ]

      for changeset <- changesets do
        assert Ecto.Changeset.get_field(changeset, :summary) == "Spoilers"
        assert Ecto.Changeset.get_field(changeset, :sensitive)
      end
    end
  end

  describe "inbound: the warning is stored, the body is left alone" do
    test "a sensitive comment keeps its body intact", ctx do
      article = local_article(ctx.user, ctx.board)

      :ok = deliver_note(ctx.actor, article, sensitive: true, summary: "Spoilers")

      comment = article |> Content.list_comments_for_article() |> hd()

      assert comment.summary == "Spoilers"
      assert comment.sensitive
      assert comment.body =~ "the actual content"

      refute comment.body =~ "[CW:",
             "gluing the warning onto the body is what this replaced"
    end

    test "summary without the flag still warns", ctx do
      article = local_article(ctx.user, ctx.board)

      :ok = deliver_note(ctx.actor, article, summary: "Spoilers")

      comment = article |> Content.list_comments_for_article() |> hd()
      assert ContentWarning.warned?(comment)
    end

    test "an ordinary post gets neither", ctx do
      article = local_article(ctx.user, ctx.board)

      :ok = deliver_note(ctx.actor, article, [])

      comment = article |> Content.list_comments_for_article() |> hd()
      refute ContentWarning.warned?(comment)
      assert comment.summary == nil
    end
  end

  describe "outbound: summary is the warning and nothing else" do
    test "an article without one publishes neither field", ctx do
      article = local_article(ctx.user, ctx.board)
      object = ObjectBuilder.article_object(article)

      refute Map.has_key?(object, "summary"),
             "`summary` used to carry a body excerpt, which Mastodon renders " <>
               "as a content warning — so every article arrived hidden behind its own text"

      refute Map.has_key?(object, "sensitive")
    end

    test "an article with one publishes both", ctx do
      article = local_article(ctx.user, ctx.board, %{summary: "Spoilers"})
      object = ObjectBuilder.article_object(article)

      assert object["summary"] == "Spoilers"
      assert object["sensitive"] == true
      assert object["content"] =~ "Body"
    end

    test "a comment carries it too, in the activity and the served object", ctx do
      article = local_article(ctx.user, ctx.board)

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "careful",
          "article_id" => article.id,
          "user_id" => ctx.user.id,
          "summary" => "Spoilers"
        })

      assert ObjectBuilder.comment_object(comment)["summary"] == "Spoilers"

      {activity, _} = Federation.Publisher.build_create_comment(comment, article)
      assert activity["object"]["summary"] == "Spoilers"
      assert activity["object"]["sensitive"] == true
    end

    # The real round trip: what this instance publishes, fed back in as if a
    # peer had sent it, must store the same warning. Both halves were written
    # against the same field names, which is exactly the assumption worth
    # checking rather than assuming.
    test "what we publish is what we would store", ctx do
      published =
        ctx.user
        |> local_article(ctx.board, %{summary: "Spoilers", body: "the actual content"})
        |> ObjectBuilder.article_object()

      target = local_article(ctx.user, ctx.board)

      :ok =
        deliver_note(ctx.actor, target,
          summary: published["summary"],
          sensitive: published["sensitive"]
        )

      comment = target |> Content.list_comments_for_article() |> hd()
      assert comment.summary == "Spoilers"
      assert comment.sensitive
    end
  end

  describe "video and audio are links, never subresources" do
    test "both kinds are extracted, and told apart" do
      object = %{
        "attachment" => [
          %{"type" => "Document", "mediaType" => "image/webp", "url" => "https://x/i.webp"},
          %{"type" => "Document", "mediaType" => "video/mp4", "url" => "https://x/v.mp4"},
          %{"type" => "Document", "mediaType" => "audio/ogg", "url" => "https://x/a.ogg"}
        ]
      }

      assert [%{"url" => "https://x/i.webp"}] =
               AttachmentExtractor.extract_image_attachments(object)

      media = AttachmentExtractor.extract_media_attachments(object)
      assert Enum.map(media, & &1["url"]) == ["https://x/v.mp4", "https://x/a.ogg"]
    end

    test "a video attachment becomes a link, not an img", ctx do
      article = local_article(ctx.user, ctx.board)

      :ok =
        deliver_note(ctx.actor, article,
          attachment: [
            %{
              "type" => "Document",
              "mediaType" => "video/mp4",
              "url" => "https://remote.example/v.mp4",
              "name" => "A video"
            }
          ]
        )

      comment = article |> Content.list_comments_for_article() |> hd()

      assert comment.body_html =~ ~s(href="https://remote.example/v.mp4")
      assert comment.body_html =~ "A video"

      refute comment.body_html =~ ~s(<img src="https://remote.example/v.mp4"),
             "an embedded video is the hotlink the media proxy exists to prevent"

      refute comment.body_html =~ "<video"
    end

    test "playable?/1 is the one predicate a renderer branches on" do
      assert AttachmentExtractor.playable?("video/mp4")
      assert AttachmentExtractor.playable?("audio/mpeg")
      refute AttachmentExtractor.playable?("image/webp")
      refute AttachmentExtractor.playable?(nil)
    end
  end

  # --- helpers ---

  defp build_article(attrs) do
    %Content.Article{}
    |> Content.Article.changeset(Map.merge(%{title: "t", body: "b", slug: "s"}, attrs))
    |> Ecto.Changeset.apply_changes()
  end

  defp deliver_note(actor, article, opts) do
    object =
      %{
        "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
        "type" => "Note",
        "content" => "<p>the actual content</p>",
        "attributedTo" => actor.ap_id,
        "inReplyTo" => article.ap_id,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
      |> Map.merge(Map.new(opts, fn {k, v} -> {to_string(k), v} end))

    activity = %{
      "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor.ap_id,
      "object" => object
    }

    InboxHandler.handle(activity, actor, :shared)
  end

  defp local_article(user, board, attrs \\ %{}) do
    {:ok, %{article: article}} =
      Content.create_article(
        Map.merge(
          %{
            title: "An article",
            body: "Body",
            slug: "cw-art-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          attrs
        ),
        [board.id]
      )

    Repo.preload(article, [:boards, :user])
  end

  defp create_board do
    %Board{}
    |> Board.changeset(%{
      name: "Board",
      slug: "cw-#{System.unique_integer([:positive])}",
      ap_enabled: true
    })
    |> Repo.insert!()
  end

  defp create_user do
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "cw#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
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
