defmodule BaudrateWeb.RecoveryCodeVerifyLive do
  @moduledoc """
  LiveView for logging in with a recovery code when the user has lost
  their authenticator device.

  Accessible from the TOTP verification page via a "Lost your device?" link.
  Lives in the `:totp` live_session (requires password auth only).

  The recovery code is POSTed to `SessionController.recovery_verify/2`
  via phx-trigger-action for server-side verification and session creation.
  """

  use BaudrateWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:form, to_form(%{"code" => ""}, as: :recovery))
      |> assign(:trigger_action, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"recovery" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :recovery))}
  end

  @impl true
  def handle_event("submit", %{"recovery" => %{"code" => code}}, socket) do
    code = String.trim(code)

    if String.match?(code, ~r/^[a-zA-Z]{3,20}$/) do
      socket =
        socket
        |> assign(:code, code)
        |> assign(:trigger_action, true)

      {:noreply, socket}
    else
      socket =
        socket
        |> put_flash(:error, gettext("Please enter a valid recovery code (a single word)."))
        |> assign(:form, to_form(%{"code" => ""}, as: :recovery))

      {:noreply, socket}
    end
  end
end
