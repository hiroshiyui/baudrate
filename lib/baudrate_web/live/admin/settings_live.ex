defmodule BaudrateWeb.Admin.SettingsLive do
  @moduledoc """
  LiveView for managing site-wide admin settings.

  Only accessible to users with the `"admin"` role. Provides a form
  to edit the site name, timezone, registration mode, federation settings,
  and End User Agreement, backed by the `Baudrate.Setup` context.

  Also shows read-only system information: the running Baudrate release
  version and the Elixir, Erlang/OTP, and ERTS versions it runs on. The
  Baudrate version is already public through NodeInfo and the federation
  `User-Agent`; the runtime versions are shown to admins only.
  """

  use BaudrateWeb, :live_view

  on_mount {BaudrateWeb.AuthHooks, :require_admin}

  alias Baudrate.Setup

  @impl true
  def mount(_params, _session, socket) do
    changeset = Setup.change_settings()
    eua = Setup.get_eua() || ""

    timezone_options =
      Baudrate.Timezone.identifiers()
      |> Enum.map(&{&1, &1})

    vapid_public_key = Setup.get_setting("vapid_public_key")

    socket =
      socket
      |> assign(form: to_form(changeset, as: :settings))
      |> assign(eua: eua)
      |> assign(eua_form: to_form(%{"eua" => eua}, as: :eua_settings))
      |> assign(timezone_options: timezone_options)
      |> assign(light_theme_options: Setup.light_theme_options())
      |> assign(dark_theme_options: Setup.dark_theme_options())
      |> assign(vapid_configured: vapid_public_key != nil)
      |> assign(vapid_public_key: vapid_public_key)
      |> assign(system_info: system_info())
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

  @impl true
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

  @impl true
  def handle_event("validate_eua", %{"eua_settings" => params}, socket) do
    {:noreply, assign(socket, eua_form: to_form(params, as: :eua_settings))}
  end

  @impl true
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

  @impl true
  def handle_event("generate_vapid_keys", _params, socket) do
    alias Baudrate.Notification.VAPID

    {public_key_b64, encrypted_private} = VAPID.generate_keypair()

    Setup.set_setting("vapid_public_key", public_key_b64)
    Setup.set_setting("vapid_private_key_encrypted", Base.encode64(encrypted_private))
    Baudrate.Setup.SettingsCache.refresh()

    {:noreply,
     socket
     |> assign(vapid_configured: true)
     |> assign(vapid_public_key: public_key_b64)
     |> put_flash(:info, gettext("VAPID keys generated successfully."))}
  end

  # Versions of the running node, read at mount time. `otp_release` is only
  # the major release ("28"); the ERTS version pins the exact runtime build
  # bundled into the release.
  defp system_info do
    %{
      baudrate: Application.spec(:baudrate, :vsn) |> to_string(),
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      erts: :erlang.system_info(:version) |> to_string()
    }
  end
end
