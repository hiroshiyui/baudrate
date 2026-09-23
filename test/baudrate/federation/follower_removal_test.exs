defmodule Baudrate.Federation.FollowerRemovalTest do
  @moduledoc """
  A member removes their own followers (6C, ADR 0070): a member here is
  deleted silently, an account elsewhere is answered with `Reject(Follow)`
  naming the Follow it accepted. The follower's id always comes from the
  client, so it is matched on the member in the query.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Federation
  alias Baudrate.Federation.{DeliveryJob, Follower, RemoteActor, UserFollow}
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  setup do
    Setup.seed_roles_and_permissions()
    %{member: member(), other: member()}
  end

  describe "list_followers_of_user/1" do
    test "lists members here and accounts elsewhere, and nobody else's", ctx do
      fan = member()
      {:ok, _} = Federation.create_local_follow(fan, ctx.member)
      {:ok, _} = Federation.create_local_follow(member(), ctx.other)
      remote = follow_remotely!(ctx.member)
      _theirs = follow_remotely!(ctx.other)

      %{local: local, remote: remote_rows} = Federation.list_followers_of_user(ctx.member)

      assert Enum.map(local, & &1.id) == [fan.id]
      assert [%Follower{id: id, remote_actor: %RemoteActor{}}] = remote_rows
      assert id == remote.id
    end
  end

  describe "remove_remote_follower/2" do
    test "deletes the row and queues a Reject naming the accepted Follow", ctx do
      follower = follow_remotely!(ctx.member)

      assert :ok = Federation.remove_remote_follower(ctx.member, follower.id)
      refute Repo.get(Follower, follower.id)

      assert [job] = Repo.all(DeliveryJob)
      activity = Jason.decode!(job.activity_json)
      assert activity["type"] == "Reject"
      assert activity["object"]["type"] == "Follow"
      assert activity["object"]["id"] == follower.activity_id
      assert activity["object"]["actor"] == follower.follower_uri
      assert activity["actor"] == Federation.actor_uri(:user, ctx.member.username)
      assert job.inbox_url =~ "remote.example"
    end

    test "refuses another member's follower, and sends nothing", ctx do
      theirs = follow_remotely!(ctx.other)

      assert {:error, :not_found} = Federation.remove_remote_follower(ctx.member, theirs.id)
      assert Repo.get(Follower, theirs.id)
      assert Repo.all(DeliveryJob) == []
    end
  end

  describe "remove_local_follower/2" do
    test "deletes that follow only", ctx do
      fan = member()
      {:ok, _} = Federation.create_local_follow(fan, ctx.member)
      {:ok, _} = Federation.create_local_follow(ctx.member, fan)

      assert {:ok, _} = Federation.remove_local_follower(ctx.member, fan.id)

      refute Federation.local_follows?(fan.id, ctx.member.id)
      # The member's own follow of them is theirs to keep.
      assert Federation.local_follows?(ctx.member.id, fan.id)
      assert Repo.all(DeliveryJob) == []
    end

    test "refuses a follow of somebody else", ctx do
      fan = member()
      {:ok, _} = Federation.create_local_follow(fan, ctx.other)

      assert {:error, :not_found} = Federation.remove_local_follower(ctx.member, fan.id)
      assert Repo.aggregate(UserFollow, :count) == 1
    end
  end

  # --- helpers ---

  defp follow_remotely!(user) do
    n = System.unique_integer([:positive])

    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/f#{n}",
        username: "f#{n}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/f#{n}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follower} =
      Federation.create_follower(
        Federation.actor_uri(:user, user.username),
        actor,
        "https://remote.example/follows/#{n}"
      )

    follower
  end

  defp member do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "fol#{n}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: "active"])
    user |> Repo.reload() |> Repo.preload(:role)
  end
end
