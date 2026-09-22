defmodule Baudrate.Moderation.ContentFilterTest do
  @moduledoc """
  The acceptance gate for content filters (Phase 5D, ADR 0065).

  Four halves:

    * **Matching** — the three kinds, the normal form that folds the usual
      evasions (fullwidth letters, a zero-width space inside a word, an entity
      in place of a letter), and that no pattern is ever a regular expression.
    * **Every way to post** — articles, comments and timeline replies, and
      **their edits**, because posting clean and editing dirty is the second
      way in. An edit is judged by what it adds.
    * **What each action does where** — block refuses, hold holds only where a
      composer submitted it (and otherwise flags, or refuses an edit), flag
      publishes and opens a report naming the filter.
    * **Remote content** — only dropped or flagged, never held, and direct
      messages are never screened at all.

  Every match is recorded, and no refusal names the pattern.

  A new way to post belongs here, with a refusal and a pass.
  """
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{InboxHandler, RemoteActor}
  alias Baudrate.Moderation.{ContentFilterMatch, ContentFilters, HeldPost, Report}
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  setup do
    Setup.seed_roles_and_permissions()

    Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    board =
      %Board{}
      |> Board.changeset(%{
        name: "Board",
        slug: "filters-#{System.unique_integer([:positive])}",
        ap_enabled: true
      })
      |> Repo.insert!()

    %{board: board, admin: member("admin"), user: member()}
  end

  defp member(role_name \\ "user") do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "filtered#{n}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: "active"])
    user |> Repo.reload() |> Repo.preload(:role)
  end

  defp filter!(admin, pattern, kind, action, applies_to \\ "both") do
    {:ok, filter} =
      ContentFilters.create_filter(
        %{"pattern" => pattern, "kind" => kind, "action" => action, "applies_to" => applies_to},
        admin
      )

    filter
  end

  defp screen(body, opts \\ []) do
    ContentFilters.screen(%{body: body, title: opts[:title]}, mode: opts[:mode] || :post)
  end

  defp article_attrs(user, body, extra \\ %{}) do
    Map.merge(
      %{
        "title" => "A title",
        "body" => body,
        "slug" => "filtered-#{System.unique_integer([:positive])}",
        "user_id" => user.id
      },
      extra
    )
  end

  defp matches, do: Repo.all(from(m in ContentFilterMatch, order_by: m.id))

  describe "matching" do
    test "a word matches whole words only, whatever the case", %{admin: admin} do
      filter!(admin, "Casino", "word", "block")

      assert screen("Casino night at the hall").outcome == :block
      assert screen("A CASINO.").outcome == :block
      assert screen("Casinos are closed").outcome == :pass
      assert screen("occasional").outcome == :pass
    end

    test "a phrase matches across punctuation and spacing", %{admin: admin} do
      filter!(admin, "buy followers", "word", "block")

      assert screen("Buy... followers! Today!").outcome == :block
      assert screen("buy   \n  followers").outcome == :block
      assert screen("buy more followers").outcome == :pass
    end

    test "the title and the content warning are read too", %{admin: admin} do
      filter!(admin, "casino", "word", "block")

      assert screen("fine", title: "Casino tonight").outcome == :block

      assert ContentFilters.screen(%{summary: "casino", body: "fine"}, mode: :post).outcome ==
               :block
    end

    test "the usual evasions fold away", %{admin: admin} do
      filter!(admin, "casino", "word", "block")

      # Fullwidth letters (NFKC), a zero-width space inside the word, and an
      # entity standing in for a letter — each renders as "casino".
      assert screen("Ｃａｓｉｎｏ").outcome == :block
      assert screen("ca​sino").outcome == :block
      assert screen("&#99;asino").outcome == :block
      assert screen("ca<b></b>sino").outcome == :block
    end

    test "substring matches inside words, and * stands for letters within one", %{admin: admin} do
      filter!(admin, "casino", "substring", "block")
      filter!(admin, "v*gra", "substring", "flag")

      assert screen("onlinecasinos").outcome == :block
      assert screen("viagra here").outcome == :flag
      assert screen("vi-agra").outcome == :pass
      assert screen("v gra").outcome == :pass
    end

    test "substring works in a language written without spaces", %{admin: admin} do
      filter!(admin, "賭場", "substring", "block")
      assert screen("今天線上賭場開幕").outcome == :block
      assert screen("今天天氣很好").outcome == :pass
    end

    test "a domain matches its links and their subdomains, and nothing else", %{admin: admin} do
      filter!(admin, "https://Spam.Example/whatever", "domain", "block")

      assert screen("[x](https://spam.example/buy)").outcome == :block
      assert screen("[x](https://www.spam.example/buy)").outcome == :block
      assert screen("Bare https://spam.example/buy link").outcome == :block
      # A browser leaves the site for `//host` too.
      assert screen(~s(<a href="//spam.example/x">x</a>)).outcome == :block
      assert screen("[x](https://notspam.example/)").outcome == :pass
      assert screen("[x](https://spam.example.org/)").outcome == :pass
    end

    test "the strongest filter decides", %{admin: admin} do
      filter!(admin, "casino", "word", "flag")
      filter!(admin, "poker", "word", "block")

      verdict = screen("casino and poker")
      assert verdict.outcome == :block
      assert length(verdict.matched) == 2
    end

    test "a filter switched off, or scoped to remote content, does not touch local posts",
         %{admin: admin} do
      off = filter!(admin, "casino", "word", "block")
      {:ok, _} = ContentFilters.update_filter(off, %{enabled: false}, admin)
      filter!(admin, "poker", "word", "block", "remote")

      assert screen("casino poker").outcome == :pass
    end

    test "matching is proportional to the text, whatever the pattern", %{admin: admin} do
      filter!(admin, "a*a*a*a*b", "substring", "block")
      text = String.duplicate("a", 60_000)

      {micros, verdict} = :timer.tc(fn -> screen(text) end)
      assert verdict.outcome == :pass
      assert micros < 2_000_000
    end
  end

  describe "the patterns an admin may write" do
    test "no regular expression, and * only among letters and numbers", %{admin: admin} do
      assert {:error, changeset} =
               ContentFilters.create_filter(
                 %{"pattern" => "(a+)+*", "kind" => "substring", "action" => "block"},
                 admin
               )

      assert %{pattern: [_]} = errors_on(changeset)

      assert {:ok, _} =
               ContentFilters.create_filter(
                 %{"pattern" => "(a+)+", "kind" => "substring", "action" => "block"},
                 admin
               )
    end

    test "patterns are stored in the normal form, so the same filter cannot exist twice",
         %{admin: admin} do
      filter = filter!(admin, "  Ｃａｓｉｎｏ  ", "word", "block")
      assert filter.pattern == "casino"

      assert {:error, changeset} =
               ContentFilters.create_filter(
                 %{"pattern" => "CASINO", "kind" => "word", "action" => "flag"},
                 admin
               )

      assert %{pattern: ["is already a filter"]} = errors_on(changeset)
    end

    test "a domain is reduced to its host, and nonsense is refused", %{admin: admin} do
      assert filter!(admin, "@someone@Spam.Example", "domain", "block").pattern ==
               "spam.example"

      assert {:error, _} =
               ContentFilters.create_filter(
                 %{"pattern" => "not a domain", "kind" => "domain", "action" => "block"},
                 admin
               )
    end

    # Authorized in the context, not only by the page's route hook (ADR 0016).
    test "only an admin may write a filter", %{admin: admin, user: user} do
      for actor <- [user, member("moderator")] do
        assert {:error, :unauthorized} =
                 ContentFilters.create_filter(
                   %{"pattern" => "casino", "kind" => "word", "action" => "block"},
                   actor
                 )
      end

      filter = filter!(admin, "casino", "word", "block")
      moderator = member("moderator")

      assert {:error, :unauthorized} =
               ContentFilters.update_filter(filter, %{enabled: false}, moderator)

      assert {:error, :unauthorized} = ContentFilters.delete_filter(filter, moderator)
      assert Repo.get(Baudrate.Moderation.ContentFilter, filter.id).enabled
    end

    test "every change is in the moderation log", %{admin: admin} do
      filter = filter!(admin, "casino", "word", "block")
      {:ok, filter} = ContentFilters.update_filter(filter, %{action: "flag"}, admin)
      {:ok, _} = ContentFilters.delete_filter(filter, admin)

      actions =
        Repo.all(
          from(l in Baudrate.Moderation.Log,
            where: l.target_type == "content_filter",
            order_by: l.id,
            select: l.action
          )
        )

      assert actions == ~w(create_filter update_filter delete_filter)
    end
  end

  describe "articles" do
    test "block refuses, records the match, and says nothing about the pattern", ctx do
      filter = filter!(ctx.admin, "casino", "word", "block")

      assert {:error, :account, :content_filtered, _} =
               Content.submit_article(article_attrs(ctx.user, "Casino tonight"), [ctx.board.id])

      assert Repo.aggregate(Content.Article, :count) == 0

      assert [%{content_filter_id: id, action: "block", target_type: "article", edit: false}] =
               matches()

      assert id == filter.id

      message = BaudrateWeb.Helpers.refusal_message(:content_filtered, ctx.user, "x")
      refute message =~ "casino"
    end

    test "hold holds what a composer submits", ctx do
      filter = filter!(ctx.admin, "casino", "word", "hold")

      assert {:held, %HeldPost{reason: "filter", content_filter_id: id}} =
               Content.submit_article(article_attrs(ctx.user, "Casino tonight"), [ctx.board.id])

      assert id == filter.id
      assert Repo.aggregate(Content.Article, :count) == 0
      assert [%{action: "hold"}] = matches()
    end

    test "hold flags what cannot be held", ctx do
      bot = member()
      Repo.update_all(from(u in User, where: u.id == ^bot.id), set: [is_bot: true])
      filter!(ctx.admin, "casino", "word", "hold")

      assert {:ok, %{article: article}} =
               Content.create_article(article_attrs(bot, "Casino tonight"), [ctx.board.id],
                 trusted: true
               )

      assert %Report{content_filter_id: id, reason: "casino"} =
               Repo.get_by(Report, article_id: article.id)

      assert id
      assert [%{action: "flag"}] = matches()
    end

    test "flag publishes and opens a report that names the filter", ctx do
      filter = filter!(ctx.admin, "casino", "word", "flag")

      assert {:ok, %{article: article}} =
               Content.submit_article(article_attrs(ctx.user, "Casino tonight"), [ctx.board.id])

      report = Repo.get_by!(Report, article_id: article.id)
      assert report.content_filter_id == filter.id
      assert report.reason == "casino"
      assert is_nil(report.reporter_id)

      # The staff are told about it as they are about any report.
      assert Repo.exists?(
               from(n in Baudrate.Notification.Notification,
                 where: n.user_id == ^ctx.admin.id and n.type == "moderation_report"
               )
             )
    end

    test "an edit may not add what a filter refuses", ctx do
      {:ok, %{article: article}} =
        Content.submit_article(article_attrs(ctx.user, "Nothing here"), [ctx.board.id])

      filter!(ctx.admin, "casino", "word", "block")

      assert {:error, :content_filtered} =
               Content.update_article(article, %{"body" => "Casino tonight"}, ctx.user)

      assert [%{action: "block", edit: true}] = matches()
    end

    test "an edit is judged by what it adds, so a typo can still be fixed", ctx do
      {:ok, %{article: article}} =
        Content.submit_article(article_attrs(ctx.user, "Casino tonight, tpyo"), [ctx.board.id])

      filter!(ctx.admin, "casino", "word", "block")

      assert {:ok, _} =
               Content.update_article(article, %{"body" => "Casino tonight, typo"}, ctx.user)

      assert matches() == []
    end

    test "an edit cannot be held, so a hold filter refuses it", ctx do
      {:ok, %{article: article}} =
        Content.submit_article(article_attrs(ctx.user, "Nothing here"), [ctx.board.id])

      filter!(ctx.admin, "casino", "word", "hold")

      assert {:error, :content_filtered} =
               Content.update_article(article, %{"body" => "Casino tonight"}, ctx.user)
    end

    test "an edit that matches a flag filter is published and reported", ctx do
      {:ok, %{article: article}} =
        Content.submit_article(article_attrs(ctx.user, "Nothing here"), [ctx.board.id])

      filter!(ctx.admin, "casino", "word", "flag")

      assert {:ok, _} = Content.update_article(article, %{"body" => "Casino tonight"}, ctx.user)
      assert Repo.get_by(Report, article_id: article.id)
    end
  end

  # Published with the post, so screened with it — found by the security
  # audit before v1.39.0, when both carried text past every filter.
  describe "what is published with a post" do
    test "a poll option is screened with the article", ctx do
      filter!(ctx.admin, "casino", "word", "block")

      assert {:error, :account, :content_filtered, _} =
               Content.submit_article(article_attrs(ctx.user, "Vote!"), [ctx.board.id],
                 poll: %{
                   mode: "single",
                   closes_at: nil,
                   options: [%{text: "casino", position: 0}, %{text: "home", position: 1}]
                 }
               )
    end

    test "an upload's description is screened with the article", ctx do
      filter!(ctx.admin, "casino", "word", "block")
      image = orphan_image(ctx.user, "casino flyer")

      assert {:error, :account, :content_filtered, _} =
               Content.submit_article(article_attrs(ctx.user, "Look"), [ctx.board.id],
                 image_ids: [image.id]
               )
    end
  end

  # A description is published text once its image is (ADR 0029, ADR 0065).
  # Before the security audit for v1.39.0, it could be rewritten on a
  # published post by a silenced member, and nothing screened it.
  describe "editing an image description" do
    setup ctx do
      image = orphan_image(ctx.user, "a harbour")

      {:ok, %{article: article}} =
        Content.submit_article(article_attrs(ctx.user, "Photo"), [ctx.board.id],
          image_ids: [image.id]
        )

      %{image: Repo.reload!(image), article: article}
    end

    test "on a published image is screened as an edit", ctx do
      filter!(ctx.admin, "casino", "word", "block")

      assert {:error, :content_filtered} =
               Content.update_article_image_alt(ctx.image.id, ctx.user.id, "casino night")

      assert Repo.reload!(ctx.image).alt == "a harbour"
      assert {:ok, _} = Content.update_article_image_alt(ctx.image.id, ctx.user.id, "the harbour")
    end

    test "on a published image is refused to a silenced member", ctx do
      {:ok, _} =
        Baudrate.Auth.issue_sanction(ctx.admin, ctx.user, "silence",
          reason: "Spam",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
        )

      assert {:error, :account_silenced} =
               Content.update_article_image_alt(ctx.image.id, ctx.user.id, "changed")

      # A draft's upload is still the member's to describe.
      orphan = orphan_image(ctx.user, nil)
      assert {:ok, _} = Content.update_article_image_alt(orphan.id, ctx.user.id, "changed")
    end
  end

  describe "comments" do
    setup ctx do
      {:ok, %{article: article}} =
        Content.submit_article(article_attrs(ctx.admin, "An article"), [ctx.board.id])

      %{article: article}
    end

    defp comment_attrs(user, article, body),
      do: %{"body" => body, "article_id" => article.id, "user_id" => user.id}

    test "block refuses a comment", ctx do
      filter!(ctx.admin, "casino", "word", "block")

      assert {:error, :content_filtered} =
               Content.submit_comment(comment_attrs(ctx.user, ctx.article, "casino!"))

      assert {:error, :content_filtered} =
               Content.create_comment(comment_attrs(ctx.user, ctx.article, "casino!"))
    end

    test "hold holds a submitted comment and flags a created one", ctx do
      filter!(ctx.admin, "casino", "word", "hold")

      assert {:held, %HeldPost{kind: "comment"}} =
               Content.submit_comment(comment_attrs(ctx.user, ctx.article, "casino!"))

      assert {:ok, comment} =
               Content.create_comment(comment_attrs(ctx.user, ctx.article, "casino!"))

      assert Repo.get_by(Report, comment_id: comment.id)
    end

    test "an edit may not add what a filter refuses, and may keep what it had", ctx do
      {:ok, clean} = Content.submit_comment(comment_attrs(ctx.user, ctx.article, "fine"))
      {:ok, dirty} = Content.submit_comment(comment_attrs(ctx.user, ctx.article, "casino tpyo"))
      filter!(ctx.admin, "casino", "word", "block")

      assert {:error, :content_filtered} =
               Content.update_comment(clean, %{"body" => "casino"}, ctx.user)

      assert {:ok, _} = Content.update_comment(dirty, %{"body" => "casino typo"}, ctx.user)
    end
  end

  describe "timeline replies" do
    setup ctx do
      {:ok, _} = Baudrate.Federation.KeyStore.ensure_user_keypair(ctx.user)
      actor = remote_actor()
      uid = System.unique_integer([:positive])

      %Federation.UserFollow{}
      |> Federation.UserFollow.changeset(%{
        user_id: ctx.user.id,
        remote_actor_id: actor.id,
        state: "accepted",
        ap_id: "https://local.example/follows/#{uid}",
        accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

      {:ok, item} =
        Federation.create_timeline_item(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/#{uid}",
          body: "Hello",
          body_html: "<p>Hello</p>",
          source_url: "https://remote.example/notes/#{uid}",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      %{item: item}
    end

    test "block refuses a reply, and flag reports it with a copy of the text", ctx do
      filter!(ctx.admin, "casino", "word", "block")
      filter!(ctx.admin, "poker", "word", "flag")

      assert {:error, :content_filtered} =
               Federation.create_timeline_item_reply(ctx.item, ctx.user, "casino!")

      assert {:ok, _reply} = Federation.create_timeline_item_reply(ctx.item, ctx.user, "poker?")

      report = Repo.get_by!(Report, reported_user_id: ctx.user.id)
      assert report.evidence_body == "poker?"
      assert report.content_filter_id
    end
  end

  describe "remote content" do
    setup ctx do
      {:ok, %{article: article}} =
        Content.submit_article(article_attrs(ctx.admin, "An article"), [ctx.board.id])

      %{article: article, actor: remote_actor()}
    end

    test "a block drops it, answering :ok so the sender does not retry", ctx do
      filter!(ctx.admin, "casino", "word", "block")

      assert :ok = deliver_note(ctx.actor, ctx.article, "<p>casino!</p>")
      assert Content.list_comments_for_article(ctx.article) == []
      assert [%{action: "drop", target_type: "remote", remote_actor_id: id}] = matches()
      assert id == ctx.actor.id
    end

    test "a hold cannot hold it, so it is stored and reported", ctx do
      filter!(ctx.admin, "casino", "word", "hold")

      assert :ok = deliver_note(ctx.actor, ctx.article, "<p>casino!</p>")
      [comment] = Content.list_comments_for_article(ctx.article)

      report = Repo.get_by!(Report, comment_id: comment.id)
      assert report.remote_actor_id == ctx.actor.id
      assert report.content_filter_id
      assert Repo.aggregate(HeldPost, :count) == 0
    end

    test "a filter scoped to local posts does not touch it", ctx do
      filter!(ctx.admin, "casino", "word", "block", "local")

      assert :ok = deliver_note(ctx.actor, ctx.article, "<p>casino!</p>")
      assert [_] = Content.list_comments_for_article(ctx.article)
    end

    test "an update that adds a refused word is dropped, and the stored text stays", ctx do
      assert :ok =
               deliver_note(ctx.actor, ctx.article, "<p>hello</p>",
                 id: "https://remote.example/notes/edit"
               )

      filter!(ctx.admin, "casino", "word", "block")

      update = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Update",
        "actor" => ctx.actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/edit",
          "type" => "Note",
          "content" => "<p>casino!</p>",
          "attributedTo" => ctx.actor.ap_id,
          "inReplyTo" => ctx.article.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert :ok = InboxHandler.handle(update, ctx.actor, :shared)
      [comment] = Content.list_comments_for_article(ctx.article)
      assert comment.body =~ "hello"
    end

    # Found by the security audit before v1.39.0: the Update was exempted
    # when it *looked* like a message, but the handler rewrites the stored
    # public comment by its id whatever the Update's addressing says.
    test "an update addressed like a message cannot edit refused text into a comment", ctx do
      id = "https://remote.example/notes/dm-shaped"
      assert :ok = deliver_note(ctx.actor, ctx.article, "<p>hello</p>", id: id)
      filter!(ctx.admin, "casino", "word", "block")
      recipient = Federation.actor_uri(:user, ctx.user.username)

      update = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Update",
        "actor" => ctx.actor.ap_id,
        "object" => %{
          "id" => id,
          "type" => "Note",
          "content" => "<p>casino!</p>",
          "attributedTo" => ctx.actor.ap_id,
          "inReplyTo" => ctx.article.ap_id,
          "to" => [recipient],
          "tag" => [%{"type" => "Mention", "href" => recipient}]
        }
      }

      assert :ok = InboxHandler.handle(update, ctx.actor, :shared)
      [comment] = Content.list_comments_for_article(ctx.article)
      assert comment.body =~ "hello"
      refute comment.body =~ "casino"
    end

    # The inbox falls back to `source.content` when `content` is empty; the
    # filter read only `content`, so the fallback carried text past it.
    test "text carried in source.content alone is screened", ctx do
      filter!(ctx.admin, "casino", "word", "block")

      activity = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => ctx.actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "",
          "source" => %{"content" => "casino tonight", "mediaType" => "text/markdown"},
          "attributedTo" => ctx.actor.ap_id,
          "inReplyTo" => ctx.article.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"]
        }
      }

      assert :ok = InboxHandler.handle(activity, ctx.actor, :shared)
      assert Content.list_comments_for_article(ctx.article) == []
    end

    test "attachment descriptions and poll options are screened", ctx do
      filter!(ctx.admin, "casino", "word", "block")

      assert ContentFilters.screen_remote(
               %{
                 "content" => "<p>fine</p>",
                 "attachment" => [%{"type" => "Image", "name" => "casino flyer"}]
               },
               ctx.actor
             ).outcome == :drop

      assert ContentFilters.screen_remote(
               %{"content" => "<p>fine</p>", "oneOf" => [%{"name" => "casino"}]},
               ctx.actor
             ).outcome == :drop
    end

    test "a direct message is never screened", ctx do
      recipient = ctx.user
      filter!(ctx.admin, "casino", "word", "block")

      Repo.update_all(from(u in User, where: u.id == ^recipient.id), set: [dm_access: "anyone"])

      dm = %{
        "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => ctx.actor.ap_id,
        "object" => %{
          "id" => "https://remote.example/notes/#{System.unique_integer([:positive])}",
          "type" => "Note",
          "content" => "<p>casino!</p>",
          "attributedTo" => ctx.actor.ap_id,
          "to" => [Federation.actor_uri(:user, recipient.username)],
          "tag" => [
            %{"type" => "Mention", "href" => Federation.actor_uri(:user, recipient.username)}
          ]
        }
      }

      InboxHandler.handle(dm, ctx.actor, :shared)
      assert matches() == []
    end
  end

  # --- helpers ---

  defp orphan_image(user, alt) do
    %Baudrate.Content.ArticleImage{}
    |> Baudrate.Content.ArticleImage.changeset(%{
      filename: "#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}.webp",
      storage_path: "/nonexistent",
      width: 10,
      height: 10,
      user_id: user.id,
      alt: alt
    })
    |> Repo.insert!()
  end

  defp remote_actor do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/r#{n}",
      username: "r#{n}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/r#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp deliver_note(actor, article, content, opts \\ []) do
    object = %{
      "id" => opts[:id] || "https://remote.example/notes/#{System.unique_integer([:positive])}",
      "type" => "Note",
      "content" => content,
      "attributedTo" => actor.ap_id,
      "inReplyTo" => article.ap_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"]
    }

    activity = %{
      "id" => "https://remote.example/activities/#{System.unique_integer([:positive])}",
      "type" => "Create",
      "actor" => actor.ap_id,
      "object" => object
    }

    InboxHandler.handle(activity, actor, :shared)
  end
end
