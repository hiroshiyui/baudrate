defmodule Baudrate.Auth.TrustTest do
  @moduledoc """
  The acceptance gate for the limits on new accounts (P5-D2, ADR 0064).

  Three halves. **Standing**: trust is earned by age *and* posts that are
  still up, computed when asked, and bots, admins and moderators have it from
  the start. **Every way to post**: articles, comments and timeline replies,
  their edits, and the article edit page's image upload — an edit is the
  second way in, so a limit that holds only at creation is decorative. And
  **direct messages**, which a new account may send only where it is not
  unsolicited.

  A new posting path belongs in the second half, with a refusal and a pass.
  """
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Auth.Trust
  alias Baudrate.Content
  alias Baudrate.Content.{ArticleImage, Board}
  alias Baudrate.Federation
  alias Baudrate.Federation.{KeyStore, RemoteActor}
  alias Baudrate.Messaging
  alias Baudrate.Messaging.DirectMessage
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.{Setting, User}
  alias BaudrateWeb.RateLimiter.Sandbox

  setup do
    Setup.seed_roles_and_permissions()

    # Posts with links schedule a link preview; nothing here is about those.
    Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    board =
      %Board{}
      |> Board.changeset(%{name: "Board", slug: "board-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    %{board: board}
  end

  defp limits_on(days \\ 3, posts \\ 3) do
    Repo.insert!(%Setting{key: "new_account_days", value: Integer.to_string(days)})
    Repo.insert!(%Setting{key: "new_account_posts", value: Integer.to_string(posts)})
    :ok
  end

  defp member(role_name \\ "user", attrs \\ %{}) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "member#{n}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: Enum.to_list(Map.merge(%{status: "active"}, attrs))
    )

    user |> Repo.reload() |> Repo.preload(:role)
  end

  defp age(user, days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [inserted_at: at])
    Repo.reload(user) |> Repo.preload(:role)
  end

  defp post(user, board, body \\ "Some words.", opts \\ []) do
    Content.create_article(
      %{
        "title" => "A post",
        "body" => body,
        "slug" => "post-#{System.unique_integer([:positive])}",
        "user_id" => user.id
      },
      [board.id],
      opts
    )
  end

  # An account that has earned trust: old enough, with three posts up.
  defp established(board) do
    user = member() |> age(10)
    for _ <- 1..3, do: {:ok, _} = post(user, board)
    user
  end

  defp two_links,
    do: "See [one](https://one.example/a) and [two](https://two.example/b)."

  describe "standing" do
    setup do: limits_on()

    test "age alone is not enough, and neither are posts alone", %{board: board} do
      old_and_silent = member() |> age(10)
      refute Trust.trusted?(old_and_silent)

      new_and_busy = member()
      for _ <- 1..3, do: {:ok, _} = post(new_and_busy, board)
      refute Trust.trusted?(new_and_busy)

      assert Trust.trusted?(age(new_and_busy, 10))
    end

    test "a removed post does not count, so trust leaves with it", %{board: board} do
      user = member() |> age(10)
      articles = for _ <- 1..3, do: elem(post(user, board), 1).article
      assert Trust.trusted?(user)

      {:ok, _} = Content.soft_delete_article(hd(articles), deleted_by: user.id)

      refute Trust.trusted?(user)
      assert %{post_count: 2, posts_required: 3} = Trust.standing(user)
    end

    test "comments count as posts", %{board: board} do
      author = established(board)
      {:ok, %{article: article}} = post(author, board)
      user = member() |> age(10)

      for _ <- 1..3 do
        {:ok, _} =
          Content.create_comment(%{
            "body" => "A reply.",
            "article_id" => article.id,
            "user_id" => user.id
          })
      end

      assert Trust.trusted?(user)
    end

    test "a reply to a remote timeline item does not count" do
      # No moderator here can remove one, so it cannot be a post "not removed".
      user = member() |> age(10)
      {actor, item} = timeline_item_followed_by(user)

      for _ <- 1..3 do
        {:ok, _} = Federation.create_timeline_item_reply(item, user, "Hello @#{actor.username}")
      end

      refute Trust.trusted?(user)
    end

    test "bots, admins and moderators are trusted from their first minute" do
      assert Trust.trusted?(member("user", %{is_bot: true}))
      assert Trust.trusted?(member("admin"))
      assert Trust.trusted?(member("moderator"))
    end

    test "an invite confers nothing" do
      inviter = member("admin")
      refute Trust.trusted?(member("user", %{invited_by_id: inviter.id}))
    end

    test "nobody to limit is trusted" do
      assert Trust.trusted?(nil)
      assert Trust.trusted?(-1)
    end

    test "the standing says what is left", %{board: board} do
      user = member()
      {:ok, _} = post(user, board)

      standing = Trust.standing(user)
      refute standing.trusted
      assert standing.post_count == 1
      assert %DateTime{} = standing.old_enough_at
      assert DateTime.compare(standing.old_enough_at, DateTime.utc_now()) == :gt
    end
  end

  describe "the settings" do
    test "0 and 0 trusts everyone" do
      limits_on(0, 0)
      assert Trust.trusted?(member())
    end

    test "either threshold binds alone", %{board: board} do
      limits_on(0, 1)
      user = member()
      refute Trust.trusted?(user)
      {:ok, _} = post(user, board)
      assert Trust.trusted?(user)
    end

    test "values are clamped, and nonsense falls back to the default" do
      limits_on(999, -4)
      assert Trust.thresholds() == %{days: Trust.max_thresholds().days, posts: 0}

      Repo.update_all(from(s in Setting, where: s.key == "new_account_days"), set: [value: "x"])
      assert Trust.thresholds().days == 3
    end

    test "the admin form refuses a value past the cap" do
      changeset = Setup.change_settings(%{"new_account_days" => "31", "new_account_posts" => "3"})
      assert %{new_account_days: [_]} = errors_on(changeset)

      changeset = Setup.change_settings(%{"new_account_days" => "3", "new_account_posts" => "21"})
      assert %{new_account_posts: [_]} = errors_on(changeset)
    end
  end

  describe "articles" do
    setup do: limits_on()

    test "one link passes, two are refused", %{board: board} do
      user = member()

      assert {:ok, _} = post(user, board, "See [this](https://one.example/a).")
      assert {:error, :account, :new_account_links, _} = post(user, board, two_links())
    end

    test "links are counted as a browser resolves them", %{board: board} do
      # A check that looked for an `https://` prefix counted none of these, and
      # a browser follows every one of them off the site.
      user = member()

      body = ~s(<a href="//one.example/a">a</a> <a href="/\\two.example/b">b</a>)
      assert {:error, :account, :new_account_links, _} = post(user, board, body)

      # `http:host` leaves the site from an `https:` page, and `https:host`
      # from an `http:` one; with the page's own scheme it is a relative path.
      other_scheme =
        if URI.parse(BaudrateWeb.Endpoint.url()).scheme == "https", do: "http", else: "https"

      body = ~s(<a href="https://one.example/a">a</a> <a href="#{other_scheme}:two.example">b</a>)
      assert {:error, :account, :new_account_links, _} = post(user, board, body)
    end

    test "links on this site, tags and mentions do not count", %{board: board} do
      user = member()
      other = member()
      origin = BaudrateWeb.Endpoint.url()

      body =
        "#welcome @#{other.username} [a board](/boards/#{board.slug}) " <>
          "[home](#{origin}/) and [one](https://one.example/a)"

      assert {:ok, _} = post(user, board, body)
    end

    test "the same page linked twice is one link", %{board: board} do
      body = "[a](https://one.example/a) and [again](https://one.example/a#part)"
      assert {:ok, _} = post(member(), board, body)
    end

    test "a host that only begins like ours is somebody else's", %{board: board} do
      host = URI.parse(BaudrateWeb.Endpoint.url()).host
      body = "[a](https://#{host}.spam.example/) and [b](https://one.example/)"

      assert {:error, :account, :new_account_links, _} = post(member(), board, body)
    end

    test "one image passes, two are refused, and an image in the body counts", %{board: board} do
      user = member()

      assert {:ok, _} = post(user, board, "One picture.", image_ids: [orphan_image(user).id])

      assert {:error, :account, :new_account_images, _} =
               post(user, board, "Two.",
                 image_ids: [orphan_image(user).id, orphan_image(user).id]
               )

      assert {:error, :account, :new_account_images, _} =
               post(user, board, "![inline](https://img.example/a.png)",
                 image_ids: [orphan_image(user).id]
               )
    end

    test "a trusted account is not limited", %{board: board} do
      assert {:ok, _} = post(established(board), board, two_links())
    end

    test "a bot posting a feed item with many links is not limited", %{board: board} do
      # Without the exemption inside the check, switching the limits on would
      # stop every RSS feed on the site — ADR 0031's finding for the terms.
      bot = member("user", %{is_bot: true})

      assert {:ok, _} =
               post(bot, board, two_links() <> " [three](https://three.example/)", trusted: true)
    end
  end

  describe "an edit is the second way in" do
    setup %{board: board} do
      user = member()
      {:ok, %{article: article}} = post(user, board, "See [this](https://one.example/a).")
      %{user: user, article: article}
    end

    test "an article edit may not add a second link", %{user: user, article: article} do
      limits_on()

      assert {:error, :new_account_links} =
               Content.update_article(article, %{"body" => two_links()}, user)
    end

    test "an article edit may keep links that were already there", %{board: board} do
      # Posted before the limits were switched on, or edited in by an admin.
      user = member()
      {:ok, %{article: article}} = post(user, board, two_links())
      limits_on()

      assert {:ok, _} =
               Content.update_article(article, %{"body" => two_links() <> " Typo."}, user)

      assert {:error, :new_account_links} =
               Content.update_article(
                 article,
                 %{"body" => two_links() <> " [three](https://three.example/)"},
                 user
               )
    end

    test "a comment edit may not add a second link", %{board: board, article: article} do
      commenter = member()

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "See [this](https://one.example/a).",
          "article_id" => article.id,
          "user_id" => commenter.id
        })

      limits_on()

      assert {:error, :new_account_links} =
               Content.update_comment(comment, %{"body" => two_links()}, commenter)

      assert {:ok, _} =
               Content.update_comment(
                 comment,
                 %{"body" => "See [this](https://one.example/a), fixed."},
                 commenter
               )

      assert board
    end

    test "an admin editing a new member's article is not limited", %{article: article} do
      limits_on()
      assert {:ok, _} = Content.update_article(article, %{"body" => two_links()}, member("admin"))
    end

    test "the edit page cannot attach an image past the limit", %{user: user, article: article} do
      limits_on()
      assert :ok = Content.authorize_article_image(article, user)

      {:ok, _} =
        Content.add_article_image(article, image_file(), Repo.preload(user, :role, force: true))

      assert {:error, :new_account_images} = Content.authorize_article_image(article, user)
    end

    test "the edit page refuses an account that may not act at all", %{
      user: user,
      article: article
    } do
      # Before ADR 0064 the edit page attached uploads with no check at all, so
      # it was also a way round a silence (ADR 0029).
      {:ok, _} =
        Auth.issue_sanction(member("admin"), user, "silence",
          reason: "Spam",
          expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
        )

      assert {:error, :account_silenced} = Content.authorize_article_image(article, user)
    end

    test "the edit page refuses someone who cannot edit the article", %{article: article} do
      assert {:error, :unauthorized} = Content.authorize_article_image(article, member())
    end
  end

  describe "comments and timeline replies" do
    setup do: limits_on()

    test "a comment may carry one link, not two", %{board: board} do
      {:ok, %{article: article}} = post(established(board), board)
      user = member()

      attrs = fn body -> %{"body" => body, "article_id" => article.id, "user_id" => user.id} end

      assert {:ok, _} = Content.create_comment(attrs.("[a](https://one.example/a)"))
      assert {:error, :new_account_links} = Content.create_comment(attrs.(two_links()))
    end

    test "a timeline reply may carry one link, not two" do
      user = member()
      {_actor, item} = timeline_item_followed_by(user)

      assert {:ok, _} =
               Federation.create_timeline_item_reply(item, user, "[a](https://a.example)")

      assert {:error, :new_account_links} =
               Federation.create_timeline_item_reply(item, user, two_links())
    end
  end

  describe "signatures" do
    # A signature is rendered under every article the account posts, so a
    # new account may add nothing to it that a post would have to count.
    setup do: limits_on()

    test "a new account cannot add a link or an image to its signature" do
      user = member()

      assert {:ok, _} = Auth.update_signature(user, "Plain words.")

      assert {:error, :new_account_signature} =
               Auth.update_signature(user, "My [blog](https://blog.example/)")

      assert {:error, :new_account_signature} =
               Auth.update_signature(user, "![me](https://img.example/me.png)")
    end

    test "it keeps what was already there, and may not add to it" do
      Repo.delete_all(Setting)
      user = member()
      {:ok, _} = Auth.update_signature(user, "My [blog](https://blog.example/)")
      limits_on()

      assert {:ok, _} = Auth.update_signature(user, "My [old blog](https://blog.example/)")

      assert {:error, :new_account_signature} =
               Auth.update_signature(
                 user,
                 "My [blog](https://blog.example/) and [shop](https://shop.example/)"
               )
    end

    test "the comparison is with the stored signature, not the caller's copy" do
      # A stale struct from another tab must not vouch for links that were
      # removed since.
      Repo.delete_all(Setting)
      user = member()
      {:ok, stale} = Auth.update_signature(user, "My [blog](https://blog.example/)")
      {:ok, _} = Auth.update_signature(stale, "No links now.")
      limits_on()

      assert {:error, :new_account_signature} =
               Auth.update_signature(stale, "My [blog](https://blog.example/)")
    end

    test "a trusted account is not limited", %{board: board} do
      assert {:ok, _} =
               Auth.update_signature(established(board), "[a](https://a.example/) ![b](/media/b)")
    end
  end

  describe "the hourly bucket" do
    setup do
      limits_on()
      test_pid = self()

      Sandbox.set_fun(fn bucket, _scale, limit ->
        send(test_pid, {:bucket, bucket, limit})
        if String.starts_with?(bucket, "new_account_post:"), do: {:deny, limit}, else: {:allow, 1}
      end)

      :ok
    end

    test "a new account over its hourly posts is refused, and told so", %{board: board} do
      user = member()

      assert {:error, :account, :new_account_rate_limited, _} = post(user, board)
      assert_received {:bucket, "new_account_post:" <> _, 10}
    end

    test "a post refused for its links does not take a place", %{board: board} do
      assert {:error, :account, :new_account_links, _} = post(member(), board, two_links())
      refute_received {:bucket, "new_account_post:" <> _, _}
    end

    test "an edit does not take a place", %{board: board} do
      Repo.delete_all(Setting)
      user = member()
      {:ok, %{article: article}} = post(user, board)
      limits_on()

      assert {:ok, _} = Content.update_article(article, %{"body" => "Edited."}, user)
      refute_received {:bucket, "new_account_post:" <> _, _}
    end

    test "a trusted account never touches the bucket", %{board: board} do
      Repo.delete_all(Setting)
      user = established(board)
      limits_on()

      assert {:ok, _} = post(user, board)
      refute_received {:bucket, "new_account_post:" <> _, _}
    end
  end

  describe "direct messages" do
    setup do: limits_on()

    test "a new account cannot message a stranger" do
      assert Messaging.dm_permission(member(), member()) == {:error, :new_account_dm}
    end

    test "it can message someone who follows it" do
      sender = member()
      recipient = member()
      {:ok, _} = Federation.create_local_follow(recipient, sender)

      assert Messaging.dm_permission(sender, recipient) == :ok
    end

    test "following them is not enough; they have to follow it" do
      sender = member()
      recipient = member()
      {:ok, _} = Federation.create_local_follow(sender, recipient)

      assert Messaging.dm_permission(sender, recipient) == {:error, :new_account_dm}
    end

    test "it can answer someone who wrote first", %{board: board} do
      sender = member()
      recipient = established(board)
      {:ok, conversation} = Messaging.find_or_create_conversation(recipient, sender)
      {:ok, _} = Messaging.create_message(conversation, recipient, %{body: "Welcome!"})

      assert {:ok, _} = Messaging.create_message(conversation, sender, %{body: "Thank you."})
    end

    test "it can always reach staff" do
      assert Messaging.dm_permission(member(), member("moderator")) == :ok
      assert Messaging.dm_permission(member(), member("admin")) == :ok
    end

    test "the recipient's own refusal comes first" do
      # Told about the limit only when the limit is the reason.
      recipient = member("user", %{dm_access: "nobody"})
      assert Messaging.dm_permission(member(), recipient) == {:error, :not_allowed}
    end

    test "a new account cannot message a remote actor that does not follow it" do
      sender = member()
      remote = remote_actor()
      {:ok, conversation} = Messaging.find_or_create_remote_conversation(sender, remote)

      assert {:error, :new_account_dm} =
               Messaging.create_message(conversation, sender, %{body: "Hello"})

      Repo.insert!(%DirectMessage{
        conversation_id: conversation.id,
        sender_remote_actor_id: remote.id,
        body: "Hi there",
        body_html: "<p>Hi there</p>"
      })

      assert {:ok, _} = Messaging.create_message(conversation, sender, %{body: "Hello"})
    end

    test "a remote follower can be messaged" do
      sender = member()
      remote = remote_actor()

      {:ok, _} =
        Federation.create_follower(
          Federation.actor_uri(:user, sender.username),
          remote,
          "https://remote.example/follows/#{System.unique_integer([:positive])}"
        )

      {:ok, conversation} = Messaging.find_or_create_remote_conversation(sender, remote)
      assert {:ok, _} = Messaging.create_message(conversation, sender, %{body: "Hello"})
    end
  end

  describe "what a refused member is told" do
    setup do: limits_on()

    test "the limit, the date and the posts still to write", %{board: board} do
      user = member()
      {:ok, _} = post(user, board)

      message = BaudrateWeb.Helpers.refusal_message(:new_account_links, user, "fallback")

      assert message =~ "at most 1 link in a post"
      assert message =~ "has passed and you have written 2 more posts"
    end

    test "only the posts, once the account is old enough" do
      message = BaudrateWeb.Helpers.refusal_message(:new_account_images, age(member(), 10), "x")

      assert message =~ "at most 1 image in a post"
      assert message =~ "This lifts once you have written 3 more posts."
      refute message =~ "has passed"
    end

    test "only the date, once the posts are there", %{board: board} do
      user = member()
      for _ <- 1..3, do: {:ok, _} = post(user, board)

      message = BaudrateWeb.Helpers.refusal_message(:new_account_dm, user, "x")

      assert message =~ "people who follow them"
      assert message =~ ~r/This lifts once \d{4}-\d\d-\d\d \d\d:\d\d has passed\.\z/
    end

    test "the hourly limit names its number" do
      message = BaudrateWeb.Helpers.refusal_message(:new_account_rate_limited, nil, "x")
      assert message =~ "at most 10 times an hour"
    end
  end

  # --- fixtures ---

  defp orphan_image(user) do
    %ArticleImage{}
    |> ArticleImage.changeset(Map.put(image_file(), :user_id, user.id))
    |> Repo.insert!()
  end

  defp image_file do
    n = System.unique_integer([:positive])

    %{
      filename: "#{String.pad_leading(Integer.to_string(n, 16), 32, "0")}.webp",
      storage_path: "/nonexistent/#{n}.webp",
      width: 10,
      height: 10
    }
  end

  defp remote_actor do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp timeline_item_followed_by(user) do
    {:ok, _} = KeyStore.ensure_user_keypair(user)
    actor = remote_actor()
    uid = System.unique_integer([:positive])

    %Federation.UserFollow{}
    |> Federation.UserFollow.changeset(%{
      user_id: user.id,
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
        body: "Hello from the fediverse",
        body_html: "<p>Hello from the fediverse</p>",
        source_url: "https://remote.example/notes/#{uid}",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {actor, item}
  end
end
