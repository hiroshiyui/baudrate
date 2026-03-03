defmodule Baudrate.Auth.HiddenIdsTest do
  use Baudrate.DataCase

  alias Baudrate.Auth

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  describe "hidden_ids/1" do
    test "returns empty lists when user has no blocks or mutes" do
      user = create_user()
      assert {[], []} = Auth.hidden_ids(user)
    end

    test "returns blocked local user IDs" do
      user = create_user()
      blocked = create_user()
      {:ok, _} = Auth.block_user(user, blocked)

      {user_ids, ap_ids} = Auth.hidden_ids(user)
      assert blocked.id in user_ids
      assert ap_ids == []
    end

    test "returns blocked remote actor AP IDs" do
      user = create_user()
      ap_id = "https://remote.example/actor/1"
      {:ok, _} = Auth.block_remote_actor(user, ap_id)

      {user_ids, ap_ids} = Auth.hidden_ids(user)
      assert user_ids == []
      assert ap_id in ap_ids
    end

    test "returns muted local user IDs" do
      user = create_user()
      muted = create_user()
      {:ok, _} = Auth.mute_user(user, muted)

      {user_ids, ap_ids} = Auth.hidden_ids(user)
      assert muted.id in user_ids
      assert ap_ids == []
    end

    test "returns muted remote actor AP IDs" do
      user = create_user()
      ap_id = "https://remote.example/actor/2"
      {:ok, _} = Auth.mute_remote_actor(user, ap_id)

      {user_ids, ap_ids} = Auth.hidden_ids(user)
      assert user_ids == []
      assert ap_id in ap_ids
    end

    test "combines blocks and mutes with deduplication" do
      user = create_user()
      target = create_user()
      ap_id = "https://remote.example/actor/3"

      # Block and mute the same local user
      {:ok, _} = Auth.block_user(user, target)
      {:ok, _} = Auth.mute_user(user, target)

      # Block and mute the same remote actor
      {:ok, _} = Auth.block_remote_actor(user, ap_id)
      {:ok, _} = Auth.mute_remote_actor(user, ap_id)

      {user_ids, ap_ids} = Auth.hidden_ids(user)

      # Should be deduplicated
      assert user_ids == [target.id]
      assert ap_ids == [ap_id]
    end

    test "returns both blocks and mutes from different targets" do
      user = create_user()
      blocked_user = create_user()
      muted_user = create_user()
      blocked_ap = "https://remote.example/blocked"
      muted_ap = "https://remote.example/muted"

      {:ok, _} = Auth.block_user(user, blocked_user)
      {:ok, _} = Auth.mute_user(user, muted_user)
      {:ok, _} = Auth.block_remote_actor(user, blocked_ap)
      {:ok, _} = Auth.mute_remote_actor(user, muted_ap)

      {user_ids, ap_ids} = Auth.hidden_ids(user)

      assert Enum.sort(user_ids) == Enum.sort([blocked_user.id, muted_user.id])
      assert Enum.sort(ap_ids) == Enum.sort([blocked_ap, muted_ap])
    end
  end
end
