defmodule BaudrateWeb.HomeLive do
  @moduledoc """
  LiveView for the home page (`/`).

  Accessible to both guests and authenticated users via the `:optional_auth`
  hook. `@current_user` may be `nil` for unauthenticated visitors.
  Displays the board listing for all visitors.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content

  @impl true
  def mount(_params, _session, socket) do
    boards =
      if socket.assigns.current_user do
        Content.list_top_boards()
      else
        Content.list_public_top_boards()
      end

    {:ok, assign(socket, :boards, boards)}
  end
end
