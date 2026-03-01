defmodule BaudrateWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BaudrateWeb, :html
  import BaudrateWeb.Helpers, only: [translate_role: 1]

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout with navigation bar and footer.

  Applied automatically via `layout:` in `live_session`.
  Shows nav links and user menu when `@current_user` is present;
  otherwise shows only the logo and theme toggle.
  The footer displays a link to the Baudrate project repository.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the currently authenticated user"
  attr :inner_content, :any, default: nil, doc: "the inner content rendered by the layout"

  def app(assigns) do
    ~H"""
    <header
      id="site-header"
      class="navbar sticky top-0 z-50 bg-base-200 border-b border-base-300 px-4 sm:px-6 lg:px-8"
    >
      <%!-- Mobile hamburger (shown < lg) --%>
      <div :if={@current_user} id="mobile-nav-trigger" class="flex-none lg:hidden">
        <div class="dropdown">
          <button
            type="button"
            tabindex="0"
            aria-label={gettext("Open navigation menu")}
            aria-haspopup="true"
            class="btn btn-ghost"
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <nav aria-label={gettext("Main menu")}>
            <ul
              tabindex="0"
              class="menu dropdown-content bg-base-100 rounded-box z-10 mt-3 w-52 p-2 shadow"
            >
              <%!-- Main nav (matches desktop nav) --%>
              <li>
                <.link navigate="/">{gettext("Home")}</.link>
              </li>
              <li>
                <.link navigate="/feed">{gettext("Feed")}</.link>
              </li>
              <li>
                <.link navigate="/search">{gettext("Search")}</.link>
              </li>
              <li>
                <.link navigate="/messages">
                  {gettext("Messages")}
                  <span
                    :if={assigns[:unread_dm_count] && @unread_dm_count > 0}
                    class="badge badge-primary badge-xs ml-1"
                    aria-label={
                      ngettext(
                        "%{count} unread message",
                        "%{count} unread messages",
                        @unread_dm_count,
                        count: @unread_dm_count
                      )
                    }
                  >
                    {@unread_dm_count}
                  </span>
                </.link>
              </li>
              <li>
                <.link navigate="/notifications">
                  {gettext("Notifications")}
                  <span
                    :if={assigns[:unread_notification_count] && @unread_notification_count > 0}
                    class="badge badge-secondary badge-xs ml-1"
                    aria-label={
                      ngettext(
                        "%{count} unread notification",
                        "%{count} unread notifications",
                        @unread_notification_count,
                        count: @unread_notification_count
                      )
                    }
                  >
                    {@unread_notification_count}
                  </span>
                </.link>
              </li>
              <%!-- Admin section (matches desktop user menu) --%>
              <li :if={@current_user.role.name == "admin"} class="divider my-1"></li>
              <li :if={@current_user.role.name == "admin"} class="menu-title">
                {gettext("Admin")}
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/settings">{gettext("Settings")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/pending-users">{gettext("Pending Users")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/federation">{gettext("Federation")}</.link>
              </li>
              <li :if={@current_user.role.name in ["admin", "moderator"]}>
                <.link navigate="/admin/moderation">{gettext("Moderation")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/boards">{gettext("Manage Boards")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/users">{gettext("Manage Users")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/moderation-log">{gettext("Moderation Log")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/invites">{gettext("Invite Codes")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/login-attempts">{gettext("Login Attempts")}</.link>
              </li>
              <%!-- User section (matches desktop user menu) --%>
              <li class="divider my-1"></li>
              <li class="menu-title flex flex-row items-center gap-2">
                <.avatar user={@current_user} size={36} />
                <span class="truncate max-w-[10rem]">{display_name(@current_user)}</span>
                ({translate_role(@current_user.role.name)})
              </li>
              <li>
                <.link navigate="/profile">{gettext("Profile")}</.link>
              </li>
              <li>
                <.link navigate="/bookmarks">{gettext("Bookmarks")}</.link>
              </li>
              <li>
                <.link navigate="/following">{gettext("Following")}</.link>
              </li>
              <li>
                <.link navigate="/invites">{gettext("My Invites")}</.link>
              </li>
              <li>
                <.link href="/logout" method="delete">{gettext("Sign Out")}</.link>
              </li>
            </ul>
          </nav>
        </div>
      </div>

      <%!-- Logo --%>
      <div class="flex-1">
        <.link navigate="/" class="btn btn-ghost text-xl">Baudrate</.link>
      </div>

      <%!-- Desktop nav links (shown >= lg) --%>
      <div :if={@current_user} id="desktop-nav" class="hidden lg:flex flex-none">
        <nav aria-label={gettext("Main menu")}>
          <ul class="menu menu-horizontal px-1 items-center">
            <li>
              <.link navigate="/" class="btn btn-ghost">{gettext("Home")}</.link>
            </li>
            <li>
              <.link navigate="/feed" class="btn btn-ghost">
                {gettext("Feed")}
              </.link>
            </li>
            <li>
              <.link navigate="/search" class="btn btn-ghost">{gettext("Search")}</.link>
            </li>
            <li>
              <.link navigate="/messages" class="btn btn-ghost">
                {gettext("Messages")}
                <span
                  :if={assigns[:unread_dm_count] && @unread_dm_count > 0}
                  class="badge badge-primary badge-xs ml-1"
                  aria-label={
                    ngettext(
                      "%{count} unread message",
                      "%{count} unread messages",
                      @unread_dm_count,
                      count: @unread_dm_count
                    )
                  }
                >
                  {@unread_dm_count}
                </span>
              </.link>
            </li>
            <li>
              <.link navigate="/notifications" class="btn btn-ghost">
                {gettext("Notifications")}
                <span
                  :if={assigns[:unread_notification_count] && @unread_notification_count > 0}
                  class="badge badge-secondary badge-xs ml-1"
                  aria-label={
                    ngettext(
                      "%{count} unread notification",
                      "%{count} unread notifications",
                      @unread_notification_count,
                      count: @unread_notification_count
                    )
                  }
                >
                  {@unread_notification_count}
                </span>
              </.link>
            </li>
          </ul>
        </nav>
      </div>

      <%!-- Right side: theme toggle + auth links / user dropdown --%>
      <div id="header-controls" class="flex-none flex items-center gap-2">
        <.font_size_controls />
        <.theme_toggle />

        <%!-- Guest auth links (shown when not logged in) --%>
        <div :if={!@current_user} id="guest-auth-links" class="flex items-center gap-2">
          <.link navigate="/search" class="btn btn-ghost btn-sm">{gettext("Search")}</.link>
          <.link navigate="/login" class="btn btn-ghost btn-sm">{gettext("Sign In")}</.link>
          <.link navigate="/register" class="btn btn-primary btn-sm">{gettext("Register")}</.link>
        </div>

        <%!-- Desktop user dropdown (shown >= lg) --%>
        <div :if={@current_user} id="user-menu-dropdown" class="hidden lg:block dropdown dropdown-end">
          <button
            type="button"
            tabindex="0"
            aria-haspopup="true"
            class="btn btn-ghost gap-2"
          >
            <.avatar user={@current_user} size={36} />
            <span class="truncate max-w-[10rem]">{display_name(@current_user)}</span>
            <.icon name="hero-chevron-down-micro" class="size-4" />
          </button>
          <nav aria-label={gettext("User menu")}>
            <ul
              tabindex="0"
              class="menu dropdown-content bg-base-100 rounded-box z-10 mt-3 w-52 p-2 shadow"
            >
              <li :if={@current_user.role.name == "admin"} class="menu-title">
                {gettext("Admin")}
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/settings">{gettext("Settings")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/pending-users">{gettext("Pending Users")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/federation">{gettext("Federation")}</.link>
              </li>
              <li :if={@current_user.role.name in ["admin", "moderator"]}>
                <.link navigate="/admin/moderation">{gettext("Moderation")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/boards">{gettext("Manage Boards")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/users">{gettext("Manage Users")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/moderation-log">{gettext("Moderation Log")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/invites">{gettext("Invite Codes")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"}>
                <.link navigate="/admin/login-attempts">{gettext("Login Attempts")}</.link>
              </li>
              <li :if={@current_user.role.name == "admin"} class="divider my-1"></li>
              <li>
                <.link navigate="/profile">{gettext("Profile")}</.link>
              </li>
              <li>
                <.link navigate="/bookmarks">{gettext("Bookmarks")}</.link>
              </li>
              <li>
                <.link navigate="/following">{gettext("Following")}</.link>
              </li>
              <li>
                <.link navigate="/invites">{gettext("My Invites")}</.link>
              </li>
              <li>
                <.link href="/logout" method="delete">{gettext("Sign Out")}</.link>
              </li>
            </ul>
          </nav>
        </div>
      </div>
    </header>

    <main id="main-content" tabindex="-1" class="flex-1 px-4 py-20 sm:px-6 lg:px-8 outline-none">
      <div class={["mx-auto space-y-4", if(assigns[:wide_layout], do: "max-w-7xl", else: "max-w-6xl")]}>
        {@inner_content}
      </div>
    </main>

    <footer id="site-footer" class="text-center text-sm text-base-content/70 py-6">
      <p>
        {raw(
          gettext("Of course it runs %{link}! Your public information hub!",
            link:
              ~s(<a href="https://github.com/hiroshiyui/baudrate" class="link link-hover" target="_blank" rel="noopener noreferrer">Baudrate</a>)
          )
        )}
      </p>
      <p class="mt-1">
        {gettext("System timezone: %{timezone}", timezone: system_timezone())}
      </p>
    </footer>

    <.flash_group flash={@flash} />
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
    <div id={@id} aria-live="polite" aria-atomic="true">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
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
    <main id="main-content" tabindex="-1" class="px-4 py-10 sm:px-6 lg:px-8 outline-none">
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
      role="group"
      aria-label={gettext("Font size")}
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
    >
      <button
        class="flex p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:font-size-decrease")}
        aria-label={gettext("Decrease font size")}
      >
        <.icon name="hero-minus-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:font-size-increase")}
        aria-label={gettext("Increase font size")}
      >
        <.icon name="hero-plus-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      role="group"
      aria-label={gettext("Theme")}
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
    >
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("System theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  defp system_timezone do
    tz = Baudrate.Setup.get_setting("timezone") || "Etc/UTC"

    offset =
      case DateTime.now(tz) do
        {:ok, dt} ->
          total_seconds = dt.utc_offset + dt.std_offset
          sign = if total_seconds >= 0, do: "+", else: "-"
          abs_seconds = abs(total_seconds)
          hours = div(abs_seconds, 3600)
          minutes = div(rem(abs_seconds, 3600), 60)

          " (#{sign}#{String.pad_leading(Integer.to_string(hours), 2, "0")}#{String.pad_leading(Integer.to_string(minutes), 2, "0")})"

        _ ->
          ""
      end

    "#{tz}#{offset}"
  end
end
