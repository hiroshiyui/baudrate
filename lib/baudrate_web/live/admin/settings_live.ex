defmodule BaudrateWeb.Admin.SettingsLive do
  @moduledoc """
  LiveView for managing site-wide admin settings.

  Only accessible to users with the `"admin"` role. Provides a form
  to edit the site name, registration mode, federation settings, and
  End User Agreement, backed by the `Baudrate.Setup` context.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Setup

  @impl true
  def mount(_params, _session, socket) do
    changeset = Setup.change_settings()
    eua = Setup.get_eua() || ""

    socket =
      socket
      |> assign(form: to_form(changeset, as: :settings))
      |> assign(eua: eua)
      |> assign(eua_form: to_form(%{"eua" => eua}, as: :eua_settings))
      |> assign(page_title: gettext("Admin Settings"))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    changeset =
      Setup.change_settings(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :settings))}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    case Setup.save_settings(params) do
      {:ok, _changes} ->
        changeset = Setup.change_settings()

        {:noreply,
         socket
         |> put_flash(:info, gettext("Settings saved successfully."))
         |> assign(form: to_form(changeset, as: :settings))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :settings))}
    end
  end

  def handle_event("validate_eua", %{"eua_settings" => params}, socket) do
    {:noreply, assign(socket, eua_form: to_form(params, as: :eua_settings))}
  end

  def handle_event("save_eua", %{"eua_settings" => %{"eua" => eua_text}}, socket) do
    case Setup.update_eua(eua_text) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(eua: eua_text)
         |> put_flash(:info, gettext("End User Agreement saved."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save End User Agreement."))}
    end
  end
end
