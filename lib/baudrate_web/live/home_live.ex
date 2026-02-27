defmodule BaudrateWeb.HomeLive do
  @moduledoc """
  LiveView for the home page (`/`).

  Accessible to both guests and authenticated users via the `:optional_auth`
  hook. `@current_user` may be `nil` for unauthenticated visitors.
  Board listing is filtered by `min_role_to_view` based on the user's role.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Content
  alias Baudrate.Setup
  alias BaudrateWeb.LinkedData

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    boards = Content.list_visible_top_boards(current_user)
    site_name = Setup.get_setting("site_name") || "Baudrate"
    jsonld = site_name |> LinkedData.site_jsonld() |> LinkedData.encode_jsonld()

    board_ids = Enum.map(boards, & &1.id)
    unread_board_ids = Content.unread_board_ids(current_user, board_ids)

    {:ok,
     assign(socket,
       boards: boards,
       unread_board_ids: unread_board_ids,
       page_title: gettext("Boards"),
       feed_site: true,
       linked_data_json: jsonld
     )}
  end
end
