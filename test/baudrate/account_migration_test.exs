defmodule Baudrate.AccountMigrationTest do
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.AccountMigration
  alias Baudrate.Federation.{HTTPClient, KeyStore, RemoteActor}
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Repo
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "mover_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    %{user: Repo.preload(user, :role)}
  end

  # A freshly fetched actor is served from the cache, so no HTTP is needed.
  defp remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(
      Map.merge(
        %{
          ap_id: "https://remote.example/users/alias-#{uid}",
          username: "alias_#{uid}",
          domain: "remote.example",
          public_key_pem: elem(KeyStore.generate_keypair(), 0),
          inbox: "https://remote.example/users/alias-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp notices(user, type) do
    Repo.all(from(n in NotificationSchema, where: n.user_id == ^user.id and n.type == ^type))
  end

  describe "add_alias/2" do
    test "stores the resolved actor id and notifies the owner", %{user: user} do
      actor = remote_actor()

      assert {:ok, updated, %RemoteActor{id: id}} =
               AccountMigration.add_alias(user, "  #{actor.ap_id}  ")

      assert id == actor.id
      assert updated.also_known_as == [actor.ap_id]

      assert [%{data: %{"label" => label}}] = notices(user, "account_alias_added")
      assert label == "@#{actor.username}@#{actor.domain}"
    end

    test "resolves an @user@domain handle through WebFinger", %{user: user} do
      {public_pem, _} = KeyStore.generate_keypair()
      ap_id = "https://handle.example/users/carol"

      Req.Test.stub(HTTPClient, fn conn ->
        if String.contains?(conn.request_path, ".well-known/webfinger") do
          Req.Test.json(conn, %{
            "subject" => "acct:carol@handle.example",
            "links" => [
              %{"rel" => "self", "type" => "application/activity+json", "href" => ap_id}
            ]
          })
        else
          Req.Test.json(conn, %{
            "id" => ap_id,
            "type" => "Person",
            "preferredUsername" => "carol",
            "inbox" => "#{ap_id}/inbox",
            "publicKey" => %{
              "id" => "#{ap_id}#main-key",
              "owner" => ap_id,
              "publicKeyPem" => public_pem
            }
          })
        end
      end)

      assert {:ok, updated, _actor} = AccountMigration.add_alias(user, "@carol@handle.example")
      assert updated.also_known_as == [ap_id]
    end

    test "refuses groups, bots and other non-person actors", %{user: user} do
      for type <- ["Group", "Service", "Application"] do
        actor = remote_actor(%{actor_type: type})
        assert {:error, :not_a_person} = AccountMigration.add_alias(user, actor.ap_id)
      end

      assert Repo.reload!(user).also_known_as == []
    end

    test "refuses duplicates and more than the maximum", %{user: user} do
      actors = for _ <- 1..AccountMigration.max_aliases(), do: remote_actor()

      for actor <- actors do
        assert {:ok, _, _} = AccountMigration.add_alias(user, actor.ap_id)
      end

      assert {:error, :already_added} = AccountMigration.add_alias(user, hd(actors).ap_id)
      assert {:error, :too_many_aliases} = AccountMigration.add_alias(user, remote_actor().ap_id)
      assert length(Repo.reload!(user).also_known_as) == AccountMigration.max_aliases()
    end

    test "refuses malformed input and local actors without storing anything", %{user: user} do
      assert {:error, :invalid_input} = AccountMigration.add_alias(user, "")
      assert {:error, :invalid_input} = AccountMigration.add_alias(user, "not an account")
      assert {:error, :invalid_input} = AccountMigration.add_alias(user, "http://plain.example/u")

      # The test endpoint is plain http, which is refused as input; in production
      # the https URL reaches ActorResolver, which refuses local actors.
      local = BaudrateWeb.Endpoint.url() <> "/ap/users/#{user.username}"
      assert {:error, reason} = AccountMigration.add_alias(user, local)
      assert reason in [:not_found, :invalid_input]

      assert Repo.reload!(user).also_known_as == []
      assert notices(user, "account_alias_added") == []
    end

    test "refuses changes while the account has moved", %{user: user} do
      Repo.update_all(from(u in Setup.User, where: u.id == ^user.id),
        set: [moved_to: "https://new.example/users/me"]
      )

      assert {:error, :moved} = AccountMigration.add_alias(user, remote_actor().ap_id)
    end
  end

  describe "remove_alias/2" do
    test "removes an alias and notifies the owner", %{user: user} do
      actor = remote_actor()
      {:ok, _, _} = AccountMigration.add_alias(user, actor.ap_id)

      assert {:ok, updated} = AccountMigration.remove_alias(user, actor.ap_id)
      assert updated.also_known_as == []
      assert [_] = notices(user, "account_alias_removed")
    end

    test "an alias the account does not have is not found", %{user: user} do
      assert {:error, :not_found} =
               AccountMigration.remove_alias(user, "https://remote.example/users/nobody")

      assert notices(user, "account_alias_removed") == []
    end
  end

  test "list_aliases/1 pairs each alias with its cached actor, in order", %{user: user} do
    first = remote_actor()
    second = remote_actor()
    {:ok, _, _} = AccountMigration.add_alias(user, first.ap_id)
    {:ok, _, _} = AccountMigration.add_alias(user, second.ap_id)

    assert [%{ap_id: a, actor: %RemoteActor{}}, %{ap_id: b}] = AccountMigration.list_aliases(user)
    assert [a, b] == [first.ap_id, second.ap_id]
  end

  test "moved?/1" do
    refute AccountMigration.moved?(nil)
    refute AccountMigration.moved?(%Setup.User{})
    assert AccountMigration.moved?(%Setup.User{moved_to: "https://new.example/users/me"})
  end

  # ---------------------------------------------------------------------------
  # Moving away
  # ---------------------------------------------------------------------------

  defp make_eligible(user) do
    {:ok, _} = Baudrate.Auth.enable_totp(user, Baudrate.Auth.generate_totp_secret())
    past = DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.truncate(:second)

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id),
      set: [totp_enabled_at: past]
    )

    Repo.reload!(user) |> Repo.preload(:role, force: true)
  end

  defp secret_for(user) do
    Baudrate.Auth.decrypt_totp_secret(Repo.reload!(user))
  end

  defp creds(user, password \\ "Password123!x"),
    do: %{password: password, code: totp_code(secret_for(user))}

  @opts [ip_address: "203.0.113.30", user_agent: "Mozilla/5.0 (X11; Linux x86_64) Firefox/130.0"]

  # Serves a destination actor document. `aka` is its alsoKnownAs.
  defp stub_target(ap_id, opts) do
    {public_pem, _} = KeyStore.generate_keypair()

    doc =
      %{
        "id" => ap_id,
        "type" => Keyword.get(opts, :type, "Person"),
        "preferredUsername" => ap_id |> String.split("/") |> List.last(),
        "inbox" => "#{ap_id}/inbox",
        "alsoKnownAs" => Keyword.get(opts, :aka, []),
        "publicKey" => %{
          "id" => "#{ap_id}#main-key",
          "owner" => ap_id,
          "publicKeyPem" => public_pem
        }
      }
      |> then(fn d ->
        if moved = opts[:moved_to], do: Map.put(d, "movedTo", moved), else: d
      end)

    Req.Test.stub(HTTPClient, fn conn -> Req.Test.json(conn, doc) end)
  end

  defp local_uri(user), do: Baudrate.Federation.actor_uri(:user, user.username)

  describe "move_eligibility/1" do
    test "needs TOTP that is at least 7 days old", %{user: user} do
      assert {:error, :totp_required} = AccountMigration.move_eligibility(user)

      {:ok, _} = Baudrate.Auth.enable_totp(user, Baudrate.Auth.generate_totp_secret())

      assert {:error, {:totp_too_new, 7}} =
               AccountMigration.move_eligibility(Repo.reload!(user))

      assert :ok = AccountMigration.move_eligibility(make_eligible(user))
    end

    test "refuses staff, board moderators and moved accounts", %{user: user} do
      user = make_eligible(user)

      for role_name <- ["admin", "moderator"] do
        role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))
        staff = %{user | role: role}
        assert {:error, :staff} = AccountMigration.move_eligibility(staff)
      end

      board =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{
          name: "Moved board",
          slug: "moved-board-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      moderator =
        Repo.insert!(%Baudrate.Content.BoardModerator{board_id: board.id, user_id: user.id})

      assert {:error, :board_moderator} = AccountMigration.move_eligibility(user)
      Repo.delete!(moderator)

      assert {:error, :moved} =
               AccountMigration.move_eligibility(%{user | moved_to: "https://new.example/u/me"})
    end

    test "allows one sent move per 30 days", %{user: user} do
      user = make_eligible(user)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      sent_at = DateTime.add(now, -10 * 86_400)

      Repo.insert!(%AccountMigration.AccountMove{
        user_id: user.id,
        target_ap_id: "https://new.example/users/me",
        status: "sent",
        requested_at: DateTime.add(sent_at, -86_400),
        send_after: sent_at,
        sent_at: sent_at
      })

      assert {:error, {:recently_moved, at}} = AccountMigration.move_eligibility(user)
      assert DateTime.diff(at, now, :day) in 19..20
    end
  end

  describe "verify_move_target/2" do
    test "accepts a person that lists this account as an alias", %{user: user} do
      stub_target("https://new.example/users/me", aka: [local_uri(user)])

      assert {:ok, %RemoteActor{ap_id: "https://new.example/users/me"}} =
               AccountMigration.verify_move_target(user, "https://new.example/users/me")
    end

    test "refuses a target without the alias, a moved target and non-persons", %{user: user} do
      stub_target("https://new.example/users/a", aka: [])

      assert {:error, :alias_not_claimed} =
               AccountMigration.verify_move_target(user, "https://new.example/users/a")

      stub_target("https://new.example/users/b",
        aka: [local_uri(user)],
        moved_to: "https://elsewhere.example/users/b"
      )

      assert {:error, :target_moved} =
               AccountMigration.verify_move_target(user, "https://new.example/users/b")

      stub_target("https://new.example/users/c", aka: [local_uri(user)], type: "Group")

      assert {:error, :not_a_person} =
               AccountMigration.verify_move_target(user, "https://new.example/users/c")
    end
  end

  describe "request_move/4" do
    test "creates a pending move that is sent after 24 hours, with a notice", %{user: user} do
      user = make_eligible(user)
      stub_target("https://new.example/users/me", aka: [local_uri(user)])

      assert {:ok, move} =
               AccountMigration.request_move(
                 user,
                 "https://new.example/users/me",
                 creds(user),
                 @opts
               )

      assert move.status == "pending"
      assert move.target_ap_id == "https://new.example/users/me"
      assert DateTime.diff(move.send_after, move.requested_at) == 24 * 3600
      assert move.requested_user_agent_family == "Firefox on Linux"

      assert [%{data: %{"label" => "@me@new.example", "browser" => "Firefox on Linux"}}] =
               notices(user, "account_move_requested")

      assert %{label: "@me@new.example"} = AccountMigration.active_move_summary(user.id)

      forget_totp_use(user)

      assert {:error, :pending_move_exists} =
               AccountMigration.request_move(
                 user,
                 "https://new.example/users/me",
                 creds(user),
                 @opts
               )
    end

    test "checks the target before credentials and records nothing on failure", %{user: user} do
      user = make_eligible(user)
      stub_target("https://new.example/users/me", aka: [])

      assert {:error, :alias_not_claimed} =
               AccountMigration.request_move(
                 user,
                 "https://new.example/users/me",
                 creds(user, "wrong"),
                 @opts
               )

      assert Repo.aggregate(Baudrate.Auth.LoginAttempt, :count) == 0

      stub_target("https://new.example/users/me", aka: [local_uri(user)])

      assert {:error, :invalid_credentials} =
               AccountMigration.request_move(
                 user,
                 "https://new.example/users/me",
                 creds(user, "wrong"),
                 @opts
               )

      assert AccountMigration.active_move(user.id) == nil
      assert notices(user, "account_move_requested") == []
    end

    test "an ineligible account is refused before anything else", %{user: user} do
      assert {:error, :totp_required} =
               AccountMigration.request_move(user, "https://new.example/users/me", %{}, @opts)
    end
  end

  describe "cancelling" do
    setup %{user: user} do
      user = make_eligible(user)
      stub_target("https://new.example/users/me", aka: [local_uri(user)])

      {:ok, move} =
        AccountMigration.request_move(user, "https://new.example/users/me", creds(user), @opts)

      forget_totp_use(user)
      %{user: user, move: move}
    end

    test "the owner can cancel; others cannot", %{user: user, move: move} do
      assert {:error, :not_found} = AccountMigration.cancel_move(user.id + 1_000_000, move.id)

      assert {:ok, %{status: "cancelled", cancel_reason: "user"}} =
               AccountMigration.cancel_move(user.id, move.id)

      assert [%{data: %{"reason" => "user"}}] = notices(user, "account_move_cancelled")
      assert {:error, :not_found} = AccountMigration.cancel_move(user.id, move.id)
      assert AccountMigration.active_move_summary(user.id) == nil
    end

    test "sign out everywhere cancels a pending move", %{user: user, move: move} do
      {:ok, token, _refresh} = Baudrate.Auth.create_user_session(user.id)
      keep = Baudrate.Auth.session_id_by_token(token)

      {:ok, _} = Baudrate.Auth.sign_out_other_sessions(user, keep)
      assert %{status: "cancelled", cancel_reason: "signed_out_everywhere"} = Repo.reload!(move)
    end

    test "disabling TOTP cancels a pending move", %{user: user, move: move} do
      {:ok, _} = Baudrate.Auth.disable_totp(Repo.reload!(user))
      assert %{status: "cancelled", cancel_reason: "totp_changed"} = Repo.reload!(move)
    end

    test "a ban cancels a pending move", %{user: user, move: move} do
      {:ok, _, _} = Baudrate.Auth.ban_user(user, user.id + 1_000_000)
      assert %{status: "cancelled", cancel_reason: "banned"} = Repo.reload!(move)
    end
  end

  test "target_labels/1 uses cached handles and falls back to the URI" do
    actor = remote_actor()
    unknown = "https://unknown.example/users/x"

    labels = AccountMigration.target_labels([actor.ap_id, unknown])

    assert labels[actor.ap_id] == "@#{actor.username}@#{actor.domain}"
    assert labels[unknown] == unknown
  end
end
