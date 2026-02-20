defmodule BaudrateWeb.ProfileLive do
  @moduledoc """
  LiveView for the user profile page (`/profile`).

  Displays read-only account details for the current user.
  `@current_user` is available via the `:require_auth` hook.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    policy = Auth.totp_policy(user.role.name)
    {:ok, assign(socket, :totp_policy, policy)}
  end
end
