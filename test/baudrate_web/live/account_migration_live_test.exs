defmodule BaudrateWeb.AccountMigrationLiveTest do
  @moduledoc """
  Alias management on `/profile/move` needs step-up re-authentication, and the
  lock is enforced by every handler, not only by hiding controls (ADR 0025).
  """

  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.AccountMigration
  alias Baudrate.Federation.{KeyStore, RemoteActor}
  alias Baudrate.Repo
  alias Baudrate.Setup.{Setting, User}

  @password "Password123!x"

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp remote_actor do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/lv-alias-#{uid}",
      username: "lv_alias_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/lv-alias-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp unlock(lv) do
    lv
    |> form("#account-migration-reauth-form", reauth: %{password: @password})
    |> render_submit()
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/profile/move")
  end

  test "is linked from the profile page", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile")
    assert has_element?(lv, "#profile-account-migration-link[href='/profile/move']")
  end

  test "while locked, aliases are listed but cannot be changed", %{conn: conn, user: user} do
    actor = remote_actor()
    {:ok, _, _} = AccountMigration.add_alias(user, actor.ap_id)

    {:ok, lv, _html} = live(conn, "/profile/move")

    assert has_element?(lv, "#account-alias-0", "@#{actor.username}@remote.example")
    assert has_element?(lv, "#account-migration-reauth-form")
    refute has_element?(lv, "#account-alias-add-form")
    refute has_element?(lv, "#account-alias-remove-0")

    # A client speaking the LiveView protocol directly is refused as well.
    render_hook(lv, "remove_alias", %{"ap-id" => actor.ap_id})
    render_hook(lv, "add_alias", %{"alias" => %{"account" => remote_actor().ap_id}})

    assert Repo.reload!(user).also_known_as == [actor.ap_id]
  end

  test "a wrong password keeps the page locked", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/profile/move")

    html =
      lv
      |> form("#account-migration-reauth-form", reauth: %{password: "wrong"})
      |> render_submit()

    assert html =~ "Invalid credentials"
    refute has_element?(lv, "#account-alias-add-form")
  end

  test "after confirming identity, aliases can be added and removed", %{conn: conn, user: user} do
    actor = remote_actor()
    {:ok, lv, _html} = live(conn, "/profile/move")
    unlock(lv)

    lv
    |> form("#account-alias-add-form", alias: %{account: actor.ap_id})
    |> render_submit()

    render_async(lv)

    assert has_element?(lv, "#account-alias-0", "@#{actor.username}@remote.example")
    assert Repo.reload!(user).also_known_as == [actor.ap_id]

    lv |> element("#account-alias-remove-0") |> render_click()

    assert has_element?(lv, "#account-aliases-empty")
    assert Repo.reload!(user).also_known_as == []
  end

  test "a lookup failure is shown and nothing is stored", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, "/profile/move")
    unlock(lv)

    lv
    |> form("#account-alias-add-form", alias: %{account: "not an account"})
    |> render_submit()

    assert render_async(lv) =~ "Enter the account as @user@example.com"
    assert Repo.one!(from(u in User, where: u.id == ^user.id, select: u.also_known_as)) == []
  end
end
