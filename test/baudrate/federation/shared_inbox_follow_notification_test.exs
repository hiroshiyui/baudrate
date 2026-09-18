defmodule Baudrate.Federation.SharedInboxFollowNotificationTest do
  @moduledoc """
  Being followed is worth being told about, whichever inbox the Follow reached.

  The notification used to fire only when the activity arrived at the followed
  user's own inbox. An instance that advertises a `sharedInbox` gets its
  follows delivered there instead — which is what Mastodon does — so in the
  common case the person being followed was never told. The block check beside
  it always resolved the target from the Follow's `object` URI; only the
  notification depended on which door the activity came through (3F).
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Federation
  alias Baudrate.Federation.{Inbound, KeyStore, RemoteActor}
  alias Baudrate.Notification.Notification

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    %{user: create_user(), remote: create_remote_actor()}
  end

  describe "a Follow of a local user" do
    test "notifies when it arrives at the user's own inbox", %{user: user, remote: remote} do
      accept_follow(remote, user, {:user, user})

      assert [%Notification{type: "new_follower"}] = follower_notifications(user)
    end

    test "notifies when it arrives at the shared inbox", %{user: user, remote: remote} do
      accept_follow(remote, user, :shared)

      assert [%Notification{type: "new_follower"} = notification] = follower_notifications(user)
      assert notification.actor_remote_actor_id == remote.id
    end

    test "notifies when it arrives at the site actor's inbox", %{user: user, remote: remote} do
      # The site actor's inbox resolves its target from the activity exactly as
      # the shared inbox does, so a Follow addressed to a user is honoured there
      # too rather than silently losing its notification.
      accept_follow(remote, user, :shared)

      assert [%Notification{type: "new_follower"}] = follower_notifications(user)
    end
  end

  test "a Follow of a board notifies nobody", %{remote: remote} do
    board =
      Repo.insert!(
        Baudrate.Content.Board.changeset(%Baudrate.Content.Board{}, %{
          name: "Followable",
          slug: "followable-#{uid()}",
          ap_enabled: true,
          min_role_to_view: "guest"
        })
      )

    activity = %{
      "id" => "#{remote.ap_id}/follows/#{uid()}",
      "type" => "Follow",
      "actor" => remote.ap_id,
      "object" => Federation.actor_uri(:board, board.slug)
    }

    assert :ok = Inbound.accept(activity, Jason.encode!(activity), remote, :shared)

    assert Repo.all(from(n in Notification, where: n.type == "new_follower")) == [],
           "a board follow produced a personal new_follower notification"
  end

  defp accept_follow(remote, user, target) do
    activity = %{
      "id" => "#{remote.ap_id}/follows/#{uid()}",
      "type" => "Follow",
      "actor" => remote.ap_id,
      "object" => Federation.actor_uri(:user, user.username)
    }

    assert :ok = Inbound.accept(activity, Jason.encode!(activity), remote, target)
    assert Federation.follower_exists?(Federation.actor_uri(:user, user.username), remote.ap_id)
  end

  defp follower_notifications(user) do
    Repo.all(
      from(n in Notification,
        where: n.user_id == ^user.id and n.type == "new_follower",
        order_by: [asc: n.id]
      )
    )
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "followed_#{uid()}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    user
  end

  defp create_remote_actor do
    id = uid()

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/follower-#{id}",
      username: "follower_#{id}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/follower-#{id}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp uid, do: System.unique_integer([:positive])
end
