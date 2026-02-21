defmodule BaudrateWeb.Admin.SettingsLive do
  @moduledoc """
  LiveView for managing site-wide admin settings.

  Only accessible to users with the `"admin"` role. Provides a form
  to edit the site name and registration mode, backed by the
  `Baudrate.Setup` context's virtual changeset.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Setup

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user.role.name != "admin" do
      {:ok,
       socket
       |> put_flash(:error, gettext("Access denied."))
       |> redirect(to: ~p"/")}
    else
      changeset = Setup.change_settings()
      {:ok, assign(socket, form: to_form(changeset, as: :settings))}
    end
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
end
