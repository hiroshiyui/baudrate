defmodule BaudrateWeb.AdminSudoDeadlineTest do
  @moduledoc """
  Admin sudo mode is enforced on every event, not only at mount.

  `on_mount(:require_admin_totp, …)` runs once per mount and never again, so a
  socket opened inside the ten-minute window kept accepting admin events for as
  long as it stayed connected — a stolen session that verified once could go on
  banning accounts and rotating federation keys hours later, and the window
  only closed on a reload. `ProfileLive` already guards its own five-minute
  unlock per handler and says why: events can be sent regardless of what the
  template renders.
  """

  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    Baudrate.Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
    admin = setup_user("admin")
    {:ok, conn: log_in_admin(conn, admin), admin: admin}
  end

  defp expire_sudo(lv) do
    # Backdate the deadline on the live process rather than adding a
    # production-only timeout knob: the mount-time check and the per-event
    # check read different things, so one configurable value could not
    # exercise the second without disabling the first.
    :sys.replace_state(lv.pid, fn state ->
      assigns = Map.put(state.socket.assigns, :admin_sudo_expires_at, 0)
      %{state | socket: %{state.socket | assigns: assigns}}
    end)
  end

  test "an event after the window closes is refused and sent to re-verify", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    expire_sudo(lv)

    assert {:error, {:live_redirect, %{to: "/admin/verify"}}} =
             render_change(lv, "validate", %{"settings" => %{"site_name" => "Taken Over"}})
  end

  test "events still work inside the window", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/settings")

    # Same event, deadline untouched: the guard must not break ordinary use.
    assert render_change(lv, "validate", %{"settings" => %{"site_name" => "Fine"}})
  end
end
