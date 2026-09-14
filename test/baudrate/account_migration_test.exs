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
end
