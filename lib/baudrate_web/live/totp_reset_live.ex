defmodule BaudrateWeb.TotpResetLive do
  @moduledoc """
  LiveView for self-service TOTP reset (when user already has TOTP enabled)
  or TOTP enable (when user has optional TOTP and hasn't enabled it yet).

  ## Reset Mode (totp_enabled == true)
  Requires password + current TOTP code. On success, signs a Phoenix.Token
  and uses phx-trigger-action to POST to `/auth/totp-reset`.

  ## Enable Mode (totp_enabled == false, policy == :optional)
  Requires password only. Same POST flow.

  Both modes enforce a 5-attempt lockout tracked in socket assigns.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth

  @max_attempts 5

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    mode = if user.totp_enabled, do: :reset, else: :enable

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:attempts, 0)
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
      password = params["password"] || ""
      code = String.trim(params["code"] || "")

      password_valid = Auth.verify_password(user, password)

      totp_valid =
        if socket.assigns.mode == :reset do
          secret = Auth.decrypt_totp_secret(user)
          secret && Auth.valid_totp?(secret, code)
        else
          true
        end

      if password_valid && totp_valid do
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
      else
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
