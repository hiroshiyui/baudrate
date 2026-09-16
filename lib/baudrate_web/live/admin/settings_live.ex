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

  alias Baudrate.{Moderation, Setup}

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
    before = Map.new(params, fn {key, _} -> {key, Setup.get_setting(key)} end)

    case Setup.save_settings(params) do
      {:ok, _changes} ->
        log_settings_change(socket.assigns.current_user.id, before)
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
        Moderation.log_action(socket.assigns.current_user.id, "update_eua")

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
    Moderation.log_action(socket.assigns.current_user.id, "generate_vapid_keys")
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

  # Records which settings changed. Allowlist edits also list the domains added
  # and removed, so a domain losing its allowance is as visible as gaining one.
  # Blocked domains are rows and are audited by `Federation.DomainBlocks`.
  defp log_settings_change(actor_id, before) do
    changed =
      before
      |> Enum.filter(fn {key, old} -> Setup.get_setting(key) != old end)
      |> Enum.map(fn {key, _} -> key end)
      |> Enum.sort()

    if changed != [] do
      details =
        Enum.reduce(~w(ap_domain_allowlist), %{changed: changed}, fn key, acc ->
          if key in changed do
            old = domain_set(before[key])
            new = domain_set(Setup.get_setting(key))

            Map.put(acc, key, %{
              added: MapSet.difference(new, old) |> Enum.sort(),
              removed: MapSet.difference(old, new) |> Enum.sort()
            })
          else
            acc
          end
        end)

      Moderation.log_action(actor_id, "update_settings", details: details)
    end
  end

  defp domain_set(nil), do: MapSet.new()

  defp domain_set(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end
end
