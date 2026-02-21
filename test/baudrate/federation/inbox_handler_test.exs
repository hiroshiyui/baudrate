defmodule Baudrate.Federation.InboxHandlerTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{InboxHandler, KeyStore, RemoteActor}

  defp setup_user_with_role(role_name) do
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "test_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    actor
  end

  describe "Follow" do
    test "creates a follower record" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      remote_actor = create_remote_actor()

      actor_uri = Federation.actor_uri(:user, user.username)

      activity = %{
        "id" => "https://remote.example/activities/follow-#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.ap_id,
        "object" => actor_uri
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, {:user, user})

      # Give async Accept delivery task time to not interfere
      Process.sleep(50)

      # Verify follower was created
      assert Federation.follower_exists?(actor_uri, remote_actor.ap_id)
    end

    test "idempotent Follow (duplicate) still succeeds" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      remote_actor = create_remote_actor()

      actor_uri = Federation.actor_uri(:user, user.username)

      activity = %{
        "id" => "https://remote.example/activities/follow-#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.ap_id,
        "object" => actor_uri
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, {:user, user})
      Process.sleep(50)

      # Second follow with different activity_id
      activity2 =
        Map.put(
          activity,
          "id",
          "https://remote.example/activities/follow-#{System.unique_integer([:positive])}"
        )

      assert :ok = InboxHandler.handle(activity2, remote_actor, {:user, user})
      Process.sleep(50)

      # Still exactly 1 follower
      assert Federation.count_followers(actor_uri) == 1
    end
  end

  describe "Undo(Follow)" do
    test "removes follower record" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      remote_actor = create_remote_actor()

      actor_uri = Federation.actor_uri(:user, user.username)

      follow_activity = %{
        "id" => "https://remote.example/activities/follow-#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => remote_actor.ap_id,
        "object" => actor_uri
      }

      assert :ok = InboxHandler.handle(follow_activity, remote_actor, {:user, user})
      Process.sleep(50)
      assert Federation.follower_exists?(actor_uri, remote_actor.ap_id)

      # Now undo the follow
      undo_activity = %{
        "type" => "Undo",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Follow",
          "actor" => remote_actor.ap_id,
          "object" => actor_uri
        }
      }

      assert :ok = InboxHandler.handle(undo_activity, remote_actor, {:user, user})
      refute Federation.follower_exists?(actor_uri, remote_actor.ap_id)
    end
  end

  describe "deferred types" do
    test "Create(Note) returns :ok without creating records" do
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Note",
          "content" => "Hello world",
          "attributedTo" => remote_actor.ap_id
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
    end

    test "Like returns :ok without creating records" do
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Like",
        "actor" => remote_actor.ap_id,
        "object" => "https://local.example/ap/articles/some-post"
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
    end

    test "Announce returns :ok without creating records" do
      remote_actor = create_remote_actor()

      activity = %{
        "type" => "Announce",
        "actor" => remote_actor.ap_id,
        "object" => "https://local.example/ap/articles/some-post"
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "domain blocking" do
    test "rejects activities from blocked domains" do
      Baudrate.Setup.set_setting("ap_domain_blocklist", "blocked-domain.example")

      remote_actor =
        create_remote_actor(%{
          ap_id: "https://blocked-domain.example/users/eve",
          username: "eve",
          domain: "blocked-domain.example",
          inbox: "https://blocked-domain.example/users/eve/inbox"
        })

      activity = %{
        "type" => "Follow",
        "actor" => remote_actor.ap_id,
        "object" => "https://local.example/ap/users/bob"
      }

      assert {:error, :domain_blocked} = InboxHandler.handle(activity, remote_actor, :shared)
    end
  end

  describe "self-referencing actors" do
    test "local_actor? correctly identifies local URIs" do
      base = BaudrateWeb.Endpoint.url()
      assert Baudrate.Federation.Validator.local_actor?("#{base}/ap/users/alice")
      refute Baudrate.Federation.Validator.local_actor?("https://remote.example/users/alice")
    end
  end
end
