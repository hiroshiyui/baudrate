defmodule BaudrateWeb.TotpSetupLive do
  use BaudrateWeb, :live_view

  alias Baudrate.Auth

  @impl true
  def mount(_params, session, socket) do
    secret = session["totp_setup_secret"]

    if is_nil(secret) do
      {:ok, redirect(socket, to: "/login"), layout: {BaudrateWeb.Layouts, :setup}}
    else
      username = socket.assigns.current_user.username
      uri = Auth.totp_uri(secret, username)
      qr_svg = Auth.totp_qr_svg(uri)
      secret_b32 = Base.encode32(secret, padding: false)
      policy = Auth.totp_policy(socket.assigns.current_user.role.name)

      socket =
        socket
        |> assign(:secret_b32, secret_b32)
        |> assign(:qr_svg, qr_svg)
        |> assign(:policy, policy)
        |> assign(:form, to_form(%{"code" => ""}, as: :totp))
        |> assign(:trigger_action, false)

      {:ok, socket, layout: {BaudrateWeb.Layouts, :setup}}
    end
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
