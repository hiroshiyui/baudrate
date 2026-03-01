defmodule Baudrate.ContentDeliveryHooksTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Setup
  alias Baudrate.Federation.{KeyStore, RemoteActor}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board(attrs) do
    %Board{}
    |> Board.changeset(attrs)
    |> Repo.insert!()
  end

  describe "create_article delivery hooks" do
    test "enqueues delivery jobs after article creation" do
      user = create_user("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)
      board = create_board(%{name: "Hook Board", slug: "hook-board"})
      {:ok, board} = KeyStore.ensure_board_keypair(board)

      # Create a follower for the user
      uid = System.unique_integer([:positive])
      {public_pem, _} = KeyStore.generate_keypair()

      {:ok, remote_actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/hook-#{uid}",
          username: "hook_#{uid}",
          domain: "remote.example",
          public_key_pem: public_pem,
          inbox: "https://remote.example/users/hook-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      user_uri = Baudrate.Federation.actor_uri(:user, user.username)

      Baudrate.Federation.create_follower(
        user_uri,
        remote_actor,
        "https://remote.example/activities/follow-#{uid}"
      )

      # Create article — should trigger delivery
      # (federation_async: false in test config, so delivery is synchronous)
      {:ok, %{article: _article}} =
        Content.create_article(
          %{title: "Hooked", body: "body", slug: "hooked-#{uid}", user_id: user.id},
          [board.id]
        )

      # Check that delivery jobs were created
      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) >= 1

      inbox_urls = Enum.map(jobs, & &1.inbox_url)
      assert remote_actor.inbox in inbox_urls
    end
  end
end
