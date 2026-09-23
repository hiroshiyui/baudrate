defmodule BaudrateWeb.ProfileSecurityLive do
  @moduledoc """
  LiveView for a member's account security (`/profile/security`): two-factor
  authentication, password, security keys, recovery codes and contacts, and
  sessions.

  ## Security Keys

  Registering or removing a WebAuthn key requires step-up re-authentication
  (password, plus the current TOTP code when TOTP is enabled) via
  `Auth.verify_reauthentication/5`. A successful check unlocks key management
  for `@security_reauth_seconds` seconds in this LiveView process only. The
  deadline lives in socket assigns, which the client cannot set, and a reload
  — or moving to another settings page — locks it again. Without this gate,
  a stolen session cookie could enrol the attacker's own key and use it to
  pass admin sudo mode (ADR 0022).

  ## Password and Sessions

  The page links to `/profile/password` (`PasswordChangeLive`). The Sessions
  section signs out every other session after the same step-up
  re-authentication (`Auth.sign_out_other_sessions/2`). The session to keep is
  identified by its row id (`@session_id`, resolved at mount), not by token,
  because tokens rotate daily.
  """

  use BaudrateWeb, :live_view

  alias Baudrate.Auth
  alias BaudrateWeb.RateLimits

  import BaudrateWeb.ProfileComponents
  import BaudrateWeb.Helpers, only: [extract_peer_ip: 1, parse_id: 1]

  @security_reauth_seconds 300

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:totp_policy, Auth.totp_policy(user.role.name))
      |> assign(:webauthn_credentials, Auth.list_webauthn_credentials(user))
      |> assign(:webauthn_challenge_token, nil)
      |> assign(:trigger_webauthn_register, false)
      |> assign(:security_reauth_until, nil)
      |> assign(:security_reauth_form, empty_security_reauth_form())
      # Account recovery (ADR 0058). `:fresh_recovery_codes` holds a batch
      # just generated, shown once and never read back from anywhere.
      |> assign(:fresh_recovery_codes, nil)
      |> assign(:unused_recovery_codes, Auth.unused_recovery_code_count(user))
      |> assign(:recovery_contacts, Auth.list_recovery_contacts(user))
      |> assign(:contact_form, empty_contact_form())
      |> assign(:sign_out_form, to_form(%{"password" => "", "code" => ""}, as: :sign_out))
      # Session row id (stable across token rotation) of the session to keep
      # when signing out everywhere else.
      |> assign(:session_id, Auth.session_id_by_token(session["session_token"]))
      |> assign(:sessions, Auth.list_sessions(user.id))
      |> assign(:sessions_status, "")
      |> assign(:peer_ip, if(connected?(socket), do: extract_peer_ip(socket), else: "unknown"))
      |> assign(:page_title, gettext("Security"))

    {:ok, socket}
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
           gettext(
             "Identity confirmed. You can change your account security settings for 5 minutes."
           )
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
  def handle_event("regenerate_recovery_codes", _params, socket) do
    with_security_reauth(socket, fn socket ->
      user = socket.assigns.current_user

      # The step-up unlock is rate-limited, but it opens a five-minute window
      # in which this handler is free. Each call mints ten codes and sends an
      # always-delivered notice, which can be a Web Push per subscribed
      # device — outbound traffic a scripted loop should not be able to
      # generate.
      case RateLimits.check_recovery_codes(user.id) do
        {:error, :rate_limited} ->
          {:noreply,
           put_flash(socket, :error, gettext("Too many attempts. Please try again later."))}

        :ok ->
          codes = Auth.regenerate_recovery_codes(user)

          {:noreply,
           socket
           |> assign(:fresh_recovery_codes, codes)
           |> assign(:unused_recovery_codes, length(codes))
           |> put_flash(:info, gettext("New recovery codes issued. The old ones no longer work."))}
      end
    end)
  end

  @impl true
  def handle_event("dismiss_recovery_codes", _params, socket) do
    # They are shown once and are not stored in readable form anywhere, so
    # this is genuinely the last chance — the button says so.
    {:noreply, assign(socket, :fresh_recovery_codes, nil)}
  end

  @impl true
  def handle_event("validate_recovery_contact", %{"contact" => params}, socket) do
    {:noreply, assign(socket, :contact_form, to_form(params, as: :contact))}
  end

  @impl true
  def handle_event("add_recovery_contact", %{"contact" => params}, socket) do
    with_security_reauth(socket, fn socket ->
      user = socket.assigns.current_user

      case Auth.add_recovery_contact(user, params) do
        {:ok, _contact} ->
          {:noreply,
           socket
           |> assign(:recovery_contacts, Auth.list_recovery_contacts(user))
           |> assign(:contact_form, empty_contact_form())
           |> put_flash(
             :info,
             gettext("Recovery contact saved. An admin has to verify it before it can be used.")
           )}

        {:error, :too_many} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("You can register at most %{count} recovery contacts.",
               count: Auth.max_recovery_contacts()
             )
           )}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :contact_form, to_form(changeset, as: :contact))}

        # Typed patterns above, so anything else — a gate refusal, a new
        # error value — would be a CaseClauseError rather than a flash.
        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             BaudrateWeb.Helpers.refusal_message(
               reason,
               user,
               gettext("Could not save that recovery contact.")
             )
           )}
      end
    end)
  end

  @impl true
  def handle_event("remove_recovery_contact", %{"id" => id}, socket) do
    with_security_reauth(socket, fn socket ->
      user = socket.assigns.current_user

      with {:ok, contact_id} <- parse_id(id),
           {:ok, _contact} <- Auth.remove_recovery_contact(user, contact_id) do
        {:noreply,
         socket
         |> assign(:recovery_contacts, Auth.list_recovery_contacts(user))
         |> put_flash(:info, gettext("Recovery contact removed."))}
      else
        _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove that contact."))}
      end
    end)
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
         |> assign(:sessions, Auth.list_sessions(user.id))
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
  def handle_event("revoke_session", %{"id" => id}, socket) do
    with_security_reauth(socket, fn socket ->
      user = socket.assigns.current_user

      result =
        with {:ok, session_id} <- parse_id(id) do
          Auth.revoke_session(user.id, session_id, socket.assigns.session_id)
        end

      case result do
        :ok ->
          {:noreply,
           socket
           |> assign(:sessions, Auth.list_sessions(user.id))
           |> assign(:sessions_status, gettext("Session signed out."))
           |> push_event("focus", %{id: "profile-sessions-heading"})}

        {:error, :no_session} ->
          {:noreply,
           put_flash(socket, :error, gettext("Your session has expired. Please sign in again."))}

        _ ->
          {:noreply,
           socket
           |> assign(:sessions, Auth.list_sessions(user.id))
           |> put_flash(:error, gettext("That session could not be signed out."))}
      end
    end)
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
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp empty_contact_form do
    to_form(%{"email" => "", "pgp_public_key" => "", "label" => ""}, as: :contact)
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
         gettext("Please confirm your identity before changing account security settings.")
       )
       |> push_event("focus", %{id: "security_reauth_password"})}
    end
  end

  defp empty_security_reauth_form do
    to_form(%{"password" => "", "code" => ""}, as: :security_reauth)
  end

  # The browser and system a session signed in with, translated here rather
  # than in `UserAgent`, whose `family/1` string is stored English.
  defp session_device(%{browser: nil, os: nil}), do: gettext("Unknown browser")
  defp session_device(%{browser: browser, os: nil}), do: browser
  defp session_device(%{browser: nil, os: os}), do: os

  defp session_device(%{browser: browser, os: os}),
    do: gettext("%{browser} on %{os}", browser: browser, os: os)
end
