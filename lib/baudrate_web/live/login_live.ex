defmodule BaudrateWeb.LoginLive do
  @moduledoc """
  LiveView for the login page.

  Uses the **phx-trigger-action** pattern: the LiveView validates credentials
  and performs rate limiting in the LiveView process, then sets `@trigger_action`
  to `true` with a signed `Phoenix.Token`. This causes the hidden form to
  POST to `SessionController.create/2`, which runs as a regular controller
  action with full access to `conn` for session writes.

  This pattern is necessary because LiveView processes cannot write to the
  HTTP session (cookie) directly — only controller actions can.
  """

  use BaudrateWeb, :live_view

  require Logger

  alias Baudrate.Auth

  @impl true
  def mount(_params, _session, socket) do
    peer_ip =
      if connected?(socket) do
        case get_connect_info(socket, :peer_data) do
          %{address: addr} -> addr |> :inet.ntoa() |> to_string()
          _ -> "unknown"
        end
      else
        "unknown"
      end

    socket =
      socket
      |> assign(:form, to_form(%{"username" => "", "password" => ""}, as: :login))
      |> assign(:trigger_action, false)
      |> assign(:token, nil)
      |> assign(:peer_ip, peer_ip)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"login" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :login))}
  end

  @impl true
  def handle_event("submit", %{"login" => %{"username" => username, "password" => password}}, socket) do
    ip = socket.assigns.peer_ip

    case Hammer.check_rate("login:#{ip}", 300_000, 10) do
      {:deny, _limit} ->
        Logger.warning("rate_limit.denied: action=login ip=#{ip}")

        socket =
          socket
          |> put_flash(:error, gettext("Too many login attempts. Please try again later."))
          |> assign(:form, to_form(%{"username" => username, "password" => ""}, as: :login))

        {:noreply, socket}

      _ ->
        do_login(socket, username, password)
    end
  end

  defp do_login(socket, username, password) do
    case Auth.authenticate_by_password(username, password) do
      {:ok, user} ->
        token = Phoenix.Token.sign(socket.endpoint, "user_auth", user.id)

        socket =
          socket
          |> assign(:token, token)
          |> assign(:trigger_action, true)

        {:noreply, socket}

      {:error, :invalid_credentials} ->
        Logger.warning("auth.login_failure: username=#{username} ip=#{socket.assigns.peer_ip}")

        socket =
          socket
          |> put_flash(:error, gettext("Invalid username or password."))
          |> assign(:form, to_form(%{"username" => username, "password" => ""}, as: :login))

        {:noreply, socket}
    end
  end
end
