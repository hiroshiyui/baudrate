defmodule BaudrateWeb.AdminTotpVerifyLive do
  @moduledoc """
  LiveView for admin TOTP re-verification (sudo mode).

  Shown when an admin navigates to any `/admin/*` page and their
  `admin_totp_verified_at` session timestamp is missing or expired
  (>10 minutes). Validates the 6-digit format client-side, then uses
  `phx-trigger-action` to POST the code to
  `SessionController.admin_totp_verify/2` for server-side verification.

  The `return_to` parameter is read from URL query params and validated
  (must start with `/admin/`, no path traversal). On successful
  verification, the user is redirected back to the original admin page.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:form, to_form(%{"code" => ""}, as: :admin_totp))
      |> assign(:trigger_action, false)
      |> assign(:page_title, gettext("Admin Verification"))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    return_to = sanitize_return_to(params["return_to"])
    {:noreply, assign(socket, :return_to, return_to)}
  end

  @impl true
  def handle_event("validate", %{"admin_totp" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :admin_totp))}
  end

  @impl true
  def handle_event("submit", %{"admin_totp" => %{"code" => code}}, socket) do
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
        |> assign(:form, to_form(%{"code" => ""}, as: :admin_totp))

      {:noreply, socket}
    end
  end

  @doc false
  defp sanitize_return_to(nil), do: "/admin/settings"

  defp sanitize_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/admin/") &&
         !String.contains?(path, "..") &&
         !String.contains?(path, "//") &&
         !String.contains?(path, "\\") &&
         !String.contains?(path, "\n") &&
         !String.contains?(path, "\r") &&
         !String.contains?(path, "@") do
      path
    else
      "/admin/settings"
    end
  end
end
