defmodule BaudrateWeb.ProfileLive do
  @moduledoc """
  LiveView for the user profile page (`/profile`).

  Displays read-only account details, avatar management, display name editing,
  and locale preferences for the current user. `@current_user` is available
  via the `:require_auth` hook.

  ## Locale Preferences

  Users can add, remove, and reorder preferred locales. Changes are persisted
  to the database and take effect immediately via `Gettext.put_locale/1`.
  The locale is also stored in the cookie session on next login.

  ## Profile Fields

  Users can set up to 4 custom key-value fields (e.g. website, location).
  These are published as `attachment` entries of type `PropertyValue` on the
  ActivityPub actor, matching the Mastodon convention for profile metadata.
  The `@profile_fields` assign is always a list of exactly 4 maps (padded
  with empty entries) for predictable template rendering.

  ## Security Keys

  Registering or removing a WebAuthn key requires step-up re-authentication
  (password, plus the current TOTP code when TOTP is enabled) via
  `Auth.verify_reauthentication/5`. A successful check unlocks key management
  for `@security_reauth_seconds` seconds in this LiveView process only. The
  deadline lives in socket assigns, which the client cannot set, and a reload
  locks it again. Without this gate, a stolen session cookie could enrol the
  attacker's own key and use it to pass admin sudo mode (ADR 0022).

  ## Password and Sessions

  The profile links to `/profile/password` (`PasswordChangeLive`). The Sessions
  section signs out every other session after the same step-up
  re-authentication (`Auth.sign_out_other_sessions/2`). The session to keep is
  identified by its row id (`@session_id`, resolved at mount), not by token,
  because tokens rotate daily.

  ## Blocked and Muted Accounts

  The Blocked Accounts and Muted Users sections list local users and remote
  actors, each with an undo control. Remote actors are stored by AP ID and
  shown as `@user@domain` when the actor is known (`@safety_remote_actors`).
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias Baudrate.Avatar
  alias BaudrateWeb.Locale
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.Helpers, only: [translate_role: 1, extract_peer_ip: 1]

  @security_reauth_seconds 300

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user
    policy = Auth.totp_policy(user.role.name)
    is_active = Auth.user_active?(user)
    can_upload_avatar = Auth.can_upload_avatar?(user)

    display_name_changeset = Baudrate.Setup.User.display_name_changeset(user, %{})
    bio_changeset = Baudrate.Setup.User.bio_changeset(user, %{})
    signature_changeset = Baudrate.Setup.User.signature_changeset(user, %{})
    webauthn_credentials = Auth.list_webauthn_credentials(user)

    socket =
      socket
      |> assign(:totp_policy, policy)
      |> assign(:is_active, is_active)
      |> assign(:can_upload_avatar, can_upload_avatar)
      |> assign(:show_crop_modal, false)
      |> assign(:preferred_locales, user.preferred_locales || [])
      |> assign(:available_locales, Locale.available_locales())
      |> assign(:display_name_form, to_form(display_name_changeset, as: :display_name))
      |> assign(:bio_form, to_form(bio_changeset, as: :bio))
      |> assign(:signature_form, to_form(signature_changeset, as: :signature))
      |> assign(:signature_preview, Baudrate.Content.Markdown.to_html(user.signature))
      |> assign_blocks_and_mutes(user)
      |> assign(:notification_preferences, user.notification_preferences || %{})
      |> assign(:profile_fields, pad_profile_fields(user.profile_fields))
      |> assign(:push_supported, false)
      |> assign(:push_subscribed, false)
      |> assign(:webauthn_credentials, webauthn_credentials)
      |> assign(:webauthn_challenge_token, nil)
      |> assign(:trigger_webauthn_register, false)
      # Set when a language change alters the *effective* locale, so the
      # session copy `SetLocale` reads gets rewritten. See `save_locales/2`.
      |> assign(:trigger_locale_sync, false)
      |> assign(:locale_sync_value, nil)
      |> assign(:security_reauth_until, nil)
      |> assign(:security_reauth_form, empty_security_reauth_form())
      |> assign(:sign_out_form, to_form(%{"password" => "", "code" => ""}, as: :sign_out))
      # Session row id (stable across token rotation) of the session to keep
      # when signing out everywhere else.
      |> assign(:session_id, Auth.session_id_by_token(session["session_token"]))
      |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
      |> assign(:page_title, gettext("Profile"))
      |> allow_upload(:avatar,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 1,
        max_file_size: 5_000_000,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_avatar", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("show_crop_modal", _params, socket) do
    {:noreply, assign(socket, :show_crop_modal, true)}
  end

  @impl true
  def handle_event("cancel_crop", _params, socket) do
    socket =
      socket
      |> assign(:show_crop_modal, false)
      |> push_event("avatar_crop_reset", %{})

    {:noreply, cancel_all_uploads(socket, :avatar)}
  end

  @impl true
  def handle_event("save_crop", crop_params, socket) do
    user = socket.assigns.current_user

    case RateLimits.check_avatar_change(user.id) do
      :ok ->
        process_and_save_avatar(socket, user, crop_params)

      {:error, :rate_limited} ->
        socket =
          socket
          |> put_flash(:error, gettext("Too many avatar changes. Please try again later."))
          |> assign(:show_crop_modal, false)
          |> push_event("avatar_crop_reset", %{})

        {:noreply, cancel_all_uploads(socket, :avatar)}
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
  def handle_event("validate_display_name", %{"display_name" => params}, socket) do
    user = socket.assigns.current_user

    changeset =
      Baudrate.Setup.User.display_name_changeset(user, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :display_name_form, to_form(changeset, as: :display_name))}
  end

  @impl true
  def handle_event(
        "save_display_name",
        %{"display_name" => %{"display_name" => display_name}},
        socket
      ) do
    user = socket.assigns.current_user

    case Auth.update_display_name(user, display_name) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("Display name updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :display_name_form, to_form(changeset, as: :display_name))}
    end
  end

  @impl true
  def handle_event("validate_bio", %{"bio" => params}, socket) do
    user = socket.assigns.current_user

    changeset =
      Baudrate.Setup.User.bio_changeset(user, params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :bio_form, to_form(changeset, as: :bio))}
  end

  @impl true
  def handle_event("save_bio", %{"bio" => %{"bio" => bio}}, socket) do
    user = socket.assigns.current_user

    case Auth.update_bio(user, bio) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("Bio updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :bio_form, to_form(changeset, as: :bio))}
    end
  end

  @impl true
  def handle_event("validate_signature", %{"signature" => params}, socket) do
    user = socket.assigns.current_user

    changeset =
      Baudrate.Setup.User.signature_changeset(user, params)
      |> Map.put(:action, :validate)

    preview = Baudrate.Content.Markdown.to_html(params["signature"] || "")

    {:noreply,
     socket
     |> assign(:signature_form, to_form(changeset, as: :signature))
     |> assign(:signature_preview, preview)}
  end

  @impl true
  def handle_event("save_signature", %{"signature" => %{"signature" => signature}}, socket) do
    user = socket.assigns.current_user

    case Auth.update_signature(user, signature) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:signature_preview, Baudrate.Content.Markdown.to_html(updated_user.signature))
         |> put_flash(:info, gettext("Signature updated."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :signature_form, to_form(changeset, as: :signature))}
    end
  end

  @impl true
  def handle_event("save_profile_fields", params, socket) do
    user = socket.assigns.current_user
    raw = Map.get(params, "profile_fields", %{})
    fields = parse_raw_profile_fields(raw)

    case Auth.update_profile_fields(user, fields) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:profile_fields, pad_profile_fields(updated_user.profile_fields))
         |> put_flash(:info, gettext("Profile fields updated."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update profile fields."))}
    end
  end

  @impl true
  def handle_event("unmute", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    mute = Enum.find(socket.assigns.mutes, &(to_string(&1.id) == id))

    if mute do
      if mute.muted_user_id do
        muted_user = Auth.get_user(mute.muted_user_id)
        if muted_user, do: Auth.unmute_user(user, muted_user)
      else
        Auth.unmute_remote_actor(user, mute.muted_actor_ap_id)
      end

      {:noreply,
       socket
       |> assign_blocks_and_mutes(user)
       |> put_flash(:info, gettext("User unmuted."))
       |> push_event("focus", %{id: "profile-muted-users-heading"})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unblock", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    block = Enum.find(socket.assigns.blocks, &(to_string(&1.id) == id))

    if block do
      if block.blocked_user_id do
        blocked_user = Auth.get_user(block.blocked_user_id)
        if blocked_user, do: Auth.unblock_user(user, blocked_user)
      else
        Auth.unblock_remote_actor(user, block.blocked_actor_ap_id)
      end

      {:noreply,
       socket
       |> assign_blocks_and_mutes(user)
       |> put_flash(:info, gettext("Account unblocked."))
       |> push_event("focus", %{id: "profile-blocked-accounts-heading"})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_dm_access", %{"dm_access" => value}, socket) do
    user = socket.assigns.current_user

    case Auth.update_dm_access(user, value) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("DM access setting updated."))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update DM access setting."))}
    end
  end

  @impl true
  def handle_event(
        "push_support",
        %{"supported" => supported, "subscribed" => subscribed},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:push_supported, supported)
     |> assign(:push_subscribed, subscribed)}
  end

  @impl true
  def handle_event("push_subscribed", _params, socket) do
    {:noreply,
     socket
     |> assign(:push_subscribed, true)
     |> put_flash(:info, gettext("Push notifications enabled."))}
  end

  @impl true
  def handle_event("push_unsubscribed", _params, socket) do
    {:noreply,
     socket
     |> assign(:push_subscribed, false)
     |> put_flash(:info, gettext("Push notifications disabled."))}
  end

  @impl true
  def handle_event("push_permission_denied", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Push notification permission was denied by the browser.")
     )}
  end

  @impl true
  def handle_event("push_subscribe_error", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Failed to enable push notifications."))}
  end

  @impl true
  def handle_event("toggle_web_push_pref", %{"type" => type}, socket) do
    user = socket.assigns.current_user
    prefs = socket.assigns.notification_preferences

    type_prefs = Map.get(prefs, type, %{})
    current_web_push = Map.get(type_prefs, "web_push", true)
    new_type_prefs = Map.put(type_prefs, "web_push", !current_web_push)
    new_prefs = Map.put(prefs, type, new_type_prefs)

    case Auth.update_notification_preferences(user, new_prefs) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:notification_preferences, updated_user.notification_preferences)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to update notification preferences."))}
    end
  end

  @impl true
  def handle_event("toggle_notification_pref", %{"type" => type}, socket) do
    user = socket.assigns.current_user
    prefs = socket.assigns.notification_preferences

    current_in_app = get_in(prefs, [type, "in_app"]) != false
    new_prefs = Map.put(prefs, type, %{"in_app" => !current_in_app})

    case Auth.update_notification_preferences(user, new_prefs) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:notification_preferences, updated_user.notification_preferences)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to update notification preferences."))}
    end
  end

  @impl true
  def handle_event("security_reauth", %{"security_reauth" => params}, socket) do
    user = socket.assigns.current_user

    result =
      with :ok <- RateLimits.check_reauth(user.id) do
        Auth.verify_reauthentication(
          user,
          params["password"],
          params["code"],
          socket.assigns.peer_ip,
          :security_keys
        )
      end

    socket = assign(socket, :security_reauth_form, empty_security_reauth_form())

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(
           :security_reauth_until,
           System.monotonic_time(:second) + @security_reauth_seconds
         )
         |> put_flash(
           :info,
           gettext("Identity confirmed. You can manage your security keys for 5 minutes.")
         )
         |> push_event("focus", %{id: "profile-security-key-register"})}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      {:error, {:throttled, seconds}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Too many failed attempts. Please try again in %{seconds} seconds.",
             seconds: seconds
           )
         )}

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Invalid credentials. Please try again."))
         |> push_event("focus", %{id: "security_reauth_password"})}
    end
  end

  @impl true
  def handle_event("sign_out_everywhere", %{"sign_out" => params}, socket) do
    user = socket.assigns.current_user

    result =
      with :ok <- RateLimits.check_reauth(user.id),
           :ok <-
             Auth.verify_reauthentication(
               user,
               params["password"],
               params["code"],
               socket.assigns.peer_ip,
               :sign_out_everywhere
             ),
           session_id when is_integer(session_id) <- socket.assigns.session_id do
        Auth.sign_out_other_sessions(user, session_id)
      else
        nil -> {:error, :no_session}
        other -> other
      end

    socket =
      assign(socket, :sign_out_form, to_form(%{"password" => "", "code" => ""}, as: :sign_out))

    case result do
      {:ok, revoked} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext(
             "Signed out %{count} other session.",
             "Signed out %{count} other sessions.",
             revoked,
             count: revoked
           )
         )
         |> push_event("focus", %{id: "profile-sessions-heading"})}

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

      {:error, {:throttled, seconds}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Too many failed attempts. Please try again in %{seconds} seconds.",
             seconds: seconds
           )
         )}

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Invalid credentials. Please try again."))
         |> push_event("focus", %{id: "sign_out_password"})}

      {:error, :no_session} ->
        {:noreply,
         put_flash(socket, :error, gettext("Your session has expired. Please sign in again."))}
    end
  end

  @impl true
  def handle_event("begin_registration", _params, socket) do
    with_security_reauth(socket, fn socket ->
      user = socket.assigns.current_user
      {challenge_token, options_json} = Auth.begin_registration(user)

      socket =
        socket
        |> assign(:webauthn_challenge_token, challenge_token)
        |> assign(:trigger_webauthn_register, false)
        |> push_event("webauthn_register", %{options: options_json})

      {:noreply, socket}
    end)
  end

  @impl true
  def handle_event("webauthn_error", %{"reason" => reason}, socket) do
    message =
      case reason do
        "NotAllowedError" -> gettext("Security key registration was cancelled or timed out.")
        "not_supported" -> gettext("WebAuthn is not supported by this browser.")
        _ -> gettext("Security key registration failed. Please try again.")
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def handle_event("delete_webauthn_credential", %{"id" => id}, socket) do
    with_security_reauth(socket, fn socket ->
      user = socket.assigns.current_user

      result =
        case Integer.parse(to_string(id)) do
          {credential_id, ""} -> Auth.delete_webauthn_credential(user, credential_id)
          _ -> {:error, :not_found}
        end

      case result do
        {:ok, _} ->
          credentials = Auth.list_webauthn_credentials(user)

          {:noreply,
           socket
           |> assign(:webauthn_credentials, credentials)
           |> put_flash(:info, gettext("Security key removed."))
           |> push_event("focus", %{id: "security-keys-heading"})}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to remove security key."))}
      end
    end)
  end

  @impl true
  def handle_event("remove_avatar", _params, socket) do
    user = socket.assigns.current_user

    case RateLimits.check_avatar_change(user.id) do
      :ok ->
        Avatar.delete_avatar(user.avatar_id)

        case Auth.remove_avatar(user) do
          {:ok, updated_user} ->
            socket =
              socket
              |> assign(:current_user, updated_user)
              |> put_flash(:info, gettext("Avatar removed."))

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to remove avatar."))}
        end

      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, gettext("Too many avatar changes. Please try again later."))}
    end
  end

  defp process_and_save_avatar(socket, user, crop_params) do
    consumed =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
        case Avatar.process_upload(path, crop_params) do
          {:ok, avatar_id} -> {:ok, {:ok, avatar_id}}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    case consumed do
      [{:ok, avatar_id}] ->
        # Delete old avatar files if they exist
        Avatar.delete_avatar(user.avatar_id)

        case Auth.update_avatar(user, avatar_id) do
          {:ok, updated_user} ->
            socket =
              socket
              |> assign(:current_user, updated_user)
              |> assign(:show_crop_modal, false)
              |> push_event("avatar_crop_reset", %{})
              |> put_flash(:info, gettext("Avatar updated successfully."))

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update avatar."))}
        end

      [{:error, :invalid_image}] ->
        socket =
          socket
          |> assign(:show_crop_modal, false)
          |> push_event("avatar_crop_reset", %{})
          |> put_flash(:error, gettext("Invalid image file."))

        {:noreply, socket}

      [{:error, _reason}] ->
        socket =
          socket
          |> assign(:show_crop_modal, false)
          |> push_event("avatar_crop_reset", %{})
          |> put_flash(:error, gettext("Failed to process avatar image."))

        {:noreply, socket}

      [] ->
        {:noreply, socket}
    end
  end

  defp cancel_all_uploads(socket, upload_name) do
    Enum.reduce(socket.assigns.uploads[upload_name].entries, socket, fn entry, acc ->
      cancel_upload(acc, upload_name, entry.ref)
    end)
  end

  defp upload_error_to_string(err), do: BaudrateWeb.Helpers.upload_error_to_string(err)

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

  # Runs `fun` only while a step-up re-authentication is still fresh. This is
  # the server-side gate: the template hides the key management controls when
  # locked, but events can be sent regardless of what is rendered.
  defp with_security_reauth(socket, fun) do
    until = socket.assigns.security_reauth_until

    if until && System.monotonic_time(:second) < until do
      fun.(socket)
    else
      {:noreply,
       socket
       |> assign(:security_reauth_until, nil)
       |> put_flash(
         :error,
         gettext("Please confirm your identity before managing security keys.")
       )
       |> push_event("focus", %{id: "security_reauth_password"})}
    end
  end

  defp empty_security_reauth_form do
    to_form(%{"password" => "", "code" => ""}, as: :security_reauth)
  end

  defp pad_profile_fields(nil), do: List.duplicate(%{"name" => "", "value" => ""}, 4)

  defp pad_profile_fields(fields) when is_list(fields) do
    empty = %{"name" => "", "value" => ""}
    padded = fields ++ List.duplicate(empty, 4)
    Enum.take(padded, 4)
  end

  defp parse_raw_profile_fields(raw) when is_map(raw) do
    raw
    |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
    |> Enum.map(fn {_, field} ->
      name = Map.get(field, "name", "") |> String.trim()
      value = Map.get(field, "value", "") |> String.trim()
      %{"name" => name, "value" => value}
    end)
    |> Enum.reject(fn %{"name" => name} -> name == "" end)
  end

  defp parse_raw_profile_fields(_), do: []

  # Blocks and mutes of remote actors are stored by AP ID; the known actors are
  # looked up so the lists can show `@user@domain` instead of a bare URI.
  defp assign_blocks_and_mutes(socket, user) do
    blocks = Auth.list_blocks(user)
    mutes = Auth.list_mutes(user)

    remote_actors =
      (Enum.map(blocks, & &1.blocked_actor_ap_id) ++ Enum.map(mutes, & &1.muted_actor_ap_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Baudrate.Federation.remote_actors_by_ap_ids()

    assign(socket, blocks: blocks, mutes: mutes, safety_remote_actors: remote_actors)
  end

  attr :user, :any, default: nil
  attr :ap_id, :string, default: nil
  attr :remote_actors, :map, required: true
  attr :name_class, :string, required: true

  # One account in the blocked or muted list: a local user, a known remote
  # actor, or (for an actor this instance no longer knows) its AP ID.
  defp safety_list_account(assigns) do
    assigns =
      assign(assigns, :remote_actor, assigns.ap_id && assigns.remote_actors[assigns.ap_id])

    ~H"""
    <%= cond do %>
      <% @user -> %>
        <.avatar user={@user} size={36} />
        <span class={[@name_class, "font-semibold break-words min-w-0"]}>
          {display_name(@user)}
          <span class="text-sm font-normal text-base-content/70">@{@user.username}</span>
        </span>
      <% @remote_actor -> %>
        <div class="avatar avatar-placeholder">
          <div
            class="bg-neutral text-neutral-content rounded-full"
            style="width: 36px; height: 36px"
          >
            <span class="text-xs">@</span>
          </div>
        </div>
        <span class={[@name_class, "font-semibold break-words min-w-0"]}>
          {display_name(@remote_actor)}
          <span class="text-sm font-normal text-base-content/70 break-all">
            @{@remote_actor.username}@{@remote_actor.domain}
          </span>
        </span>
      <% true -> %>
        <div class="avatar avatar-placeholder">
          <div
            class="bg-neutral text-neutral-content rounded-full"
            style="width: 36px; height: 36px"
          >
            <span class="text-xs">@</span>
          </div>
        </div>
        <span class={[@name_class, "text-sm text-base-content/70 break-all min-w-0"]}>{@ap_id}</span>
    <% end %>
    """
  end

  defp safety_list_name(%Baudrate.Setup.User{username: username}, _ap_id, _actors), do: username

  defp safety_list_name(_user, ap_id, actors) do
    case actors[ap_id] do
      %{username: username, domain: domain} -> "@#{username}@#{domain}"
      nil -> ap_id
    end
  end
end
