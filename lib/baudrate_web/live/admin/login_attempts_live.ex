defmodule BaudrateWeb.Admin.LoginAttemptsLive do
  @moduledoc """
  LiveView for the admin login attempts page.

  Displays a paginated, filterable list of login attempts for security
  monitoring. Only accessible to admin users.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Auth
  import BaudrateWeb.Helpers, only: [parse_page: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       wide_layout: true,
       username_filter: "",
       page_title: gettext("Admin Login Attempts")
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    username_filter = params["username"] || ""

    opts =
      [page: page]
      |> then(fn opts ->
        if username_filter != "",
          do: Keyword.put(opts, :username, username_filter),
          else: opts
      end)

    %{attempts: attempts, page: page, total_pages: total_pages} =
      Auth.paginate_login_attempts(opts)

    {:noreply,
     assign(socket,
       attempts: attempts,
       page: page,
       total_pages: total_pages,
       username_filter: username_filter
     )}
  end

  @impl true
  def handle_event("search", %{"username" => term}, socket) do
    params = if term == "", do: %{}, else: %{"username" => term}
    {:noreply, push_patch(socket, to: ~p"/admin/login-attempts?#{params}")}
  end
end
