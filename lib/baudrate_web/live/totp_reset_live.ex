defmodule BaudrateWeb.TotpResetLive do
  @moduledoc """
  LiveView for self-service TOTP reset (when user already has TOTP enabled)
  or TOTP enable (when user has optional TOTP and hasn't enabled it yet).

  ## Reset Mode (totp_enabled == true)
  Requires password + current TOTP code. On success, signs a Phoenix.Token
  and uses phx-trigger-action to POST to `/auth/totp-reset`.

  ## Enable Mode (totp_enabled == false, policy == :optional)
  Requires password only. Same POST flow.

  ## Throttling

  Credentials are checked by `Auth.verify_reauthentication/5`, behind the
  per-user `RateLimits.check_reauth/1` bucket. Failures feed the per-account
  login throttle, so reloading the page does not reset the lockout, and this
  form cannot be used to guess the password around the login throttle. A
  5-attempt counter in socket assigns remains as defense in depth.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers, only: [extract_peer_ip: 1]

  @max_attempts 5

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    mode = if user.totp_enabled, do: :reset, else: :enable

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:attempts, 0)
      |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
      |> assign(:form, to_form(%{"password" => "", "code" => ""}, as: :totp_reset))
      |> assign(:trigger_action, false)
      |> assign(:page_title, gettext("TOTP Reset"))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"totp_reset" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :totp_reset))}
  end

  @impl true
  def handle_event("submit", %{"totp_reset" => params}, socket) do
    if socket.assigns.attempts >= @max_attempts do
      socket =
        socket
        |> put_flash(:error, gettext("Too many failed attempts. Please try again later."))
        |> redirect(to: "/profile")

      {:noreply, socket}
    else
      user = socket.assigns.current_user

      result =
        with :ok <- RateLimits.check_reauth(user.id) do
          Auth.verify_reauthentication(
            user,
            params["password"],
            params["code"],
            socket.assigns.peer_ip,
            :totp_reset
          )
        end

      case result do
        :ok ->
          token =
            Phoenix.Token.sign(BaudrateWeb.Endpoint, "totp_reset", %{
              user_id: user.id,
              mode: socket.assigns.mode
            })

          socket =
            socket
            |> assign(:token, token)
            |> assign(:trigger_action, true)

          {:noreply, socket}

        {:error, :rate_limited} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Too many attempts. Please try again later."))
           |> assign(:form, to_form(%{"password" => "", "code" => ""}, as: :totp_reset))}

        {:error, {:throttled, seconds}} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext("Too many failed attempts. Please try again in %{seconds} seconds.",
               seconds: seconds
             )
           )
           |> assign(:form, to_form(%{"password" => "", "code" => ""}, as: :totp_reset))}

        {:error, :invalid_credentials} ->
          attempts = socket.assigns.attempts + 1

          socket =
            socket
            |> assign(:attempts, attempts)
            |> put_flash(:error, gettext("Invalid credentials. Please try again."))
            |> assign(:form, to_form(%{"password" => "", "code" => ""}, as: :totp_reset))

          {:noreply, socket}
      end
    end
  end
end
