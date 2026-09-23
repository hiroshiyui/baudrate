defmodule Baudrate.Notification.AccountSecurityNoticesTest do
  @moduledoc """
  Account security notices (ADR 0022): a user is told whenever one of their
  second factors changes, and cannot turn these notices off.
  """

  use Baudrate.DataCase, async: true

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Notification.Hooks
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Notification.WebPush
  alias Baudrate.Repo

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    %{user: create_user()}
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "secnotice_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp credential_attrs(label) do
    %{
      credential_id: :crypto.strong_rand_bytes(32),
      public_key_cbor: CBOR.encode(%{1 => 2, -2 => :crypto.strong_rand_bytes(32)}),
      sign_count: 0,
      label: label
    }
  end

  defp notices(user) do
    Repo.all(
      from(n in NotificationSchema,
        where: n.user_id == ^user.id,
        order_by: [asc: n.id]
      )
    )
  end

  describe "security key changes" do
    test "adding a key notifies the owner with the key label", %{user: user} do
      {:ok, _cred} = Auth.create_webauthn_credential(user, credential_attrs("YubiKey 5"))

      assert [%{type: "security_key_added", data: %{"label" => "YubiKey 5"}} = n] = notices(user)
      assert is_nil(n.actor_user_id)
      refute n.read
    end

    test "removing a key notifies the owner", %{user: user} do
      {:ok, cred} = Auth.create_webauthn_credential(user, credential_attrs("Old Key"))
      {:ok, _} = Auth.delete_webauthn_credential(user, cred.id)

      assert [
               %{type: "security_key_added"},
               %{type: "security_key_removed", data: %{"label" => "Old Key"}}
             ] = notices(user)
    end

    test "every change is recorded; security notices are not deduplicated", %{user: user} do
      {:ok, _} = Auth.create_webauthn_credential(user, credential_attrs("Key A"))
      {:ok, _} = Auth.create_webauthn_credential(user, credential_attrs("Key A"))

      assert length(notices(user)) == 2
    end

    test "a failed insert or a missing key sends nothing", %{user: user} do
      attrs = credential_attrs("Dup")
      {:ok, _} = Auth.create_webauthn_credential(user, attrs)
      {:error, _changeset} = Auth.create_webauthn_credential(user, attrs)
      {:error, :not_found} = Auth.delete_webauthn_credential(user, -1)

      assert [%{type: "security_key_added"}] = notices(user)
    end

    test "removing another user's key neither succeeds nor notifies anyone", %{user: user} do
      other = create_user()
      {:ok, cred} = Auth.create_webauthn_credential(other, credential_attrs("Theirs"))

      assert {:error, :not_found} = Auth.delete_webauthn_credential(user, cred.id)
      assert notices(user) == []
      assert [%{type: "security_key_added"}] = notices(other)
    end
  end

  describe "TOTP changes" do
    test "enabling TOTP notifies the user", %{user: user} do
      {:ok, _} = Auth.enable_totp(user, Auth.generate_totp_secret())

      assert [%{type: "totp_enabled"}] = notices(user)
    end

    test "disabling TOTP notifies only when it was on", %{user: user} do
      {:ok, _} = Auth.disable_totp(user)
      assert notices(user) == []

      {:ok, enabled} = Auth.enable_totp(user, Auth.generate_totp_secret())
      {:ok, _} = Auth.disable_totp(enabled)

      assert [%{type: "totp_enabled"}, %{type: "totp_disabled"}] = notices(user)
    end
  end

  describe "delivery" do
    test "notices ignore a stored preference that disables them", %{user: user} do
      # The preferences changeset refuses these keys, so write the map directly
      # to prove a stored value cannot silence a security notice either.
      prefs = %{
        "security_key_added" => %{"in_app" => false, "web_push" => false},
        "totp_enabled" => %{"in_app" => false, "web_push" => false}
      }

      Repo.update_all(from(u in Baudrate.Setup.User, where: u.id == ^user.id),
        set: [notification_preferences: prefs]
      )

      user = Repo.reload!(user)
      {:ok, _} = Auth.create_webauthn_credential(user, credential_attrs("K"))
      {:ok, _} = Auth.enable_totp(user, Auth.generate_totp_secret())

      assert [%{type: "security_key_added"}, %{type: "totp_enabled"}] = notices(user)
    end

    test "users cannot opt out through the preferences changeset", %{user: user} do
      changeset =
        Baudrate.Setup.User.notification_preferences_changeset(user, %{
          notification_preferences: %{"security_key_added" => %{"in_app" => false}}
        })

      refute changeset.valid?
    end

    test "notify_account_security/3 refuses non-security types", %{user: user} do
      assert {:error, :not_a_security_type} =
               Hooks.notify_account_security(user.id, "new_follower")

      assert notices(user) == []
    end
  end

  describe "web push payload" do
    test "links to /profile/security, carries the key label, and uses the recipient's locale",
         %{user: user} do
      {:ok, user} = Auth.update_preferred_locales(user, ["zh_TW"])
      {:ok, _} = Auth.create_webauthn_credential(user, credential_attrs("Pixel Passkey"))

      [notice] = notices(user)

      payload =
        notice
        |> Repo.preload([:user, :actor_user, :actor_remote_actor, :article])
        |> WebPush.build_payload()

      assert payload.type == "security_key_added"
      assert payload.body == "Pixel Passkey"
      assert payload.url == BaudrateWeb.Endpoint.url() <> "/profile/security"

      expected =
        Gettext.with_locale(BaudrateWeb.Gettext, "zh_TW", fn ->
          BaudrateWeb.Helpers.notification_text("security_key_added")
        end)

      assert payload.title == expected
      refute payload.title == "A security key was added to your account."
    end

    test "alias notices link to the account migration page with the alias", %{user: user} do
      {:ok, _} =
        Hooks.notify_account_security(user.id, "account_alias_added", %{
          "label" => "@me@old.example"
        })

      [notice] = notices(user)

      payload =
        notice
        |> Repo.preload([:user, :actor_user, :actor_remote_actor, :article])
        |> WebPush.build_payload()

      assert payload.url == BaudrateWeb.Endpoint.url() <> "/profile/move"
      assert payload.body == "@me@old.example"
    end

    test "a failed-code notice links to the password change page", %{user: user} do
      {:ok, _} = Hooks.notify_account_security(user.id, "totp_login_failed")

      [notice] = notices(user)

      payload =
        notice
        |> Repo.preload([:user, :actor_user, :actor_remote_actor, :article])
        |> WebPush.build_payload()

      assert payload.url == BaudrateWeb.Endpoint.url() <> "/profile/password"
      assert payload.title =~ "failed the two-factor code"
    end
  end
end
