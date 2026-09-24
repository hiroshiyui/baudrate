defmodule BaudrateWeb.AuthHooks do
  @moduledoc """
  LiveView `on_mount` hooks for authentication enforcement.

  Six hooks are provided, each attached to `live_session` scopes in the router:

    * `:require_auth` — requires a fully authenticated session (`session_token`
      present and valid). Used for the `:authenticated` live_session. Assigns
      `@current_user` on success, redirects to `/login` on failure.
      Also resolves the user's preferred locale from `user.preferred_locales`
      and sets Gettext locale + `@locale` assign.

    * `:optional_auth` — loads the user if a valid session exists, but does not
      redirect if unauthenticated. Assigns `@current_user` (may be `nil`).
      Used for pages that are accessible to both guests and authenticated users.
      Also resolves locale when a user is present.

    * `:require_password_auth` — requires password-level auth only (`user_id`
      in session). Used for the `:totp` live_session where the user has passed
      password auth but hasn't completed TOTP yet. Assigns `@current_user`.
      Also resolves the user's preferred locale.

    * `:redirect_if_authenticated` — if the user already has a valid
      `session_token`, redirects to `/`. Used for the `:public` live_session
      (login page) to prevent authenticated users from seeing the login form.

    * `:require_admin_totp` — requires periodic TOTP re-verification for admin
      users accessing `/admin/*` pages (sudo mode). Checks
      `admin_totp_verified_at` in the cookie session; if missing or older than
      10 minutes, redirects to `/admin/verify?return_to=<path>`. Non-admin
      users (e.g. moderators) pass through without re-verification.
      Used in the `:admin` live_session.

    * `:rate_limit_mount` — rate limits WebSocket connections per IP address
      (60 mounts per minute). Only enforced on connected mounts (skips static
      render). Fails open on backend errors.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  use Gettext, backend: BaudrateWeb.Gettext

  alias Baudrate.Auth
  alias Baudrate.Messaging
  alias Baudrate.Notification
  alias BaudrateWeb.AnnouncementNoticeHook
  alias BaudrateWeb.AutocompleteSuggestHook
  alias BaudrateWeb.Crawlers
  alias BaudrateWeb.MarkdownPreviewHook
  alias BaudrateWeb.RecoveryNoticeHook
  alias BaudrateWeb.UnreadDmCountHook
  alias BaudrateWeb.UnreadNotificationCountHook
  import BaudrateWeb.Helpers, only: [extract_peer_ip: 1]

  def on_mount(:require_auth, _params, session, socket) do
    apply_session_locale(session)
    session_token = session["session_token"]

    if session_token do
      case Auth.get_user_by_session_token(session_token) do
        {:ok, user} ->
          cond do
            # Its sessions were revoked when it was deleted; this is the
            # backstop (ADR 0072).
            user.status == "deleted" ->
              {:halt, to_login(socket)}

            user.status == "banned" ->
              {:halt,
               socket
               |> put_flash(:error, gettext("Your account has been banned."))
               |> redirect(to: "/login")}

            # Defence in depth behind `authenticate_by_password/2`: a
            # suspension issued mid-session revokes the sessions, but a
            # session created before it must not survive either (ADR 0029).
            suspended?(user) ->
              {:halt,
               socket
               |> put_flash(:error, gettext("Your account is suspended."))
               |> redirect(to: "/login")}

            true ->
              locale = resolve_user_locale(user)

              socket =
                socket
                |> assign(:current_user, user)
                |> assign(:locale, locale)
                |> assign(:unread_dm_count, Messaging.unread_count(user))
                |> assign(:unread_notification_count, Notification.unread_count(user.id))
                # Warning banner while a data export request is pending/ready (ADR 0023).
                |> assign(
                  :active_data_export,
                  Baudrate.DataPortability.active_request_summary(user.id)
                )
                # Warning banner while an account move is pending (ADR 0025).
                |> assign(
                  :active_account_move,
                  Baudrate.AccountMigration.active_move_summary(user.id)
                )
                # A restriction the member is under, so the banner can say
                # what stands and until when (ADR 0029).
                |> assign(:active_sanction, List.first(Auth.active_sanctions(user)))
                # Published terms this member has not accepted yet (P1-D8).
                |> assign(:terms_pending, Auth.terms_pending?(user))
                # Whether this account can be recovered at all (ADR 0058).
                |> assign(:recovery_pending, recovery_pending?(user))
                # The member's muted words, compiled once per mount (ADR 0073).
                |> assign(:muted_matchers, muted_matchers(user))
                # Site announcements this member has not dismissed (7B).
                |> assign(:announcements, Baudrate.Announcements.active_for(user))
                |> AnnouncementNoticeHook.attach()
                |> MarkdownPreviewHook.attach()
                |> AutocompleteSuggestHook.attach()
                |> RecoveryNoticeHook.attach()
                |> UnreadDmCountHook.attach(user)
                |> UnreadNotificationCountHook.attach(user)
                |> attach_page_metadata_hook()

              {:cont, socket}
          end

        {:error, _reason} ->
          {:halt, to_login(socket)}
      end
    else
      {:halt, to_login(socket)}
    end
  end

  def on_mount(:optional_auth, _params, session, socket) do
    locale = apply_session_locale(session)
    session_token = session["session_token"]

    if session_token do
      case Auth.get_user_by_session_token(session_token) do
        {:ok, user} ->
          # A suspended account is signed out everywhere, not just kept off
          # the authenticated pages: it browses as a guest would (ADR 0029).
          if user.status in ["banned", "deleted"] or suspended?(user) do
            {:cont,
             socket
             |> assign(:current_user, nil)
             |> assign(:locale, locale)
             |> assign(:muted_matchers, [])
             |> assign(:announcements, Baudrate.Announcements.active_for(nil))
             |> AnnouncementNoticeHook.attach()}
          else
            locale = resolve_user_locale(user)

            socket =
              socket
              |> assign(:current_user, user)
              |> assign(:locale, locale)
              |> assign(:unread_dm_count, Messaging.unread_count(user))
              |> assign(:unread_notification_count, Notification.unread_count(user.id))
              # Warning banner while a data export request is pending/ready (ADR 0023).
              |> assign(
                :active_data_export,
                Baudrate.DataPortability.active_request_summary(user.id)
              )
              # Warning banner while an account move is pending (ADR 0025).
              |> assign(
                :active_account_move,
                Baudrate.AccountMigration.active_move_summary(user.id)
              )
              # A restriction the member is under, so the banner can say what
              # stands and until when (ADR 0029).
              |> assign(:active_sanction, List.first(Auth.active_sanctions(user)))
              # Published terms this member has not accepted yet (P1-D8).
              |> assign(:terms_pending, Auth.terms_pending?(user))
              # Whether this account can be recovered at all (ADR 0058).
              |> assign(:recovery_pending, recovery_pending?(user))
              |> assign(:muted_matchers, muted_matchers(user))
              |> assign(:announcements, Baudrate.Announcements.active_for(user))
              |> AnnouncementNoticeHook.attach()
              |> MarkdownPreviewHook.attach()
              |> AutocompleteSuggestHook.attach()
              |> RecoveryNoticeHook.attach()
              |> UnreadDmCountHook.attach(user)
              |> UnreadNotificationCountHook.attach(user)
              |> attach_page_metadata_hook()

            {:cont, socket}
          end

        {:error, _reason} ->
          {:cont,
           socket
           |> assign(:current_user, nil)
           |> assign(:locale, locale)
           |> assign(:muted_matchers, [])
           |> assign(:announcements, Baudrate.Announcements.active_for(nil))
           |> AnnouncementNoticeHook.attach()
           |> MarkdownPreviewHook.attach()
           |> attach_page_metadata_hook()}
      end
    else
      {:cont,
       socket
       |> assign(:current_user, nil)
       |> assign(:locale, locale)
       |> assign(:recovery_pending, false)
       |> assign(:muted_matchers, [])
       |> assign(:announcements, Baudrate.Announcements.active_for(nil))
       |> AnnouncementNoticeHook.attach()
       |> MarkdownPreviewHook.attach()
       |> attach_page_metadata_hook()}
    end
  end

  def on_mount(:require_password_auth, _params, session, socket) do
    apply_session_locale(session)
    user_id = session["user_id"]

    if user_id do
      user = Auth.get_user(user_id)

      if user && user.status not in ["banned", "deleted"] && not suspended?(user) do
        locale = resolve_user_locale(user)

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:locale, locale)
          |> attach_page_metadata_hook()

        {:cont, socket}
      else
        {:halt, redirect(socket, to: "/login")}
      end
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    apply_session_locale(session)
    session_token = session["session_token"]

    if session_token do
      case Auth.get_user_by_session_token(session_token) do
        {:ok, user} ->
          if user.status in ["banned", "deleted"] do
            {:cont, attach_page_metadata_hook(socket)}
          else
            {:halt, redirect(socket, to: "/")}
          end

        {:error, _} ->
          {:cont, attach_page_metadata_hook(socket)}
      end
    else
      {:cont, attach_page_metadata_hook(socket)}
    end
  end

  def on_mount(:rate_limit_mount, _params, _session, socket) do
    if connected?(socket) do
      ip = extract_peer_ip(socket)
      bucket = "liveview_mount:#{ip}"

      case BaudrateWeb.RateLimiter.check_rate(bucket, 60_000, 60) do
        {:deny, _} ->
          {:halt,
           socket
           |> put_flash(:error, gettext("Too many requests. Please try again later."))
           |> redirect(to: "/")}

        # {:allow, _} or {:error, _} — fail open
        _ ->
          {:cont, socket}
      end
    else
      {:cont, socket}
    end
  end

  # 10-minute timeout for admin TOTP re-verification (sudo mode)
  @admin_totp_timeout_seconds 600

  def on_mount(:require_admin_totp, _params, session, socket) do
    user = socket.assigns[:current_user]

    cond do
      # Non-admin users (e.g. moderators) pass through without TOTP
      # re-verification. This is deliberate and documented in CLAUDE.md and
      # in the router; a security audit flagged it, but widening it would
      # change how every moderator works, so it stays a decision for the
      # operator rather than a fix.
      is_nil(user) || user.role.name != "admin" ->
        {:cont, socket}

      # Admin without TOTP configured — redirect to profile to set it up
      !user.totp_enabled ->
        {:halt,
         socket
         |> put_flash(
           :error,
           gettext("TOTP must be configured before accessing admin pages.")
         )
         |> redirect(to: "/profile/security")}

      true ->
        verified_at = session["admin_totp_verified_at"]
        now = System.system_time(:second)

        if is_integer(verified_at) && now - verified_at < @admin_totp_timeout_seconds do
          # The mount-time check was the only one: `on_mount` never runs again,
          # so a socket opened inside the window kept accepting admin events
          # for as long as it stayed connected — hours after the ten minutes
          # expired. `ProfileSecurityLive` already guards its own unlock this way and
          # says why: events can be sent regardless of what is rendered.
          {:cont,
           socket
           |> assign(:admin_sudo_expires_at, verified_at + @admin_totp_timeout_seconds)
           |> attach_hook(:admin_sudo_deadline, :handle_event, &enforce_admin_sudo/3)}
        else
          return_to = admin_return_path(socket)

          {:halt,
           redirect(socket, to: "/admin/verify?return_to=#{URI.encode_www_form(return_to)}")}
        end
    end
  end

  def on_mount(:require_admin, _params, _session, socket) do
    if socket.assigns[:current_user] && socket.assigns.current_user.role.name == "admin" do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, gettext("Access denied."))
       |> redirect(to: "/")}
    end
  end

  def on_mount(:require_admin_or_moderator, _params, _session, socket) do
    if socket.assigns[:current_user] &&
         socket.assigns.current_user.role.name in ["admin", "moderator"] do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, gettext("Access denied."))
       |> redirect(to: "/")}
    end
  end

  # The path a page is on, and the URL it calls its own. Attached hooks run
  # before the LiveView's own `handle_params/3`, so a page can still override
  # either (an unlisted article assigns `:noindex`; ADR 0057).
  defp attach_page_metadata_hook(%{private: %{lifecycle: _}} = socket) do
    attach_hook(socket, :set_page_metadata, :handle_params, fn params, uri, socket ->
      path = URI.parse(uri).path

      {:cont,
       socket
       |> assign(:current_path, path)
       |> assign(:canonical_url, Crawlers.canonical_url(path, params))}
    end)
  end

  defp attach_page_metadata_hook(socket), do: socket

  # Applies the locale stored in the session by `BaudrateWeb.Plugs.SetLocale`
  # to the current LiveView process. Without this, anonymous LV mounts run
  # with the default Gettext locale ("en") and cause a visible locale flip
  # after the dead render.
  # A suspended account cannot sign in, and cannot keep a session it already
  # had. Checked by the clock, so it stops the moment the suspension ends
  # without any sweep having to run (ADR 0029).
  defp suspended?(user), do: Auth.suspended?(user)

  # Every hook that can render a page starts here, so this is also where the
  # viewer's time zone is cleared: a LiveView process is fresh, but a dead
  # render runs in a request process that may have served someone else.
  # `resolve_user_locale/1` sets it again once the member is known.
  defp apply_session_locale(session) do
    BaudrateWeb.TimeZone.put(nil)

    case session["locale"] do
      locale when is_binary(locale) ->
        Gettext.put_locale(locale)
        locale

      _ ->
        Gettext.get_locale()
    end
  end

  # A member's muted words, compiled for `BaudrateWeb.CoreComponents.muted_collapse/1`
  # (ADR 0073). Most members have none, and then nothing is compiled.
  defp muted_matchers(%{muted_keywords: [_ | _] = keywords}),
    do: Enum.map(keywords, &Baudrate.Moderation.PatternMatcher.compile/1)

  defp muted_matchers(_user), do: []

  defp resolve_user_locale(user) do
    BaudrateWeb.TimeZone.put(user.time_zone)

    case BaudrateWeb.Locale.resolve_from_preferences(user.preferred_locales) do
      nil ->
        Gettext.get_locale()

      locale ->
        Gettext.put_locale(locale)
        locale
    end
  end

  # Refuses an admin event once the sudo window has closed. Matched on
  # `is_integer` so a missing assign halts rather than passing: under Elixir's
  # term ordering a number sorts before every atom, so `deadline < nil` is
  # `true` and the bare comparison let every event through. The assign and
  # this hook are attached in one expression today, but a security check must
  # not depend on that staying true.
  defp enforce_admin_sudo(_event, _params, socket) do
    deadline = socket.assigns[:admin_sudo_expires_at]

    if is_integer(deadline) and System.system_time(:second) < deadline do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, gettext("Please verify your identity again to continue."))
       |> push_navigate(to: "/admin/verify")}
    end
  end

  # The admin page to come back to after sudo verification. `:uri` comes from
  # the conn on the HTTP render and from the socket's connect info once
  # A guest who asked for a private page is told why they are at `/login`, and
  # brought back afterwards. Before Phase 4D this was a bare redirect: no
  # flash, no memory, so the page they wanted was simply gone and the only
  # clue was that the URL had changed.
  #
  # The path travels as a query parameter because a LiveView cannot write the
  # session — the same shape admin sudo already uses. `LoginLive` carries it
  # into the sign-in POST, and `SessionController` sanitises it through
  # `Helpers.local_path/2`, the one open-redirect guard.
  # Reading the dismissal column first is what keeps this cheap: it is already
  # on the loaded user, and the two existence queries behind `arranged?/1` run
  # only for somebody who has neither dismissed the notice nor acted on it.
  defp recovery_pending?(%{recovery_notice_dismissed_at: nil} = user),
    do: not Auth.recovery_arranged?(user)

  defp recovery_pending?(_user), do: false

  defp to_login(socket) do
    socket = refusal_flash(socket)

    case return_path(socket) do
      nil -> redirect(socket, to: "/login")
      path -> redirect(socket, to: "/login?" <> URI.encode_query(%{"return_to" => path}))
    end
  end

  # The redirect is what matters; the message is the courtesy. A socket with
  # no flash (a bare `%Socket{}` in a unit test, or a lifecycle that has not
  # got that far) must not turn a refusal into a crash.
  defp refusal_flash(%{assigns: %{flash: _}} = socket),
    do: Phoenix.LiveView.put_flash(socket, :error, gettext("Please sign in to see that page."))

  defp refusal_flash(socket), do: socket

  defp return_path(socket) do
    case connect_uri(socket) do
      %URI{path: path, query: query} when is_binary(path) ->
        candidate = if query in [nil, ""], do: path, else: path <> "?" <> query
        if BaudrateWeb.Helpers.local_path(candidate, nil), do: candidate

      _ ->
        nil
    end
  end

  # `get_connect_info/2` raises outside `mount/3`. This hook runs at mount in
  # production, but remembering where somebody was going is a convenience and
  # refusing entry is the job: the convenience must never turn the refusal
  # into a crash.
  defp connect_uri(socket) do
    get_connect_info(socket, :uri)
  rescue
    RuntimeError -> nil
  end

  # connected (the page the socket was opened on). Anything outside `/admin/`
  # falls back to the settings page; `/admin/verify` re-sanitizes it anyway.
  defp admin_return_path(socket) do
    case get_connect_info(socket, :uri) do
      %URI{path: "/admin/" <> _ = path, query: query} when query in [nil, ""] -> path
      %URI{path: "/admin/" <> _ = path, query: query} -> path <> "?" <> query
      _ -> "/admin"
    end
  end
end
