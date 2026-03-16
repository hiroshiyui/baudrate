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
  import BaudrateWeb.Helpers, only: [extract_peer_ip: 1]

  @impl true
  def mount(_params, _session, socket) do
    peer_ip = if connected?(socket), do: extract_peer_ip(socket), else: "unknown"

    socket =
      socket
      |> assign(:form, to_form(%{"username" => "", "password" => ""}, as: :login))
      |> assign(:trigger_action, false)
      |> assign(:token, nil)
      |> assign(:peer_ip, peer_ip)
      |> assign(:page_title, gettext("Sign In"))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"login" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :login))}
  end

  @impl true
  def handle_event(
        "submit",
        %{"login" => %{"username" => username, "password" => password}},
        socket
      ) do
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
    ip = socket.assigns.peer_ip

    case Auth.check_login_throttle(username) do
      {:delay, seconds} ->
        Logger.warning("login_throttle.denied: username=#{username} ip=#{ip} delay=#{seconds}s")

        socket =
          socket
          |> put_flash(
            :error,
            gettext("Account temporarily locked. Try again in %{seconds} seconds.",
              seconds: seconds
            )
          )
          |> assign(:form, to_form(%{"username" => username, "password" => ""}, as: :login))

        {:noreply, socket}

      :ok ->
        case Auth.authenticate_by_password(username, password) do
          {:ok, user} ->
            Auth.record_login_attempt(username, ip, true)
            token = Phoenix.Token.sign(socket.endpoint, "user_auth", user.id)

            socket =
              socket
              |> assign(:token, token)
              |> assign(:trigger_action, true)

            {:noreply, socket}

          {:error, reason} when reason in [:banned, :invalid_credentials, :bot_account] ->
            Auth.record_login_attempt(username, ip, false)

            log_tag =
              case reason do
                :banned -> "auth.banned_login"
                :bot_account -> "auth.bot_login_attempt"
                _ -> "auth.login_failure"
              end

            Logger.warning("#{log_tag}: username=#{username} ip=#{ip}")

            socket =
              socket
              |> put_flash(:error, gettext("Invalid username or password."))
              |> assign(:form, to_form(%{"username" => username, "password" => ""}, as: :login))

            {:noreply, socket}
        end
    end
  end
end
