defmodule Baudrate.AuthTest do
  use Baudrate.DataCase

  alias Baudrate.Auth
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name, opts \\ []) do
    role = Repo.one!(from r in Role, where: r.name == ^role_name)
    username = Keyword.get(opts, :username, "user_#{System.unique_integer([:positive])}")
    password = Keyword.get(opts, :password, "Password123!x")

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => username,
        "password" => password,
        "password_confirmation" => password,
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  describe "authenticate_by_password/2" do
    test "returns user with valid credentials" do
      user = create_user("admin", username: "admin_user", password: "SecurePass1!!")
      assert {:ok, authed} = Auth.authenticate_by_password("admin_user", "SecurePass1!!")
      assert authed.id == user.id
      assert authed.role.name == "admin"
    end

    test "returns error with wrong password" do
      create_user("admin", username: "admin2", password: "SecurePass1!!")

      assert {:error, :invalid_credentials} =
               Auth.authenticate_by_password("admin2", "WrongPass1!!")
    end

    test "returns error with nonexistent username" do
      assert {:error, :invalid_credentials} =
               Auth.authenticate_by_password("nobody", "WrongPass1!!")
    end
  end

  describe "totp_policy/1" do
    test "admin requires TOTP" do
      assert Auth.totp_policy("admin") == :required
    end

    test "moderator requires TOTP" do
      assert Auth.totp_policy("moderator") == :required
    end

    test "user has optional TOTP" do
      assert Auth.totp_policy("user") == :optional
    end

    test "guest has disabled TOTP" do
      assert Auth.totp_policy("guest") == :disabled
    end
  end

  describe "login_next_step/1" do
    test "returns :totp_verify when TOTP is enabled" do
      user = create_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, user} = Auth.enable_totp(user, secret)
      user = Repo.preload(user, :role)
      assert Auth.login_next_step(user) == :totp_verify
    end

    test "returns :totp_setup for admin without TOTP" do
      user = create_user("admin")
      assert Auth.login_next_step(user) == :totp_setup
    end

    test "returns :totp_setup for moderator without TOTP" do
      user = create_user("moderator")
      assert Auth.login_next_step(user) == :totp_setup
    end

    test "returns :authenticated for user without TOTP" do
      user = create_user("user")
      assert Auth.login_next_step(user) == :authenticated
    end

    test "returns :authenticated for guest" do
      user = create_user("guest")
      assert Auth.login_next_step(user) == :authenticated
    end
  end

  describe "TOTP operations" do
    test "generate_totp_secret returns 20 bytes" do
      secret = Auth.generate_totp_secret()
      assert byte_size(secret) == 20
    end

    test "totp_uri generates valid otpauth URI" do
      secret = Auth.generate_totp_secret()
      uri = Auth.totp_uri(secret, "testuser")
      assert String.starts_with?(uri, "otpauth://totp/Baudrate:testuser")
      assert uri =~ "issuer=Baudrate"
    end

    test "totp_qr_data_uri generates a data URI" do
      secret = Auth.generate_totp_secret()
      uri = Auth.totp_uri(secret, "testuser")
      data_uri = Auth.totp_qr_data_uri(uri)
      assert String.starts_with?(data_uri, "data:image/svg+xml;base64,")
    end

    test "valid_totp? validates correct code" do
      secret = Auth.generate_totp_secret()
      code = NimbleTOTP.verification_code(secret)
      assert Auth.valid_totp?(secret, code)
    end

    test "valid_totp? rejects incorrect code" do
      secret = Auth.generate_totp_secret()
      refute Auth.valid_totp?(secret, "000000")
    end

    test "enable_totp stores encrypted secret and enables TOTP" do
      user = create_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, updated} = Auth.enable_totp(user, secret)
      assert updated.totp_enabled == true
      # Secret is stored encrypted, not plaintext
      assert updated.totp_secret != secret
      # But can be decrypted back
      assert Auth.decrypt_totp_secret(updated) == secret
    end
  end

  describe "verify_password/2" do
    test "returns true for correct password" do
      user = create_user("user", password: "SecurePass1!!")
      assert Auth.verify_password(user, "SecurePass1!!")
    end

    test "returns false for wrong password" do
      user = create_user("user", password: "SecurePass1!!")
      refute Auth.verify_password(user, "WrongPass1!!")
    end

    test "returns false for nil user" do
      refute Auth.verify_password(nil, "anything")
    end
  end

  describe "disable_totp/1" do
    test "clears TOTP secret and disables TOTP" do
      user = create_user("user")
      secret = Auth.generate_totp_secret()
      {:ok, user} = Auth.enable_totp(user, secret)
      assert user.totp_enabled

      {:ok, user} = Auth.disable_totp(user)
      refute user.totp_enabled
      assert is_nil(user.totp_secret)
    end
  end

  describe "delete_all_sessions_for_user/1" do
    test "deletes all sessions for a user" do
      user = create_user("user")
      {:ok, _t1, _r1} = Auth.create_user_session(user.id)
      {:ok, _t2, _r2} = Auth.create_user_session(user.id)

      assert {2, _} = Auth.delete_all_sessions_for_user(user.id)
    end

    test "does not affect other users' sessions" do
      user1 = create_user("user", username: "user1")
      user2 = create_user("user", username: "user2")
      {:ok, token, _r} = Auth.create_user_session(user1.id)
      {:ok, _t2, _r2} = Auth.create_user_session(user2.id)

      Auth.delete_all_sessions_for_user(user2.id)

      assert {:ok, _} = Auth.get_user_by_session_token(token)
    end
  end

  describe "generate_recovery_codes/1" do
    test "generates 10 recovery codes" do
      user = create_user("user")
      codes = Auth.generate_recovery_codes(user)
      assert length(codes) == 10
    end

    test "codes are in xxxx-xxxx base32 format" do
      user = create_user("user")
      codes = Auth.generate_recovery_codes(user)

      for code <- codes do
        assert String.match?(code, ~r/^[a-z2-7]{4}-[a-z2-7]{4}$/)
      end
    end

    test "codes have no duplicates" do
      user = create_user("user")
      codes = Auth.generate_recovery_codes(user)
      assert length(Enum.uniq(codes)) == length(codes)
    end

    test "replaces old codes when regenerated" do
      user = create_user("user")
      old_codes = Auth.generate_recovery_codes(user)
      new_codes = Auth.generate_recovery_codes(user)

      # Old codes should no longer work
      for code <- old_codes do
        assert Auth.verify_recovery_code(user, code) == :error
      end

      # New codes should work
      [first | _] = new_codes
      assert Auth.verify_recovery_code(user, first) == :ok
    end
  end

  describe "verify_recovery_code/2" do
    test "accepts valid unused code" do
      user = create_user("user")
      [code | _] = Auth.generate_recovery_codes(user)
      assert Auth.verify_recovery_code(user, code) == :ok
    end

    test "rejects already-used code" do
      user = create_user("user")
      [code | _] = Auth.generate_recovery_codes(user)
      assert Auth.verify_recovery_code(user, code) == :ok
      assert Auth.verify_recovery_code(user, code) == :error
    end

    test "rejects invalid code" do
      user = create_user("user")
      Auth.generate_recovery_codes(user)
      assert Auth.verify_recovery_code(user, "zzzz-zzzz") == :error
    end

    test "rejects nil code" do
      user = create_user("user")
      assert Auth.verify_recovery_code(user, nil) == :error
    end

    test "is case-insensitive" do
      user = create_user("user")
      [code | _] = Auth.generate_recovery_codes(user)
      assert Auth.verify_recovery_code(user, String.upcase(code)) == :ok
    end

    test "accepts code without dash" do
      user = create_user("user")
      [code | _] = Auth.generate_recovery_codes(user)
      assert Auth.verify_recovery_code(user, String.replace(code, "-", "")) == :ok
    end
  end

  describe "update_avatar/2" do
    test "sets avatar_id on user" do
      user = create_user("user")
      assert is_nil(user.avatar_id)

      {:ok, updated} = Auth.update_avatar(user, "abc123def456")
      assert updated.avatar_id == "abc123def456"
    end

    test "replaces existing avatar_id" do
      user = create_user("user")
      {:ok, user} = Auth.update_avatar(user, "old_id")
      {:ok, updated} = Auth.update_avatar(user, "new_id")
      assert updated.avatar_id == "new_id"
    end
  end

  describe "remove_avatar/1" do
    test "sets avatar_id to nil" do
      user = create_user("user")
      {:ok, user} = Auth.update_avatar(user, "some_avatar_id")
      assert user.avatar_id == "some_avatar_id"

      {:ok, updated} = Auth.remove_avatar(user)
      assert is_nil(updated.avatar_id)
    end

    test "is safe when avatar_id is already nil" do
      user = create_user("user")
      assert is_nil(user.avatar_id)

      {:ok, updated} = Auth.remove_avatar(user)
      assert is_nil(updated.avatar_id)
    end
  end

  describe "register_user/1" do
    test "creates user with active status in open mode" do
      Repo.insert!(%Baudrate.Setup.Setting{key: "registration_mode", value: "open"})

      assert {:ok, user, codes} =
               Auth.register_user(%{
                 "username" => "openuser",
                 "password" => "SecurePass1!!",
                 "password_confirmation" => "SecurePass1!!",
                 "terms_accepted" => "true"
               })

      assert user.status == "active"
      assert user.role_id != nil
      assert length(codes) == 10

      role = Repo.preload(user, :role).role
      assert role.name == "user"
    end

    test "creates user with pending status in approval mode" do
      assert {:ok, user, _codes} =
               Auth.register_user(%{
                 "username" => "pendinguser",
                 "password" => "SecurePass1!!",
                 "password_confirmation" => "SecurePass1!!",
                 "terms_accepted" => "true"
               })

      assert user.status == "pending"
    end

    test "returns error for invalid data" do
      assert {:error, _changeset} =
               Auth.register_user(%{
                 "username" => "",
                 "password" => "short",
                 "password_confirmation" => "short"
               })
    end
  end

  describe "approve_user/1" do
    test "sets pending user to active" do
      {:ok, user, _codes} =
        Auth.register_user(%{
          "username" => "toapprove",
          "password" => "SecurePass1!!",
          "password_confirmation" => "SecurePass1!!",
          "terms_accepted" => "true"
        })

      assert user.status == "pending"

      {:ok, approved} = Auth.approve_user(user)
      assert approved.status == "active"
    end
  end

  describe "list_pending_users/0" do
    test "returns only pending users" do
      {:ok, _pending, _codes} =
        Auth.register_user(%{
          "username" => "pending1",
          "password" => "SecurePass1!!",
          "password_confirmation" => "SecurePass1!!",
          "terms_accepted" => "true"
        })

      _active = create_user("user")

      pending = Auth.list_pending_users()
      assert length(pending) == 1
      assert hd(pending).username == "pending1"
    end

    test "returns empty list when no pending users" do
      assert Auth.list_pending_users() == []
    end
  end

  describe "user_active?/1" do
    test "returns true for active user" do
      user = create_user("user")
      assert Auth.user_active?(user)
    end

    test "returns false for pending user" do
      {:ok, user, _codes} =
        Auth.register_user(%{
          "username" => "pendcheck",
          "password" => "SecurePass1!!",
          "password_confirmation" => "SecurePass1!!",
          "terms_accepted" => "true"
        })

      refute Auth.user_active?(user)
    end
  end

  describe "can_create_content?/1" do
    test "returns true for active user with create_content permission" do
      user = create_user("user")
      assert Auth.can_create_content?(user)
    end

    test "returns false for pending user" do
      {:ok, user, _codes} =
        Auth.register_user(%{
          "username" => "pendcreate",
          "password" => "SecurePass1!!",
          "password_confirmation" => "SecurePass1!!",
          "terms_accepted" => "true"
        })

      user = Repo.preload(user, :role)
      refute Auth.can_create_content?(user)
    end

    test "returns false for guest role" do
      user = create_user("guest")
      refute Auth.can_create_content?(user)
    end
  end

  describe "get_user/1" do
    test "returns user with role preloaded" do
      user = create_user("admin")
      found = Auth.get_user(user.id)
      assert found.id == user.id
      assert found.role.name == "admin"
    end

    test "returns nil for nonexistent ID" do
      assert Auth.get_user(-1) == nil
    end
  end

  describe "search_users/2" do
    test "finds users by partial username match" do
      create_user("user", username: "alice")
      create_user("user", username: "alicia")
      create_user("user", username: "bob")

      results = Auth.search_users("ali")
      usernames = Enum.map(results, & &1.username)
      assert "alice" in usernames
      assert "alicia" in usernames
      refute "bob" in usernames
    end

    test "only returns active users" do
      create_user("user", username: "activeuser")

      {:ok, pending, _codes} =
        Auth.register_user(%{
          "username" => "pendinguser",
          "password" => "SecurePass1!!",
          "password_confirmation" => "SecurePass1!!",
          "terms_accepted" => "true"
        })

      # pendinguser has status "pending" (default approval_required mode)
      assert pending.status == "pending"

      results = Auth.search_users("user")
      usernames = Enum.map(results, & &1.username)
      assert "activeuser" in usernames
      refute "pendinguser" in usernames
    end

    test "respects :exclude_id option" do
      user = create_user("user", username: "myself")
      create_user("user", username: "myself2")

      results = Auth.search_users("myself", exclude_id: user.id)
      usernames = Enum.map(results, & &1.username)
      refute "myself" in usernames
      assert "myself2" in usernames
    end

    test "respects :limit option" do
      for i <- 1..5, do: create_user("user", username: "search_user_#{i}")

      results = Auth.search_users("search_user", limit: 3)
      assert length(results) == 3
    end

    test "returns empty list for short or non-matching query" do
      create_user("user", username: "testuser")
      assert Auth.search_users("zzzznotfound") == []
    end

    test "sanitizes SQL wildcards in search term" do
      create_user("user", username: "normal_user")
      # Searching for literal "%" should not match everything
      results = Auth.search_users("%")
      refute Enum.any?(results, &(&1.username == "normal_user"))
    end
  end

  describe "update_display_name/2" do
    test "sets a display name" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_display_name(user, "John Doe")
      assert updated.display_name == "John Doe"
      assert Repo.get!(User, user.id).display_name == "John Doe"
    end

    test "clears display name to nil with empty string" do
      user = create_user("user")
      {:ok, user} = Auth.update_display_name(user, "John Doe")
      assert {:ok, updated} = Auth.update_display_name(user, "")
      assert updated.display_name == nil
    end

    test "clears display name to nil with nil" do
      user = create_user("user")
      {:ok, user} = Auth.update_display_name(user, "John Doe")
      assert {:ok, updated} = Auth.update_display_name(user, nil)
      assert updated.display_name == nil
    end

    test "enforces 64-character limit" do
      user = create_user("user")
      long_name = String.duplicate("あ", 65)
      assert {:ok, updated} = Auth.update_display_name(user, long_name)
      assert String.length(updated.display_name) == 64
    end

    test "strips HTML tags" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_display_name(user, "<b>Bold</b> Name")
      assert updated.display_name == "Bold Name"
    end

    test "removes control characters" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_display_name(user, "Hello\x00World\x7F")
      assert updated.display_name == "HelloWorld"
    end

    test "removes bidi override characters" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_display_name(user, "Hello\u202AWorld\u202C")
      assert updated.display_name == "HelloWorld"
    end

    test "collapses whitespace" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_display_name(user, "  John   Doe  ")
      assert updated.display_name == "John Doe"
    end

    test "whitespace-only becomes nil" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_display_name(user, "   ")
      assert updated.display_name == nil
    end
  end

  describe "update_dm_access/2" do
    test "sets dm_access to 'anyone'" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_dm_access(user, "anyone")
      assert updated.dm_access == "anyone"
      assert Repo.get!(Setup.User, user.id).dm_access == "anyone"
    end

    test "sets dm_access to 'followers'" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_dm_access(user, "followers")
      assert updated.dm_access == "followers"
      assert Repo.get!(Setup.User, user.id).dm_access == "followers"
    end

    test "sets dm_access to 'nobody'" do
      user = create_user("user")
      assert {:ok, updated} = Auth.update_dm_access(user, "nobody")
      assert updated.dm_access == "nobody"
      assert Repo.get!(Setup.User, user.id).dm_access == "nobody"
    end

    test "returns error changeset for invalid value" do
      user = create_user("user")
      assert {:error, changeset} = Auth.update_dm_access(user, "invalid")
      assert %{dm_access: _} = errors_on(changeset)
    end
  end

  describe "block_user/2 and unblock_user/2" do
    test "blocks and unblocks a local user" do
      user = create_user("user")
      target = create_user("user")

      assert {:ok, block} = Auth.block_user(user, target)
      assert block.user_id == user.id
      assert block.blocked_user_id == target.id

      assert Auth.blocked?(user, target)
      refute Auth.blocked?(target, user)

      {1, nil} = Auth.unblock_user(user, target)
      refute Auth.blocked?(user, target)
    end

    test "prevents duplicate blocks" do
      user = create_user("user")
      target = create_user("user")

      assert {:ok, _} = Auth.block_user(user, target)
      assert {:error, _} = Auth.block_user(user, target)
    end
  end

  describe "block_remote_actor/2 and unblock_remote_actor/2" do
    test "blocks and unblocks a remote actor" do
      user = create_user("user")
      ap_id = "https://remote.example/users/someone"

      assert {:ok, block} = Auth.block_remote_actor(user, ap_id)
      assert block.blocked_actor_ap_id == ap_id

      assert Auth.blocked?(user, ap_id)

      {1, nil} = Auth.unblock_remote_actor(user, ap_id)
      refute Auth.blocked?(user, ap_id)
    end
  end

  describe "list_blocks/1" do
    test "lists all blocks for a user" do
      user = create_user("user")
      target = create_user("user")
      ap_id = "https://remote.example/users/actor"

      {:ok, _} = Auth.block_user(user, target)
      {:ok, _} = Auth.block_remote_actor(user, ap_id)

      blocks = Auth.list_blocks(user)
      assert length(blocks) == 2
    end
  end

  describe "user_blocked_by?/2" do
    test "checks reverse block relationship" do
      user = create_user("user")
      target = create_user("user")

      {:ok, _} = Auth.block_user(user, target)

      assert Auth.user_blocked_by?(target.id, user.id)
      refute Auth.user_blocked_by?(user.id, target.id)
    end
  end

  describe "blocked_user_ids/1 and blocked_actor_ap_ids/1" do
    test "returns lists of blocked IDs" do
      user = create_user("user")
      target = create_user("user")
      ap_id = "https://remote.example/users/actor"

      {:ok, _} = Auth.block_user(user, target)
      {:ok, _} = Auth.block_remote_actor(user, ap_id)

      assert target.id in Auth.blocked_user_ids(user)
      assert ap_id in Auth.blocked_actor_ap_ids(user)
    end
  end

  # --- User Mutes ---

  describe "mute_user/2 and unmute_user/2" do
    test "mutes and unmutes a local user" do
      user = create_user("user")
      target = create_user("user")

      assert {:ok, mute} = Auth.mute_user(user, target)
      assert mute.user_id == user.id
      assert mute.muted_user_id == target.id

      assert Auth.muted?(user, target)
      refute Auth.muted?(target, user)

      {1, nil} = Auth.unmute_user(user, target)
      refute Auth.muted?(user, target)
    end

    test "prevents duplicate mutes" do
      user = create_user("user")
      target = create_user("user")

      assert {:ok, _} = Auth.mute_user(user, target)
      assert {:error, _} = Auth.mute_user(user, target)
    end

    test "prevents self-mute" do
      user = create_user("user")
      assert {:error, changeset} = Auth.mute_user(user, user)
      assert %{muted_user_id: ["cannot mute yourself"]} = errors_on(changeset)
    end
  end

  describe "mute_remote_actor/2 and unmute_remote_actor/2" do
    test "mutes and unmutes a remote actor" do
      user = create_user("user")
      ap_id = "https://remote.example/users/someone"

      assert {:ok, mute} = Auth.mute_remote_actor(user, ap_id)
      assert mute.muted_actor_ap_id == ap_id

      assert Auth.muted?(user, ap_id)

      {1, nil} = Auth.unmute_remote_actor(user, ap_id)
      refute Auth.muted?(user, ap_id)
    end
  end

  describe "list_mutes/1" do
    test "lists all mutes for a user" do
      user = create_user("user")
      target = create_user("user")
      ap_id = "https://remote.example/users/muted-actor"

      {:ok, _} = Auth.mute_user(user, target)
      {:ok, _} = Auth.mute_remote_actor(user, ap_id)

      mutes = Auth.list_mutes(user)
      assert length(mutes) == 2
    end
  end

  describe "muted_user_ids/1 and muted_actor_ap_ids/1" do
    test "returns lists of muted IDs" do
      user = create_user("user")
      target = create_user("user")
      ap_id = "https://remote.example/users/muted-actor"

      {:ok, _} = Auth.mute_user(user, target)
      {:ok, _} = Auth.mute_remote_actor(user, ap_id)

      assert target.id in Auth.muted_user_ids(user)
      assert ap_id in Auth.muted_actor_ap_ids(user)
    end
  end

  describe "get_user_by_username/1" do
    test "returns user for valid username" do
      user = create_user("user", username: "findme_#{System.unique_integer([:positive])}")
      found = Auth.get_user_by_username(user.username)
      assert found.id == user.id
      assert found.role
    end

    test "returns nil for non-existent username" do
      assert Auth.get_user_by_username("totally_nonexistent") == nil
    end
  end

  describe "paginate_users/1" do
    test "returns paginated result with correct metadata" do
      for _ <- 1..3, do: create_user("user")

      result = Auth.paginate_users(page: 1, per_page: 2)
      assert is_list(result.users)
      assert length(result.users) == 2
      assert result.total >= 3
      assert result.page == 1
      assert result.per_page == 2
      assert result.total_pages >= 2
    end

    test "returns page 1 for invalid page number" do
      create_user("user")
      result = Auth.paginate_users(page: 0)
      assert result.page == 1
    end
  end
end
