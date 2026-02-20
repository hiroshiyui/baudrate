defmodule BaudrateWeb.HomeLive do
  @moduledoc """
  LiveView for the authenticated home page (`/`).

  Requires full authentication via the `:require_auth` hook.
  `@current_user` is available via the auto-layout.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @impl true
  def mount(_params, _session, socket) do
    boards = Content.list_top_boards()
    {:ok, assign(socket, :boards, boards)}
  end
end
