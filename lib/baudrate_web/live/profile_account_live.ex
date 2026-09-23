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

  ## Deleting the account

  `Baudrate.AccountDeletion.request/3` checks the password (and TOTP code)
  and signs out every other session. This session is signed out by the
  hidden `account-deletion-signout-form`, which posts to
  `SessionController.deletion_requested/2` — a LiveView cannot clear its own
  cookie — and lands the member on `/login` with the date (ADR 0072).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.AccountDeletion
  alias Baudrate.Auth
  alias BaudrateWeb.Locale
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers, only: [extract_peer_ip: 1]

  import BaudrateWeb.ProfileComponents

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user
    user_agent = if connected?(socket), do: get_connect_info(socket, :user_agent), else: nil

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
      |> assign(:session_id, Auth.session_id_by_token(session["session_token"]))
      |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
      |> assign(:user_agent, user_agent)
      |> assign(:deletion_eligibility, AccountDeletion.eligibility(user))
      |> assign(:can_export, Baudrate.DataPortability.eligibility(user) == :ok)
      |> assign(:trigger_deletion_signout, false)
      |> assign_deletion_form(%{})

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
  def handle_event("request_deletion", %{"deletion" => params}, socket) do
    user = socket.assigns.current_user
    withdraw? = params["withdraw_content"] == "true"

    result =
      with :ok <- RateLimits.check_reauth(user.id) do
        AccountDeletion.request(
          user,
          %{password: params["password"], code: params["code"]},
          ip_address: socket.assigns.peer_ip,
          session_id: socket.assigns.session_id,
          user_agent: socket.assigns.user_agent,
          withdraw_content: withdraw?
        )
      end

    case result do
      {:ok, _deletion} ->
        # Every other session is gone; this one leaves through the form.
        {:noreply, assign(socket, :trigger_deletion_signout, true)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign_deletion_form(%{"withdraw_content" => to_string(withdraw?)})
         |> put_flash(:error, deletion_error(reason))
         |> push_event("focus", %{id: "account-deletion-password"})}
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

  defp assign_deletion_form(socket, params) do
    assign(socket, :deletion_form, to_form(params, as: :deletion))
  end

  defp deletion_error(:invalid_credentials), do: gettext("Invalid credentials. Please try again.")
  defp deletion_error(:rate_limited), do: gettext("Too many attempts. Please try again later.")

  defp deletion_error({:throttled, seconds}),
    do:
      gettext("Too many failed attempts. Please try again in %{seconds} seconds.",
        seconds: seconds
      )

  defp deletion_error(:pending_deletion_exists),
    do: gettext("Deleting this account has already been requested.")

  defp deletion_error(reason), do: deletion_ineligible_message(reason)

  @doc false
  def deletion_ineligible_message(:bot),
    do: gettext("Bot accounts are deleted by an administrator.")

  def deletion_ineligible_message(:staff),
    do:
      gettext(
        "Administrators and moderators cannot delete their account. Ask to be demoted first."
      )

  def deletion_ineligible_message(:board_moderator),
    do:
      gettext(
        "Board moderators cannot delete their account. Ask to be removed as a moderator first."
      )

  def deletion_ineligible_message(_), do: gettext("This account cannot be deleted.")

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
