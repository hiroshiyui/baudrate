defmodule BaudrateWeb.Admin.InstanceDetailLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Repo

  alias Baudrate.Federation.{DomainBlockCache, DomainBlocks, RemoteActor, RemoteActors}

  setup do
    Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Baudrate.Setup.Setting{key: "site_name", value: "Test Site"})
    Baudrate.Setup.set_setting("ap_federation_mode", "blocklist")
    DomainBlockCache.refresh()
    on_exit(fn -> DomainBlockCache.refresh() end)
    :ok
  end

  defp create_actor(domain, username) do
    Repo.insert!(%RemoteActor{
      ap_id: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      display_name: "Someone",
      public_key_pem: elem(Baudrate.Federation.KeyStore.generate_keypair(), 0),
      inbox: "https://#{domain}/users/#{username}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  test "lists the accounts known on an instance", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    loud = create_actor("shared.example", "loud")
    _elsewhere = create_actor("other.example", "someone")

    {:ok, lv, html} = live(conn, "/admin/federation/instances/shared.example")

    assert html =~ "shared.example"
    assert has_element?(lv, "#instance-actor-#{loud.id}")
    refute html =~ "@someone@other.example"
  end

  test "suspends one account, with a reason, without touching its neighbours", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    loud = create_actor("shared.example", "loud")
    quiet = create_actor("shared.example", "quiet")

    {:ok, lv, _html} = live(conn, "/admin/federation/instances/shared.example")

    lv |> element("#instance-actor-suspend-#{loud.id}") |> render_click()

    html =
      lv
      |> form("#instance-actor-suspend-form-#{loud.id}", %{"reason" => "harassment"})
      |> render_submit()

    assert html =~ "is suspended"
    assert RemoteActors.suspended?(Repo.reload(loud))
    refute RemoteActors.suspended?(Repo.reload(quiet))

    assert [%{details: %{"reason" => "harassment"}}] =
             Baudrate.Moderation.list_moderation_logs(action: "suspend_remote_actor").logs
  end

  test "refuses to suspend without a reason", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    loud = create_actor("shared.example", "loud")

    {:ok, lv, _html} = live(conn, "/admin/federation/instances/shared.example")

    lv |> element("#instance-actor-suspend-#{loud.id}") |> render_click()

    html =
      lv
      |> form("#instance-actor-suspend-form-#{loud.id}", %{"reason" => "   "})
      |> render_submit()

    assert html =~ "Say why this account is suspended"
    refute RemoteActors.suspended?(Repo.reload(loud))
  end

  test "lifts a suspension", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    loud = create_actor("shared.example", "loud")
    {:ok, _} = RemoteActors.suspend(loud, admin, "harassment")

    {:ok, lv, _html} = live(conn, "/admin/federation/instances/shared.example")

    html = lv |> element("#instance-actor-unsuspend-#{loud.id}") |> render_click()

    assert html =~ "no longer suspended"
    refute RemoteActors.suspended?(Repo.reload(loud))

    assert [%{}] =
             Baudrate.Moderation.list_moderation_logs(action: "unsuspend_remote_actor").logs
  end

  test "says when the instance itself is blocked", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    create_actor("shared.example", "loud")
    {:ok, _} = DomainBlocks.block_domain("shared.example", admin, %{reason: "spam wave"})

    {:ok, lv, html} = live(conn, "/admin/federation/instances/shared.example")

    assert has_element?(lv, "#instance-blocked-notice")
    assert html =~ "spam wave"
  end

  test "keeps showing a blocked instance's accounts to staff", %{conn: conn} do
    # ADR 0030, decision 7: moderators cannot judge what they cannot see, and a
    # block is often applied before the content has been reviewed.
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    loud = create_actor("shared.example", "loud")
    {:ok, _} = DomainBlocks.block_domain("shared.example", admin, %{reason: "spam wave"})

    {:ok, lv, _html} = live(conn, "/admin/federation/instances/shared.example")

    assert has_element?(lv, "#instance-actor-#{loud.id}")
  end

  test "a pasted URL finds the same instance as the bare domain", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    loud = create_actor("shared.example", "loud")

    {:ok, lv, _html} =
      live(conn, "/admin/federation/instances/#{URI.encode_www_form("HTTPS://Shared.Example/")}")

    assert has_element?(lv, "#instance-actor-#{loud.id}")
  end

  test "is refused to a non-admin", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, _}} = live(conn, "/admin/federation/instances/shared.example")
  end
end
