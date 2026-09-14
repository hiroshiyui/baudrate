defmodule BaudrateWeb.AccountMigrationLiveTest do
  @moduledoc """
  Alias management on `/profile/move` needs step-up re-authentication, and the
  lock is enforced by every handler, not only by hiding controls (ADR 0025).
  """

  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.{AccountMigration, Auth}
  alias Baudrate.Federation.{HTTPClient, KeyStore, RemoteActor}
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

  describe "moving this account" do
    defp make_eligible(user) do
      secret = Auth.generate_totp_secret()
      {:ok, _} = Auth.enable_totp(user, secret)
      past = DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.truncate(:second)
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [totp_enabled_at: past])
      {Repo.reload!(user), secret}
    end

    defp stub_destination(user) do
      {public_pem, _} = KeyStore.generate_keypair()
      ap_id = "https://new.example/users/me"

      Req.Test.stub(HTTPClient, fn conn ->
        Req.Test.json(conn, %{
          "id" => ap_id,
          "type" => "Person",
          "preferredUsername" => "me",
          "inbox" => "#{ap_id}/inbox",
          "alsoKnownAs" => [Baudrate.Federation.actor_uri(:user, user.username)],
          "publicKey" => %{
            "id" => "#{ap_id}#main-key",
            "owner" => ap_id,
            "publicKeyPem" => public_pem
          }
        })
      end)

      # The request runs in a task started by the LiveView process.
      Req.Test.set_req_test_to_shared()
      on_exit(fn -> Req.Test.set_req_test_to_private() end)
      ap_id
    end

    test "without TOTP, explains why the account cannot move", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/profile/move")

      assert has_element?(
               lv,
               "#account-move-ineligible-reason",
               "Enable two-factor authentication"
             )

      assert has_element?(lv, "#account-move-enable-totp[href='/profile/totp-reset']")
      refute has_element?(lv, "#account-move-form")
    end

    test "a request shows as pending with a site-wide banner, and can be cancelled",
         %{conn: conn, user: user} do
      {user, secret} = make_eligible(user)
      target = stub_destination(user)

      {:ok, lv, _html} = live(conn, "/profile/move")

      lv
      |> form("#account-move-form",
        move: %{account: target, password: @password, code: totp_code(secret)}
      )
      |> render_submit()

      render_async(lv, 5_000)

      assert has_element?(lv, "#account-move-pending-target", "@me@new.example")
      assert has_element?(lv, "#account-move-banner", "@me@new.example")
      assert %{status: "pending"} = move = AccountMigration.active_move(user.id)

      # Every other page shows the banner too.
      {:ok, other, _html} = live(conn, "/profile")
      assert has_element?(other, "#account-move-banner-link[href='/profile/move']")

      lv |> element("#account-move-cancel") |> render_click()

      refute has_element?(lv, "#account-move-pending")
      refute has_element?(lv, "#account-move-banner")
      assert %{status: "cancelled"} = Repo.reload!(move)
      assert has_element?(lv, "#account-move-history-#{move.id}", "Cancelled")
    end

    test "wrong credentials create nothing", %{conn: conn, user: user} do
      {user, _secret} = make_eligible(user)
      target = stub_destination(user)

      {:ok, lv, _html} = live(conn, "/profile/move")

      lv
      |> form("#account-move-form", move: %{account: target, password: "wrong", code: "000000"})
      |> render_submit()

      assert render_async(lv, 5_000) =~ "Invalid credentials"
      assert AccountMigration.active_move(user.id) == nil
    end

    test "cancelling someone else's move does nothing", %{conn: conn} do
      other = setup_user("user")
      {other, _} = make_eligible(other)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      move =
        Repo.insert!(%AccountMigration.AccountMove{
          user_id: other.id,
          target_ap_id: "https://new.example/users/other",
          status: "pending",
          requested_at: now,
          send_after: DateTime.add(now, 86_400)
        })

      {:ok, lv, _html} = live(conn, "/profile/move")
      render_hook(lv, "cancel_move", %{"id" => to_string(move.id)})

      assert %{status: "pending"} = Repo.reload!(move)
    end
  end
end
