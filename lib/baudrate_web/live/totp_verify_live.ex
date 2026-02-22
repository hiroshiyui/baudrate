defmodule BaudrateWeb.TotpVerifyLive do
  @moduledoc """
  LiveView for TOTP verification during login.

  Shown after password auth when the user has TOTP enabled (`login_next_step/1`
  returned `:totp_verify`). Validates the 6-digit format client-side, then uses
  `phx-trigger-action` to POST the code to `SessionController.totp_verify/2`
  for server-side verification and session establishment.
  """

  use BaudrateWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:form, to_form(%{"code" => ""}, as: :totp))
      |> assign(:trigger_action, false)
      |> assign(:page_title, gettext("TOTP Verification"))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"totp" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :totp))}
  end

  @impl true
  def handle_event("submit", %{"totp" => %{"code" => code}}, socket) do
    code = String.trim(code)

    if String.match?(code, ~r/^\d{6}$/) do
      socket =
        socket
        |> assign(:code, code)
        |> assign(:trigger_action, true)

      {:noreply, socket}
    else
      socket =
        socket
        |> put_flash(:error, gettext("Please enter a 6-digit code."))
        |> assign(:form, to_form(%{"code" => ""}, as: :totp))

      {:noreply, socket}
    end
  end
end
