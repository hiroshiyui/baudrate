defmodule BaudrateWeb.TotpVerifyLive do
  use BaudrateWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:form, to_form(%{"code" => ""}, as: :totp))
      |> assign(:trigger_action, false)

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
