defmodule BaudrateWeb.ProfileAccountLive do
  @moduledoc """
  LiveView for a member's account settings (`/profile/account`): preferred
  languages, the time zone timestamps are shown in (`BaudrateWeb.TimeZone`),
  and the ways to take the account elsewhere — the data export
  (`/profile/export`) and account migration (`/profile/move`).

  ## Locale Preferences

  Users can add, remove, and reorder preferred locales. Changes are persisted
  to the database and take effect immediately via `Gettext.put_locale/1`.
  When the *effective* locale moves, the hidden `locale-sync-form` posts it to
  `BaudrateWeb.LocaleController`, the session write a LiveView cannot make
  (see `save_locales/2`).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias BaudrateWeb.Locale

  import BaudrateWeb.ProfileComponents

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:preferred_locales, user.preferred_locales || [])
      |> assign(:available_locales, Locale.available_locales())
      # Set when a language change alters the *effective* locale, so the
      # session copy `SetLocale` reads gets rewritten. See `save_locales/2`.
      |> assign(:trigger_locale_sync, false)
      |> assign(:locale_sync_value, nil)
      |> assign(:zones, Baudrate.Timezone.identifiers())
      |> assign(:site_zone, BaudrateWeb.TimeZone.site_zone())
      |> assign_time_zone_form(user.time_zone)
      |> assign(:page_title, gettext("Account"))

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_time_zone", %{"time_zone" => %{"time_zone" => zone}}, socket) do
    # Assigned back so a re-render never resets the select to the stored value.
    {:noreply, assign_time_zone_form(socket, zone)}
  end

  @impl true
  def handle_event("save_time_zone", %{"time_zone" => %{"time_zone" => zone}}, socket) do
    save_time_zone(socket, zone)
  end

  @impl true
  def handle_event("use_device_time_zone", %{"zone" => zone}, socket) when is_binary(zone) do
    if zone in socket.assigns.zones do
      save_time_zone(socket, zone)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext(
           "This device did not report a time zone this site knows. Choose one from the list."
         )
       )}
    end
  end

  @impl true
  def handle_event("add_locale", %{"locale" => locale}, socket) do
    current = socket.assigns.preferred_locales

    if locale in current do
      {:noreply, socket}
    else
      save_locales(socket, current ++ [locale])
    end
  end

  @impl true
  def handle_event("remove_locale", %{"locale" => locale}, socket) do
    new_locales = Enum.reject(socket.assigns.preferred_locales, &(&1 == locale))
    save_locales(socket, new_locales)
  end

  @impl true
  def handle_event("move_locale_up", %{"locale" => locale}, socket) do
    locales = socket.assigns.preferred_locales
    idx = Enum.find_index(locales, &(&1 == locale))

    if idx && idx > 0 do
      new_locales = swap(locales, idx, idx - 1)
      save_locales(socket, new_locales)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("move_locale_down", %{"locale" => locale}, socket) do
    locales = socket.assigns.preferred_locales
    idx = Enum.find_index(locales, &(&1 == locale))

    if idx && idx < length(locales) - 1 do
      new_locales = swap(locales, idx, idx + 1)
      save_locales(socket, new_locales)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp save_time_zone(socket, zone) do
    case Auth.update_time_zone(socket.assigns.current_user, zone) do
      {:ok, updated_user} ->
        # This process renders the page, so it switches now, as
        # `save_locales/2` switches the language with `Gettext.put_locale/1`.
        BaudrateWeb.TimeZone.put(updated_user.time_zone)

        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign_time_zone_form(updated_user.time_zone)
         |> put_flash(:info, gettext("Time zone updated."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("That is not a time zone this site knows."))}
    end
  end

  defp assign_time_zone_form(socket, zone) do
    assign(socket, :time_zone_form, to_form(%{"time_zone" => zone || ""}, as: :time_zone))
  end

  defp save_locales(socket, new_locales) do
    user = socket.assigns.current_user
    was = Locale.resolve_from_preferences(socket.assigns.preferred_locales)

    case Auth.update_preferred_locales(user, new_locales) do
      {:ok, updated_user} ->
        now = Locale.resolve_from_preferences(new_locales)
        locale = now || Gettext.get_locale()

        Gettext.put_locale(locale)

        socket =
          socket
          |> assign(:current_user, updated_user)
          |> assign(:preferred_locales, updated_user.preferred_locales)
          |> assign(:locale, locale)
          |> maybe_sync_session_locale(was, now)
          |> put_flash(:info, gettext("Language preferences updated."))

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update language preferences."))}
    end
  end

  # `BaudrateWeb.Plugs.SetLocale` reads a member's language from
  # `session[:preferred_locales]`, which is written at login and nowhere else,
  # and a LiveView cannot write the session. So changing the language here left
  # that copy stale: every later full page load rendered its dead HTML — and
  # `lang=` on `<html>` — in the old language, telling a screen reader the
  # wrong thing on every single load, until the member signed in again.
  #
  # Posting to `LocaleController` is the session write that was missing. Only
  # when the *effective* locale moved: reordering the entries below the head
  # changes the account without changing what anyone reads, and a page reload
  # there would be gratuitous.
  defp maybe_sync_session_locale(socket, same, same), do: socket

  defp maybe_sync_session_locale(socket, _was, now) do
    socket
    |> assign(:locale_sync_value, now || Locale.auto())
    |> assign(:trigger_locale_sync, true)
  end

  defp swap(list, i, j) do
    list
    |> List.replace_at(i, Enum.at(list, j))
    |> List.replace_at(j, Enum.at(list, i))
  end
end
