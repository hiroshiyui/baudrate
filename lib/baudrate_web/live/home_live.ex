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
    boards = Content.list_visible_top_boards(socket.assigns.current_user)
    site_name = Setup.get_setting("site_name") || "Baudrate"
    jsonld = site_name |> LinkedData.site_jsonld() |> LinkedData.encode_jsonld()

    {:ok,
     assign(socket,
       boards: boards,
       page_title: gettext("Boards"),
       feed_site: true,
       linked_data_json: jsonld
     )}
  end
end
