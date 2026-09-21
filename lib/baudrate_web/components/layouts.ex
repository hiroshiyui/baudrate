defmodule BaudrateWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BaudrateWeb, :html
  import BaudrateWeb.Helpers, only: [translate_role: 1]

  alias Baudrate.Setup
  alias BaudrateWeb.Locale
  alias BaudrateWeb.PolicyLive

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout with navigation bar, footer, and mobile bottom nav.

  Applied automatically via `layout:` in `live_session`.
  Shows nav links and user menu when `@current_user` is present;
  otherwise shows only the logo and theme toggle.
  The footer links the policy documents an admin has published (`/terms`,
  `/rules`, `/privacy`); it renders nothing while all three are unwritten.

  On mobile (below `lg` breakpoint), a fixed bottom dock provides quick
  one-tap navigation: Home, Timeline, Search, Messages, Notifications for
  authenticated users; Home, Search, Sign In, Register for guests. The active
  item is highlighted based on `@current_path`.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the currently authenticated user"
  attr :inner_content, :any, default: nil, doc: "the inner content rendered by the layout"

  def app(assigns) do
    # Resolved once per render rather than twice in the footer markup. Reads
    # hit the settings ETS cache, so this costs nothing per page.
    assigns = assign_new(assigns, :published_policies, fn -> Setup.published_policies() end)

    ~H"""
    <header
      id="site-header"
      class="layout-header navbar sticky top-0 z-50 bg-base-200 border-b-2 border-base-300 px-4 sm:px-6 lg:px-8"
    >
      <%!-- Mobile hamburger (shown < lg, authenticated users only — guest nav is in bottom dock) --%>
      <div :if={@current_user} id="mobile-nav-trigger" class="nav-mobile-trigger flex-none lg:hidden">
        <div class="dropdown">
          <button
            id="nav-mobile-menu-button"
            type="button"
            tabindex="0"
            aria-label={gettext("Open navigation menu")}
            aria-haspopup="true"
            aria-expanded="false"
            class="nav-menu-button btn btn-ghost"
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <nav id="nav-mobile-menu" class="nav-mobile-menu" aria-label={gettext("Main menu")}>
            <ul
              tabindex="0"
              class="menu dropdown-content bg-base-100 rounded-box z-10 mt-3 w-52 p-2 shadow"
            >
              <%!-- Site name (visible only on mobile) --%>
              <li class="menu-title text-base site-name">
                {Baudrate.Setup.get_setting("site_name") || "Baudrate"}
              </li>
              <%!-- Admin section (collapsible, matches desktop user menu) --%>
              <li :if={@current_user && @current_user.role.name in ["admin", "moderator"]}>
                <hr />
              </li>
              <li :if={@current_user && @current_user.role.name in ["admin", "moderator"]}>
                <details id="nav-mobile-admin" class="nav-admin-section">
                  <summary>{gettext("Admin")}</summary>
                  <ul>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/settings" class="nav-admin-link">{gettext("Settings")}</.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/pending-users" class="nav-admin-link">
                        {gettext("Pending Users")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/federation" class="nav-admin-link">
                        {gettext("Federation")}
                      </.link>
                    </li>
                    <li>
                      <.link navigate="/admin/moderation" class="nav-admin-link">
                        {gettext("Moderation")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/boards" class="nav-admin-link">
                        {gettext("Manage Boards")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/users" class="nav-admin-link">
                        {gettext("Manage Users")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/moderation-log" class="nav-admin-link">
                        {gettext("Moderation Log")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/invites" class="nav-admin-link">
                        {gettext("Invite Codes")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/login-attempts" class="nav-admin-link">
                        {gettext("Login Attempts")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/data-exports" class="nav-admin-link">
                        {gettext("Data Exports")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/bots" class="nav-admin-link">{gettext("Manage Bots")}</.link>
                    </li>
                  </ul>
                </details>
              </li>
              <%!-- User section (matches desktop user menu) --%>
              <li :if={@current_user}>
                <hr />
              </li>
              <li :if={@current_user} class="menu-title flex flex-row items-center gap-2">
                <.avatar user={@current_user} size={36} decorative />
                <span class="truncate max-w-[10rem]">{display_name(@current_user)}</span>
                ({translate_role(@current_user.role.name)})
              </li>
              <li :if={@current_user}>
                <.link navigate="/profile" class="nav-user-link">{gettext("Profile")}</.link>
              </li>
              <li :if={@current_user}>
                <.link navigate="/bookmarks" class="nav-user-link">{gettext("Bookmarks")}</.link>
              </li>
              <li :if={@current_user}>
                <.link navigate="/following" class="nav-user-link">{gettext("Following")}</.link>
              </li>
              <li :if={@current_user}>
                <.link navigate="/invites" class="nav-user-link">{gettext("My Invites")}</.link>
              </li>
              <li :if={@current_user}>
                <.link href="/logout" method="delete" class="nav-user-link">{gettext("Sign Out")}</.link>
              </li>
            </ul>
          </nav>
        </div>
      </div>

      <%!-- Logo. A signed-in member's mobile site name lives in the hamburger
      menu, so the logo hides below `lg` for them. A guest has no hamburger —
      their mobile nav is the bottom dock, which carries icons and no name — so
      for a guest it stays visible at every width, or the site never says what
      it is called on a phone. --%>
      <div class={["flex-1", if(@current_user, do: "hidden lg:block", else: "block")]}>
        <.link navigate="/" id="nav-logo" class="nav-logo btn btn-ghost text-xl site-name">
          {Baudrate.Setup.get_setting("site_name") || "Baudrate"}
        </.link>
      </div>

      <%!-- Desktop nav links (shown >= lg) --%>
      <div :if={@current_user} id="desktop-nav" class="nav-desktop hidden lg:flex flex-none">
        <nav id="nav-desktop-menu" class="nav-desktop-menu" aria-label={gettext("Main menu")}>
          <ul class="menu menu-horizontal px-1 items-center">
            <li>
              <.link
                navigate="/"
                id="nav-home"
                class="nav-link btn btn-ghost"
                aria-current={if active_nav?(assigns[:current_path], "/"), do: "page"}
              >
                {gettext("Home")}
              </.link>
            </li>
            <li>
              <.link
                navigate="/timeline"
                id="nav-timeline"
                class="nav-link btn btn-ghost"
                aria-current={if active_nav?(assigns[:current_path], "/timeline"), do: "page"}
              >
                {gettext("Timeline")}
              </.link>
            </li>
            <li>
              <.link
                navigate="/search"
                id="nav-search"
                class="nav-link btn btn-ghost"
                aria-current={if active_nav?(assigns[:current_path], "/search"), do: "page"}
              >
                {gettext("Search")}
              </.link>
            </li>
            <li>
              <.link
                navigate="/messages"
                id="nav-messages"
                class="nav-link btn btn-ghost"
                aria-current={if active_nav?(assigns[:current_path], "/messages"), do: "page"}
              >
                {gettext("Messages")}
                <span
                  :if={assigns[:unread_dm_count] && @unread_dm_count > 0}
                  class="nav-unread-badge badge badge-primary badge-xs ml-1"
                  aria-hidden="true"
                >
                  {display_badge_count(@unread_dm_count)}
                </span>
                <span
                  :if={assigns[:unread_dm_count] && @unread_dm_count > 0}
                  class="nav-unread-count sr-only"
                >
                  {ngettext(
                    "%{count} unread message",
                    "%{count} unread messages",
                    @unread_dm_count,
                    count: @unread_dm_count
                  )}
                </span>
              </.link>
            </li>
            <li>
              <.link
                navigate="/notifications"
                id="nav-notifications"
                class="nav-link btn btn-ghost"
                aria-current={if active_nav?(assigns[:current_path], "/notifications"), do: "page"}
              >
                {gettext("Notifications")}
                <span
                  :if={assigns[:unread_notification_count] && @unread_notification_count > 0}
                  class="nav-unread-badge badge badge-secondary badge-xs ml-1"
                  aria-hidden="true"
                >
                  {display_badge_count(@unread_notification_count)}
                </span>
                <span
                  :if={assigns[:unread_notification_count] && @unread_notification_count > 0}
                  class="nav-unread-count sr-only"
                >
                  {ngettext(
                    "%{count} unread notification",
                    "%{count} unread notifications",
                    @unread_notification_count,
                    count: @unread_notification_count
                  )}
                </span>
              </.link>
            </li>
          </ul>
        </nav>
      </div>

      <%!-- Right side: theme toggle + auth links / user dropdown --%>
      <div
        id="header-controls"
        class="layout-header-controls flex-none flex items-center gap-2 ml-auto"
      >
        <.font_size_controls />
        <.theme_toggle />
        <.share_button url={assigns[:canonical_url]} title={assigns[:page_title]} />

        <%!-- Guest auth links (desktop only — mobile uses hamburger menu) --%>
        <div
          :if={!@current_user}
          id="guest-auth-links"
          class="nav-guest-links hidden lg:flex items-center gap-2"
        >
          <.link navigate="/search" id="nav-guest-search" class="nav-guest-link btn btn-ghost btn-sm">
            {gettext("Search")}
          </.link>
          <.link navigate="/login" id="nav-guest-login" class="nav-guest-link btn btn-ghost btn-sm">
            {gettext("Sign In")}
          </.link>
          <.link
            navigate="/register"
            id="nav-guest-register"
            class="nav-guest-link btn btn-primary btn-sm"
          >
            {gettext("Register")}
          </.link>
        </div>

        <%!-- Desktop user dropdown (shown >= lg) --%>
        <div
          :if={@current_user}
          id="user-menu-dropdown"
          class="nav-user-dropdown hidden lg:block dropdown dropdown-end"
        >
          <button
            id="nav-user-menu-button"
            type="button"
            tabindex="0"
            aria-haspopup="true"
            aria-expanded="false"
            class="nav-menu-button btn btn-ghost gap-2"
          >
            <.avatar user={@current_user} size={36} decorative />
            <span class="truncate max-w-[10rem]">{display_name(@current_user)}</span>
            <.icon name="hero-chevron-down-micro" class="size-4" />
          </button>
          <nav id="nav-user-menu" class="nav-user-menu" aria-label={gettext("User menu")}>
            <ul
              tabindex="0"
              class="menu dropdown-content bg-base-100 rounded-box z-10 mt-3 w-52 p-2 shadow"
            >
              <li :if={@current_user.role.name in ["admin", "moderator"]}>
                <details id="nav-admin" class="nav-admin-section">
                  <summary>{gettext("Admin")}</summary>
                  <ul>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/settings" class="nav-admin-link">{gettext("Settings")}</.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/pending-users" class="nav-admin-link">
                        {gettext("Pending Users")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/federation" class="nav-admin-link">
                        {gettext("Federation")}
                      </.link>
                    </li>
                    <li>
                      <.link navigate="/admin/moderation" class="nav-admin-link">
                        {gettext("Moderation")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/boards" class="nav-admin-link">
                        {gettext("Manage Boards")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/users" class="nav-admin-link">
                        {gettext("Manage Users")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/moderation-log" class="nav-admin-link">
                        {gettext("Moderation Log")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/invites" class="nav-admin-link">
                        {gettext("Invite Codes")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/login-attempts" class="nav-admin-link">
                        {gettext("Login Attempts")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/data-exports" class="nav-admin-link">
                        {gettext("Data Exports")}
                      </.link>
                    </li>
                    <li :if={@current_user.role.name == "admin"}>
                      <.link navigate="/admin/bots" class="nav-admin-link">{gettext("Manage Bots")}</.link>
                    </li>
                  </ul>
                </details>
              </li>
              <li :if={@current_user.role.name in ["admin", "moderator"]}>
                <hr />
              </li>
              <li>
                <.link navigate="/profile" class="nav-user-link">{gettext("Profile")}</.link>
              </li>
              <li>
                <.link navigate="/bookmarks" class="nav-user-link">{gettext("Bookmarks")}</.link>
              </li>
              <li>
                <.link navigate="/following" class="nav-user-link">{gettext("Following")}</.link>
              </li>
              <li>
                <.link navigate="/invites" class="nav-user-link">{gettext("My Invites")}</.link>
              </li>
              <li>
                <.link href="/logout" method="delete" class="nav-user-link">{gettext("Sign Out")}</.link>
              </li>
            </ul>
          </nav>
        </div>
      </div>
    </header>

    <main
      id="main-content"
      tabindex="-1"
      class="layout-main flex-1 px-4 pt-6 pb-24 lg:pt-10 lg:pb-20 sm:px-6 lg:px-8 outline-none"
    >
      <div class={["mx-auto space-y-4", if(assigns[:wide_layout], do: "max-w-7xl", else: "max-w-6xl")]}>
        <.data_export_notice :if={assigns[:active_data_export]} request={@active_data_export} />
        <.account_move_notice :if={assigns[:active_account_move]} summary={@active_account_move} />
        <.account_moved_notice :if={assigns[:current_user] && @current_user.moved_to} />
        <.sanction_notice :if={assigns[:active_sanction]} sanction={@active_sanction} />
        <.terms_notice :if={assigns[:terms_pending]} />
        <.recovery_notice :if={assigns[:recovery_pending]} />
        {@inner_content}
      </div>
    </main>

    <%!-- Below `lg` the dock is fixed over the bottom of the viewport, so the
    footer needs its own clearance: `main`'s padding does not cover a sibling. --%>
    <footer id="site-footer" class="layout-footer pt-6 pb-24 lg:pb-6">
      <nav
        :if={@published_policies != []}
        id="site-footer-policies"
        aria-label={gettext("Site policies")}
        class="site-footer-policies mx-auto max-w-6xl px-4 sm:px-6 lg:px-8"
      >
        <ul class="site-footer-policy-list flex flex-wrap justify-center gap-x-6 gap-y-2 text-sm opacity-70">
          <li :for={name <- @published_policies} class="site-footer-policy-item">
            <.link
              id={"site-footer-#{name}"}
              navigate={policy_path(name)}
              class="site-footer-policy-link link link-hover"
            >
              {PolicyLive.title(name)}
            </.link>
          </li>
        </ul>
      </nav>

      <%!-- The feeds have existed since v1.x and nothing linked them, so the
      only way to find one was to know the path. Site-wide here; board and user
      feeds are advertised on their own pages. --%>
      <nav
        id="site-footer-feeds"
        aria-label={gettext("Syndication feeds")}
        class="site-footer-feeds mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 mt-4"
      >
        <ul class="site-footer-feed-list flex flex-wrap justify-center gap-x-6 gap-y-2 text-sm opacity-70">
          <li class="site-footer-feed-item">
            <.link
              id="site-footer-feed-rss"
              href={~p"/feeds/rss"}
              class="site-footer-feed-link link link-hover"
            >
              {gettext("RSS")}
            </.link>
          </li>
          <li class="site-footer-feed-item">
            <.link
              id="site-footer-feed-atom"
              href={~p"/feeds/atom"}
              class="site-footer-feed-link link link-hover"
            >
              {gettext("Atom")}
            </.link>
          </li>
        </ul>
      </nav>

      <.language_switcher current_locale={assigns[:locale]} current_path={assigns[:current_path]} />
    </footer>

    <.mobile_bottom_nav
      current_user={@current_user}
      current_path={assigns[:current_path]}
      unread_dm_count={assigns[:unread_dm_count] || 0}
      unread_notification_count={assigns[:unread_notification_count] || 0}
    />

    <.flash_group flash={@flash} />

    <button
      id="scroll-to-top-btn"
      aria-label={gettext("Scroll to top")}
      class="layout-scroll-top fixed bottom-20 right-4 lg:bottom-10 lg:right-10 z-40 btn btn-circle btn-primary size-14 shadow-2xl"
    >
      <.icon name="hero-arrow-up-solid" class="size-6" />
    </button>
    """
  end

  @doc """
  Warning shown on every page while the current user has a pending or ready
  data export request (ADR 0023). It cannot be dismissed and names the
  requesting browser family, so a user whose account was compromised notices
  the request during the 24-hour wait and can cancel it.
  """
  attr :request, :map, required: true

  def data_export_notice(assigns) do
    ~H"""
    <aside
      id="data-export-notice"
      class="data-export-notice alert alert-warning"
      aria-labelledby="data-export-notice-heading"
    >
      <.icon name="hero-shield-exclamation" class="size-5 shrink-0" />
      <div class="min-w-0 space-y-1">
        <h2 id="data-export-notice-heading" class="data-export-notice-heading font-semibold">
          {gettext("A data export of your account is in progress")}
        </h2>
        <p id="data-export-notice-text" class="data-export-notice-text text-sm break-words">
          <%= if @request.requested_user_agent_family do %>
            {gettext("Requested %{time} from %{browser}. If this was not you, cancel it now.",
              time: format_datetime(@request.requested_at),
              browser: @request.requested_user_agent_family
            )}
          <% else %>
            {gettext("Requested %{time}. If this was not you, cancel it now.",
              time: format_datetime(@request.requested_at)
            )}
          <% end %>
        </p>
      </div>
      <.link
        id="data-export-notice-link"
        navigate={~p"/profile/export"}
        class="data-export-notice-link btn btn-sm"
      >
        {gettext("Review")}
      </.link>
    </aside>
    """
  end

  @doc """
  Warning shown on every page while a move of the user's account is pending
  (ADR 0025).

  It cannot be dismissed. It names the destination, the requesting browser
  family and when the `Move` will be sent, so a user whose account was taken
  over notices during the 24-hour wait and can cancel it.
  """
  attr :summary, :map, required: true

  def account_move_notice(assigns) do
    ~H"""
    <aside
      id="account-move-notice"
      class="account-move-notice alert alert-warning"
      aria-labelledby="account-move-notice-heading"
    >
      <.icon name="hero-shield-exclamation" class="size-5 shrink-0" />
      <div class="min-w-0 space-y-1">
        <h2 id="account-move-notice-heading" class="account-move-notice-heading font-semibold">
          {gettext("Your account is about to move to %{account}", account: @summary.label)}
        </h2>
        <p id="account-move-notice-text" class="account-move-notice-text text-sm break-words">
          <%= if @summary.move.requested_user_agent_family do %>
            {gettext(
              "Requested %{time} from %{browser}. Your followers will be moved after %{send_time}. If this was not you, cancel it now.",
              time: format_datetime(@summary.move.requested_at),
              browser: @summary.move.requested_user_agent_family,
              send_time: format_datetime(@summary.move.send_after)
            )}
          <% else %>
            {gettext(
              "Requested %{time}. Your followers will be moved after %{send_time}. If this was not you, cancel it now.",
              time: format_datetime(@summary.move.requested_at),
              send_time: format_datetime(@summary.move.send_after)
            )}
          <% end %>
        </p>
      </div>
      <.link
        id="account-move-notice-link"
        navigate={~p"/profile/move"}
        class="account-move-notice-link btn btn-sm"
      >
        {gettext("Review")}
      </.link>
    </aside>
    """
  end

  @doc """
  Notice on every page while published terms are waiting to be accepted
  (P1-D8).

  It does not block reading, and it is not dismissible: the member is not
  being punished, only asked, and the gate refuses posting until they answer.
  The button leads to `/terms`, where accepting happens — a one-click "accept"
  on the banner itself would let someone agree to a document without the page
  ever showing it to them.
  """
  def terms_notice(assigns) do
    ~H"""
    <aside
      id="terms-notice"
      class="terms-notice alert alert-warning"
      aria-labelledby="terms-notice-heading"
    >
      <.icon name="hero-document-text" class="size-5 shrink-0" />
      <div class="min-w-0 space-y-1">
        <h2 id="terms-notice-heading" class="terms-notice-heading font-semibold">
          {gettext("The terms of service have changed")}
        </h2>
        <p id="terms-notice-text" class="terms-notice-text text-sm break-words">
          {gettext("You can keep reading, but posting is paused until you accept them.")}
        </p>
      </div>
      <.link id="terms-notice-link" navigate={~p"/terms"} class="terms-notice-link btn btn-sm">
        {gettext("Review")}
      </.link>
    </aside>
    """
  end

  @doc """
  Notice for an account that cannot currently be recovered: no unused recovery
  codes and no verified recovery contact (ADR 0058).

  This site sends no email, so an account in that state has no way back if its
  password is lost — which makes this safety work, and decision 5 of ADR 0056
  is explicit that "boring" is never an argument against that. It stays inside
  0056's other rules all the same: no count, no badge, no colour that shouts,
  and dismissing it is final. It is named `-notice` like its siblings, because
  a name containing `banner` is one a content blocker hides.
  """
  def recovery_notice(assigns) do
    ~H"""
    <aside
      id="recovery-notice"
      class="recovery-notice alert"
      aria-labelledby="recovery-notice-heading"
    >
      <.icon name="hero-key" class="size-5 shrink-0" />
      <div class="min-w-0 space-y-1">
        <h2 id="recovery-notice-heading" class="recovery-notice-heading font-semibold">
          {gettext("You have no way back into this account")}
        </h2>
        <p id="recovery-notice-text" class="recovery-notice-text text-sm break-words">
          {gettext(
            "Your recovery codes are used up and no recovery contact is verified. This site sends no email, so if you lose your password there is nothing we can do."
          )}
        </p>
      </div>
      <div class="recovery-notice-actions flex gap-2">
        <.link
          id="recovery-notice-link"
          navigate={~p"/profile"}
          class="recovery-notice-link btn btn-sm"
        >
          {gettext("Set it up")}
        </.link>
        <button
          type="button"
          id="recovery-notice-dismiss"
          phx-click="dismiss_recovery_notice"
          class="recovery-notice-dismiss btn btn-sm btn-ghost"
        >
          {gettext("Not now")}
        </button>
      </div>
    </aside>
    """
  end

  @doc """
  Notice on every page for the owner of a moved account: it is read-only, and
  the redirect can be removed on `/profile/move` (ADR 0025).
  """
  def account_moved_notice(assigns) do
    ~H"""
    <aside
      id="account-moved-notice"
      class="account-moved-notice alert alert-info"
      aria-labelledby="account-moved-notice-text"
    >
      <.icon name="hero-truck" class="size-5 shrink-0" />
      <p id="account-moved-notice-text" class="account-moved-notice-text min-w-0 text-sm">
        {gettext(
          "Your account has moved and is read-only. You can still read, export your data and manage your account."
        )}
      </p>
      <.link
        id="account-moved-notice-link"
        navigate={~p"/profile/move"}
        class="account-moved-notice-link btn btn-sm"
      >
        {gettext("Review")}
      </.link>
    </aside>
    """
  end

  @doc """
  Notice on every page for a member under an active restriction (ADR 0029).

  A silenced member finds the composer simply gone, and a control that
  vanishes explains nothing. The notice says which restriction stands, the
  staff-written reason, and when it ends — the same thing the always-delivered
  notification said, where they will actually be looking.
  """
  attr :sanction, :map, required: true

  def sanction_notice(assigns) do
    ~H"""
    <aside
      id="sanction-notice"
      class="sanction-notice alert alert-warning"
      aria-labelledby="sanction-notice-text"
    >
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <p id="sanction-notice-text" class="sanction-notice-text min-w-0 text-sm break-words">
        <span class="sanction-notice-kind font-semibold">
          <%= if @sanction.kind == "suspend" do %>
            {gettext("Your account is suspended.")}
          <% else %>
            {gettext("Your account is silenced and cannot post.")}
          <% end %>
        </span>
        <span :if={@sanction.reason} class="sanction-notice-reason">
          {gettext("Reason: %{reason}", reason: @sanction.reason)}
        </span>
        <span :if={@sanction.expires_at} class="sanction-notice-until">
          {gettext("It ends %{at}.", at: BaudrateWeb.Helpers.format_datetime(@sanction.expires_at))}
        </span>
      </p>
    </aside>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="flash-group">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a minimal setup layout without navigation.
  """
  def setup(assigns) do
    ~H"""
    <main id="main-content" tabindex="-1" class="layout-main px-4 py-10 sm:px-6 lg:px-8 outline-none">
      <div class="mx-auto max-w-2xl space-y-4">
        {@inner_content}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders font size zoom in/out controls.

  Dispatches `phx:font-size-decrease` and `phx:font-size-increase` events
  handled by JS in `app.js`, which persists the zoom level in localStorage.
  """
  def font_size_controls(assigns) do
    ~H"""
    <div
      id="font-size-controls"
      role="group"
      aria-label={gettext("Font size")}
      class="toolbar-font-size card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
    >
      <button
        id="font-size-decrease"
        class="toolbar-font-size-button flex p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:font-size-decrease")}
        aria-label={gettext("Decrease font size")}
      >
        <.icon name="hero-minus-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        id="font-size-increase"
        class="toolbar-font-size-button flex p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:font-size-increase")}
        aria-label={gettext("Increase font size")}
      >
        <.icon name="hero-plus-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  @doc """
  Renders a button that hands the current page on.

  On a phone or an installed PWA it opens the OS share sheet through
  `navigator.share`. On a desktop browser, where that does not exist, it
  copies the link and says so — it used to hide itself there, which left the
  site with no sharing affordance at all on the machines most writing happens
  on. `WebShareHook` decides which, and relabels the button when it will be
  the copy.

  It is rendered hidden and revealed by the hook, because a button that can do
  nothing without JavaScript should not be visible without it. The server
  cannot know which of the two capabilities the browser has, so it cannot
  render the right label either; both are passed as translated `data-*`
  attributes for the hook to choose between.

  Pages pass `url` and `title` when the thing worth sharing is not the address
  bar — an article's canonical URL rather than whatever query string the
  reader arrived with.
  """
  attr :url, :string, default: nil, doc: "canonical URL to share; defaults to location.href"
  attr :title, :string, default: nil, doc: "title to share; defaults to document.title"

  def share_button(assigns) do
    ~H"""
    <button
      id="web-share-button"
      type="button"
      phx-hook="WebShareHook"
      hidden
      class="toolbar-share-button hidden btn btn-ghost btn-circle btn-sm"
      aria-label={gettext("Share this page")}
      title={gettext("Share this page")}
      data-share-url={@url}
      data-share-title={@title}
      data-copy-label={gettext("Copy a link to this page")}
      data-copied-label={gettext("Link copied")}
    >
      <.icon name="hero-share" class="size-5" />
    </button>
    """
  end

  @doc """
  Renders the footer language switcher.

  **A `<details>` holding a plain form**, and both halves are deliberate.

  `<details>` is the one disclosure widget the browser implements itself: it
  opens, closes and takes the keyboard with no JavaScript and no `aria-*`
  bookkeeping of ours to get wrong. `dropdown-top` opens it upward, which in a
  footer is also what keeps it clear of the mobile dock — see
  `features/layout_test.exs`, which fails when a dropdown item is not the
  topmost element at its own centre.

  The form posts to `BaudrateWeb.LocaleController` rather than sending a
  LiveView event, because writing the cookie and the session is a controller's
  job here — and because a language control has to keep working when scripting
  has gone wrong, the same judgement that makes a content warning a `<details>`
  rather than a hook (ADR 0052). Nothing in this component needs JavaScript,
  and nothing in it should come to need it.

  The names avoid every word a cosmetic-filter list targets (`banner`,
  `consent`, `cookie`, `popup`, `promo`…). A hidden language switcher is a dead
  end for precisely the readers who came looking for one — the `#policy-accept`
  lesson in `CLAUDE.md`.

  `current_path` comes from `AuthHooks.attach_current_path_hook/1` and carries
  no query string. `LocaleController` puts one back from the `referer` when it
  agrees with this path, so a search or a page number survives the switch.
  """
  attr :current_locale, :string, default: nil
  attr :current_path, :string, default: nil

  def language_switcher(assigns) do
    ~H"""
    <div class="site-footer-languages mt-4 flex justify-center">
      <details id="locale-switcher" class="locale-switcher dropdown dropdown-top dropdown-end">
        <summary id="locale-switcher-summary" class="locale-switcher-summary btn btn-ghost btn-sm">
          <.icon name="hero-language" class="size-4" />
          <%!-- Read out as "Site language, English": a lone language name is
          not a control anyone can identify, and the visible text stays inside
          the accessible name, which `aria-label` alone would not manage. --%>
          <span class="locale-switcher-label sr-only">{gettext("Site language")}</span>
          <span class="locale-switcher-current" lang={locale_tag(@current_locale || "en")}>
            {Locale.locale_display_name(@current_locale || "en")}
          </span>
        </summary>
        <form
          id="locale-switcher-form"
          method="post"
          action={~p"/locale"}
          class="locale-switcher-form"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="return_to" value={@current_path || "/"} />
          <ul class="locale-switcher-list menu dropdown-content bg-base-100 rounded-box z-10 mb-2 w-56 p-2 shadow">
            <li class="locale-switcher-heading menu-title">{gettext("Site language")}</li>
            <li :for={{code, name} <- Locale.available_locales()} class="locale-switcher-item">
              <button
                id={"locale-option-#{code}"}
                type="submit"
                name="locale"
                value={code}
                lang={locale_tag(code)}
                class={[
                  "locale-option",
                  if(code == @current_locale, do: "locale-option-current")
                ]}
                aria-current={if code == @current_locale, do: "true"}
              >
                {name}
              </button>
            </li>
            <li class="locale-switcher-item">
              <button
                id="locale-option-auto"
                type="submit"
                name="locale"
                value={Locale.auto()}
                class="locale-option locale-option-auto opacity-70"
              >
                {gettext("Match my browser")}
              </button>
            </li>
          </ul>
        </form>
      </details>
    </div>
    """
  end

  # `zh_TW` is a Gettext locale name; `zh-TW` is what BCP 47 (and therefore
  # `lang=`) wants. The root layout does the same to the document element.
  defp locale_tag(code), do: String.replace(code, "_", "-")

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      role="group"
      aria-label={gettext("Theme")}
      class="toolbar-theme card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
    >
      <div class="theme-toggle-indicator absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme-pref=light]_&]:left-1/3 [[data-theme-pref=dark]_&]:left-2/3 transition-[left]" />

      <button
        id="theme-toggle-system"
        class="theme-option flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-pressed="false"
        aria-label={gettext("System theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        id="theme-toggle-light"
        class="theme-option flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-pressed="false"
        aria-label={gettext("Light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        id="theme-toggle-dark"
        class="theme-option flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-pressed="false"
        aria-label={gettext("Dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  attr :current_user, :map, default: nil
  attr :current_path, :string, default: nil
  attr :unread_dm_count, :integer, default: 0
  attr :unread_notification_count, :integer, default: 0

  defp mobile_bottom_nav(assigns) do
    ~H"""
    <nav
      id="mobile-bottom-nav"
      aria-label={gettext("Mobile navigation")}
      class="dock lg:hidden z-50 bg-base-200 border-t-2 border-base-300 pb-[env(safe-area-inset-bottom)]"
    >
      <%= if @current_user do %>
        <.link
          navigate="/"
          id="dock-home"
          aria-label={gettext("Home")}
          aria-current={if active_nav?(@current_path, "/"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/"), do: "dock-active")]}
        >
          <.icon name="hero-home" class="size-[1.2em]" />
        </.link>
        <.link
          navigate="/timeline"
          id="dock-timeline"
          aria-label={gettext("Timeline")}
          aria-current={if active_nav?(@current_path, "/timeline"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/timeline"), do: "dock-active")]}
        >
          <.icon name="hero-rss" class="size-[1.2em]" />
        </.link>
        <.link
          navigate="/search"
          id="dock-search"
          aria-label={gettext("Search")}
          aria-current={if active_nav?(@current_path, "/search"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/search"), do: "dock-active")]}
        >
          <.icon name="hero-magnifying-glass" class="size-[1.2em]" />
        </.link>
        <.link
          navigate="/messages"
          id="dock-messages"
          aria-label={
            if @unread_dm_count > 0,
              do:
                ngettext(
                  "Messages, %{count} unread",
                  "Messages, %{count} unread",
                  @unread_dm_count,
                  count: @unread_dm_count
                ),
              else: gettext("Messages")
          }
          aria-current={if active_nav?(@current_path, "/messages"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/messages"), do: "dock-active")]}
        >
          <span class="indicator">
            <span
              :if={@unread_dm_count > 0}
              class="dock-unread-badge indicator-item badge badge-primary badge-xs"
              aria-hidden="true"
            >
              {display_badge_count(@unread_dm_count)}
            </span>
            <.icon name="hero-chat-bubble-left-right" class="size-[1.2em]" />
          </span>
        </.link>
        <.link
          navigate="/notifications"
          id="dock-notifications"
          aria-label={
            if @unread_notification_count > 0,
              do:
                ngettext(
                  "Notifications, %{count} unread",
                  "Notifications, %{count} unread",
                  @unread_notification_count,
                  count: @unread_notification_count
                ),
              else: gettext("Notifications")
          }
          aria-current={if active_nav?(@current_path, "/notifications"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/notifications"), do: "dock-active")]}
        >
          <span class="indicator">
            <span
              :if={@unread_notification_count > 0}
              class="dock-unread-badge indicator-item badge badge-secondary badge-xs"
              aria-hidden="true"
            >
              {display_badge_count(@unread_notification_count)}
            </span>
            <.icon name="hero-bell" class="size-[1.2em]" />
          </span>
        </.link>
      <% else %>
        <.link
          navigate="/"
          id="dock-home"
          aria-label={gettext("Home")}
          aria-current={if active_nav?(@current_path, "/"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/"), do: "dock-active")]}
        >
          <.icon name="hero-home" class="size-[1.2em]" />
        </.link>
        <.link
          navigate="/search"
          id="dock-search"
          aria-label={gettext("Search")}
          aria-current={if active_nav?(@current_path, "/search"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/search"), do: "dock-active")]}
        >
          <.icon name="hero-magnifying-glass" class="size-[1.2em]" />
        </.link>
        <.link
          navigate="/login"
          id="dock-login"
          aria-label={gettext("Sign In")}
          aria-current={if active_nav?(@current_path, "/login"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/login"), do: "dock-active")]}
        >
          <.icon name="hero-arrow-right-on-rectangle" class="size-[1.2em]" />
        </.link>
        <.link
          navigate="/register"
          id="dock-register"
          aria-label={gettext("Register")}
          aria-current={if active_nav?(@current_path, "/register"), do: "page"}
          class={["dock-link", if(active_nav?(@current_path, "/register"), do: "dock-active")]}
        >
          <.icon name="hero-user-plus" class="size-[1.2em]" />
        </.link>
      <% end %>
    </nav>
    """
  end

  # Caps a badge count at 99+ so narrow phone screens and header chips
  # don't have the number overflow the badge pill.
  defp display_badge_count(count) when is_integer(count) and count > 99, do: "99+"
  defp display_badge_count(count), do: count

  defp active_nav?(current_path, "/"), do: current_path == "/"

  defp active_nav?(current_path, target) when is_binary(current_path) do
    String.starts_with?(current_path, target)
  end

  defp active_nav?(_, _), do: false

  # Each policy document has its own literal route, so `Setup.policy_names/0`
  # maps to a path here rather than being interpolated into one.
  defp policy_path(:terms), do: ~p"/terms"
  defp policy_path(:rules), do: ~p"/rules"
  defp policy_path(:privacy), do: ~p"/privacy"
end
