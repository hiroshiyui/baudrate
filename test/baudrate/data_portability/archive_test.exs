defmodule Baudrate.DataPortability.ArchiveTest do
  @moduledoc """
  Acceptance gates for the data export archive (ADR 0023 §14–§18).

  The canary test is the permanent guard: every secret column and every piece
  of other people's data is seeded with a unique marker, and no marker may
  appear in any archive entry, raw, Base64, or hex. **When you add a column
  that holds a secret, add it here.**
  """

  # Uses a per-test uploads root via application env.
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.{Auth, Content, Messaging, Moderation, Notification, Repo}
  alias Baudrate.Auth.{LoginAttempt, RecoveryCode, UserSession}
  alias Baudrate.Content.{ArticleImage, ArticleRevision, Board}
  alias Baudrate.DataPortability.{Archive, Files}
  alias Baudrate.Notification.PushSubscription
  alias Baudrate.Setup.User

  @base_url "https://bbs.example"
  @hex_a String.duplicate("a", 64)
  @hex_b String.duplicate("b", 64)

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    root =
      Path.join(System.tmp_dir!(), "baudrate-export-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "article_images"))
    File.mkdir_p!(Path.join(root, "avatars"))
    Application.put_env(:baudrate, :data_export_uploads_root, root)

    on_exit(fn ->
      Application.delete_env(:baudrate, :data_export_uploads_root)
      File.rm_rf(root)
    end)

    %{root: root, user: create_user("user")}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp create_user(role_name) do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "arch_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board(min_role) do
    uid = System.unique_integer([:positive])

    %Board{}
    |> Board.changeset(%{
      name: "Board #{uid}",
      slug: "board-#{uid}",
      min_role_to_view: min_role,
      min_role_to_post: if(min_role == "guest", do: "user", else: min_role)
    })
    |> Repo.insert!()
  end

  defp create_article(user, board, title, body) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          "title" => title,
          "body" => body,
          "slug" => "a-#{System.unique_integer([:positive])}",
          "user_id" => user.id
        },
        [board.id]
      )

    article
  end

  defp marker(label), do: "CANARY#{label}#{Base.encode16(:crypto.strong_rand_bytes(6))}"

  defp build!(user, opts \\ []) do
    {:ok, info} = Archive.build(user, Keyword.merge([base_url: @base_url], opts))
    {:ok, entries} = :zip.unzip(String.to_charlist(info.path), [:memory])
    Archive.cleanup(info)
    Map.new(entries, fn {name, bin} -> {List.to_string(name), bin} end)
  end

  defp json(entries, name), do: Jason.decode!(Map.fetch!(entries, name))

  defp encodings(marker) do
    [
      marker,
      Base.encode64(marker),
      Base.url_encode64(marker, padding: false),
      Base.encode16(marker, case: :lower),
      Base.encode16(marker, case: :upper)
    ]
  end

  defp export_temp_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "baudrate-export-"))
    |> Enum.reject(&String.starts_with?(&1, "baudrate-export-test-"))
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # The canary gate
  # ---------------------------------------------------------------------------

  test "no secret and no other person's data appears anywhere in the archive", %{user: user} do
    other = create_user("user")
    moderator = create_user("moderator")
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    public = create_board("guest")
    private = create_board("admin")

    m = %{
      hashed_password: marker("PWHASH"),
      totp_secret: marker("TOTP"),
      ap_private_key: marker("APKEY"),
      recovery_hash: marker("RECOVERY"),
      session_token: marker("SESSTOKEN"),
      session_refresh: marker("SESSREFRESH"),
      session_ip: marker("SESSIP"),
      session_ua: marker("SESSUA"),
      credential_id: marker("CREDID"),
      public_key: marker("PUBKEY"),
      push_endpoint: marker("PUSHEP"),
      push_p256dh: marker("P256DH"),
      push_auth: marker("PUSHAUTH"),
      active_invite: marker("INVITE"),
      login_ip: marker("LOGINIP"),
      dm_received: marker("DMRECV"),
      report_reason: marker("REPORT"),
      mod_revision: marker("MODREV"),
      private_board: marker("PRIVBOARD"),
      mod_deleted: marker("MODDEL"),
      notification: marker("NOTIF")
    }

    # Secrets on the user row.
    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [
        hashed_password: m.hashed_password,
        totp_secret: m.totp_secret,
        totp_enabled: true,
        ap_private_key_encrypted: m.ap_private_key
      ]
    )

    Repo.insert_all(RecoveryCode, [
      %{user_id: user.id, code_hash: m.recovery_hash, inserted_at: now}
    ])

    Repo.insert_all(UserSession, [
      %{
        user_id: user.id,
        token_hash: m.session_token,
        refresh_token_hash: m.session_refresh,
        expires_at: DateTime.add(now, 86_400),
        refreshed_at: now,
        ip_address: m.session_ip,
        user_agent: m.session_ua,
        inserted_at: now
      }
    ])

    {:ok, _} =
      Auth.create_webauthn_credential(user, %{
        credential_id: m.credential_id,
        public_key_cbor: m.public_key,
        sign_count: 0,
        label: "Visible Key Label"
      })

    Repo.insert!(
      PushSubscription.changeset(%PushSubscription{}, %{
        user_id: user.id,
        endpoint: "https://push.example/#{m.push_endpoint}",
        p256dh: m.push_p256dh,
        auth: m.push_auth
      })
    )

    naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("invite_codes", [
      %{
        code: m.active_invite,
        created_by_id: user.id,
        max_uses: 1,
        use_count: 0,
        revoked: false,
        expires_at: DateTime.add(now, 86_400),
        inserted_at: naive,
        updated_at: naive
      }
    ])

    Repo.insert_all(LoginAttempt, [
      %{username: user.username, ip_address: m.login_ip, success: false, inserted_at: now}
    ])

    # Other people's data.
    {:ok, conv} = Messaging.find_or_create_conversation(user, other)
    {:ok, _} = Messaging.create_message(conv, other, %{"body" => m.dm_received})
    {:ok, _} = Messaging.create_message(conv, user, %{"body" => "SENTDM-visible"})

    {:ok, _} =
      Moderation.create_report(%{
        reporter_id: other.id,
        reported_user_id: user.id,
        category: "spam",
        reason: m.report_reason
      })

    own = create_article(user, public, "Visible title", "VISIBLE-body")

    Repo.insert_all(ArticleRevision, [
      %{
        article_id: own.id,
        editor_id: moderator.id,
        title: "t",
        body: m.mod_revision,
        inserted_at: now
      }
    ])

    create_article(user, private, m.private_board, m.private_board)

    removed = create_article(user, public, m.mod_deleted, m.mod_deleted)
    {:ok, _} = Content.soft_delete_article(removed, deleted_by: moderator.id)

    {:ok, _} =
      Notification.create_notification(%{
        type: "mention",
        user_id: user.id,
        actor_user_id: other.id,
        data: %{"x" => m.notification}
      })

    entries = build!(Repo.reload!(user))
    blob = entries |> Map.values() |> IO.iodata_to_binary()

    # Positive controls: the test really reads archive contents.
    assert blob =~ "VISIBLE-body"
    assert blob =~ "SENTDM-visible"
    assert blob =~ "Visible Key Label"

    for {label, value} <- m, encoded <- encodings(value) do
      refute String.contains?(blob, encoded),
             "archive leaked #{label} (as #{inspect(encoded)})"
    end

    # The other user's username may appear as the DM counterpart handle, but
    # never their message, report, or IP.
    assert json(entries, "invites.json") |> hd() |> Map.fetch!("code") == nil
  end

  # ---------------------------------------------------------------------------
  # What is and is not exported
  # ---------------------------------------------------------------------------

  test "articles: visible boards only; self-deleted flagged; moderator or unknown deletions excluded",
       %{user: user} do
    moderator = create_user("moderator")
    public = create_board("guest")
    members = create_board("user")
    admins = create_board("admin")

    visible = create_article(user, public, "Public", "p")
    members_only = create_article(user, members, "Members", "m")
    create_article(user, admins, "Admins", "x")

    self_deleted = create_article(user, public, "Mine gone", "s")
    {:ok, _} = Content.soft_delete_article(self_deleted, deleted_by: user.id)

    mod_deleted = create_article(user, public, "Removed", "r")
    {:ok, _} = Content.soft_delete_article(mod_deleted, deleted_by: moderator.id)

    unknown = create_article(user, public, "Unknown", "u")
    {:ok, _} = Content.soft_delete_article(unknown)

    articles = user |> build!() |> json("articles.json")
    by_id = Map.new(articles, &{&1["id"], &1})

    assert Map.keys(by_id) |> Enum.sort() ==
             Enum.sort([visible.id, members_only.id, self_deleted.id])

    assert by_id[visible.id]["uri"] == visible.ap_id
    assert by_id[visible.id]["boards"] == [public.slug]
    assert by_id[visible.id]["deleted_at"] == nil
    assert by_id[self_deleted.id]["deleted_at"] != nil
  end

  test "interactions, comments and relationships: URIs only, visible targets only",
       %{user: user} do
    author = create_user("user")
    follower = create_user("user")
    blocked = create_user("user")
    public = create_board("guest")
    admins = create_board("admin")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    visible = create_article(author, public, "SECRETTITLE-visible", "b")
    hidden = create_article(author, admins, "SECRETTITLE-hidden", "b")

    for article <- [visible, hidden] do
      Repo.insert_all("article_likes", [
        %{
          article_id: article.id,
          user_id: user.id,
          ap_id: "#{@base_url}/like-#{article.id}",
          inserted_at: now,
          updated_at: now
        }
      ])

      Repo.insert_all("bookmarks", [
        %{article_id: article.id, user_id: user.id, inserted_at: now, updated_at: now}
      ])
    end

    {:ok, comment} =
      Content.create_comment(%{
        "body" => "my comment",
        "article_id" => visible.id,
        "user_id" => user.id
      })

    Repo.insert_all("user_follows", [
      %{
        user_id: user.id,
        followed_user_id: author.id,
        state: "accepted",
        ap_id: "#{@base_url}/follow-1",
        inserted_at: now,
        updated_at: now
      },
      %{
        user_id: follower.id,
        followed_user_id: user.id,
        state: "accepted",
        ap_id: "#{@base_url}/follow-2",
        inserted_at: now,
        updated_at: now
      }
    ])

    {:ok, _} = Auth.block_user(user, blocked)

    entries = build!(user)
    blob = entries |> Map.values() |> IO.iodata_to_binary()
    interactions = json(entries, "interactions.json")

    assert [%{"target" => liked}] = interactions["article_likes"]
    assert liked == visible.ap_id
    assert [%{"target" => bookmarked}] = interactions["bookmarks"]
    assert bookmarked == visible.ap_id

    # Other people's titles never appear, and nothing from the hidden board.
    refute blob =~ "SECRETTITLE"
    refute blob =~ hidden.slug

    assert [%{"body" => "my comment", "in_reply_to" => parent, "uri" => uri}] =
             json(entries, "comments.json")

    assert parent == visible.ap_id
    assert uri == Repo.reload!(comment).ap_id

    relationships = json(entries, "relationships.json")
    assert [%{"handle" => followed, "state" => "accepted"}] = relationships["following"]
    assert followed == author.username
    assert [%{"handle" => follower_handle}] = relationships["followers"]
    assert follower_handle == follower.username
    assert [%{"handle" => blocked_handle}] = relationships["blocks"]
    assert blocked_handle == blocked.username
  end

  test "messages: only the user's own messages, counterpart by handle", %{user: user} do
    other = create_user("user")
    {:ok, conv} = Messaging.find_or_create_conversation(user, other)
    {:ok, _} = Messaging.create_message(conv, user, %{"body" => "mine"})
    {:ok, _} = Messaging.create_message(conv, other, %{"body" => "theirs"})

    assert [%{"with" => %{"handle" => handle}, "messages_sent" => [%{"body" => "mine"}]}] =
             user |> build!() |> json("messages.json")

    assert handle == other.username
  end

  test "README is written in the user's preferred language", %{user: user} do
    {:ok, user} = Auth.update_preferred_locales(user, ["zh_TW"])
    readme = user |> build!() |> Map.fetch!("README.txt")

    expected =
      Gettext.with_locale(BaudrateWeb.Gettext, "zh_TW", fn ->
        Gettext.gettext(BaudrateWeb.Gettext, "Not included:")
      end)

    assert readme =~ expected
  end

  test "entry names come from fixed names and record ids only", %{user: user, root: root} do
    board = create_board("guest")
    article = create_article(user, board, "../../evil name.json", "b")
    File.write!(Path.join([root, "article_images", "#{@hex_a}.webp"]), "IMG")

    image =
      Repo.insert!(%ArticleImage{
        article_id: article.id,
        user_id: user.id,
        filename: "#{@hex_a}.webp",
        storage_path: "/nonexistent/old/release/#{@hex_a}.webp",
        width: 1,
        height: 1
      })

    names = user |> build!() |> Map.keys()

    assert "media/article_images/#{image.id}.webp" in names

    for name <- names do
      assert name =~ ~r{\A(README\.txt|[a-z_]+\.json|media/[a-z_]+/[0-9]+\.webp)\z}
    end
  end

  # ---------------------------------------------------------------------------
  # Path confinement
  # ---------------------------------------------------------------------------

  describe "media path confinement" do
    setup %{user: user, root: root} do
      board = create_board("guest")
      %{article: create_article(user, board, "With images", "b"), root: root}
    end

    defp add_image(article, user, filename) do
      Repo.insert!(%ArticleImage{
        article_id: article.id,
        user_id: user.id,
        filename: filename,
        storage_path: "unused",
        width: 1,
        height: 1
      })
    end

    test "traversal filenames and stored storage_path are never used",
         %{user: user, article: article} do
      secret = Path.join(System.tmp_dir!(), "baudrate-export-test-secret.env")
      File.write!(secret, "SECRET_KEY_BASE=CANARYENV")
      on_exit(fn -> File.rm(secret) end)

      add_image(article, user, "../../../../#{Path.basename(secret)}")

      Repo.insert!(%ArticleImage{
        article_id: article.id,
        user_id: user.id,
        filename: "#{@hex_b}.webp",
        storage_path: secret,
        width: 1,
        height: 1
      })

      entries = build!(user)
      refute entries |> Map.values() |> IO.iodata_to_binary() =~ "CANARYENV"
    end

    test "a symlinked file escaping the uploads root is skipped",
         %{user: user, article: article, root: root} do
      outside = Path.join(System.tmp_dir!(), "baudrate-export-test-outside.txt")
      File.write!(outside, "CANARYSYMLINK")
      on_exit(fn -> File.rm(outside) end)

      File.ln_s!(outside, Path.join([root, "article_images", "#{@hex_a}.webp"]))
      add_image(article, user, "#{@hex_a}.webp")

      refute user |> build!() |> Map.values() |> IO.iodata_to_binary() =~ "CANARYSYMLINK"
    end

    test "a symlinked directory component is not followed", %{root: root} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "baudrate-export-test-dir-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "#{@hex_a}.webp"), "CANARYDIR")
      on_exit(fn -> File.rm_rf(outside) end)

      File.rm_rf!(Path.join(root, "article_images"))
      File.ln_s!(outside, Path.join(root, "article_images"))

      assert Files.image_path("article_images", "#{@hex_a}.webp") == :error
    end

    test "a symlinked uploads root (as in production) is resolved and allowed", %{root: root} do
      link = root <> "-link"
      File.ln_s!(root, link)
      on_exit(fn -> File.rm(link) end)
      File.write!(Path.join([root, "article_images", "#{@hex_a}.webp"]), "IMG")

      Application.put_env(:baudrate, :data_export_uploads_root, link)

      assert {:ok, path} = Files.image_path("article_images", "#{@hex_a}.webp")
      assert File.read!(path) == "IMG"
    end

    test "avatars: every existing rendition is included", %{user: user, root: root} do
      File.mkdir_p!(Path.join([root, "avatars", @hex_a]))
      File.write!(Path.join([root, "avatars", @hex_a, "120.webp"]), "A120")
      File.write!(Path.join([root, "avatars", @hex_a, "48.webp"]), "A48")
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [avatar_id: @hex_a])

      entries = user |> Repo.reload!() |> build!()

      assert entries["media/avatar/120.webp"] == "A120"
      assert entries["media/avatar/48.webp"] == "A48"
      refute Map.has_key?(entries, "media/avatar/24.webp")
    end
  end

  # ---------------------------------------------------------------------------
  # Limits
  # ---------------------------------------------------------------------------

  describe "limits" do
    test "a build is refused while another holds the slot", %{user: user} do
      config = Repo.config() |> Keyword.drop([:pool, :pool_size, :ownership_timeout])
      {:ok, conn} = Postgrex.start_link(config)

      key = Archive.lock_key()
      Postgrex.query!(conn, "SELECT pg_advisory_lock($1)", [key])

      try do
        assert {:error, :busy} = Archive.build(user, base_url: @base_url)
      after
        Postgrex.query!(conn, "SELECT pg_advisory_unlock($1)", [key])
        GenServer.stop(conn)
      end

      assert {:ok, info} = Archive.build(user, base_url: @base_url)
      Archive.cleanup(info)
    end

    test "a deadline breach aborts and leaves no temp files", %{user: user} do
      before = export_temp_dirs()

      assert {:error, :timeout} = Archive.build(user, base_url: @base_url, timeout_ms: -1)
      assert export_temp_dirs() == before
    end

    test "the size cap aborts and leaves no temp files", %{user: user} do
      before = export_temp_dirs()

      assert {:error, :too_large} = Archive.build(user, base_url: @base_url, max_bytes: 10)
      assert export_temp_dirs() == before
    end

    test "the archive is private and cleanup removes it", %{user: user} do
      {:ok, info} = Archive.build(user, base_url: @base_url)

      assert File.stat!(info.path).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(info.dir).mode |> Bitwise.band(0o777) == 0o700
      refute String.contains?(info.path, "priv/static")

      Archive.cleanup(info)
      refute File.exists?(info.dir)
    end
  end
end
