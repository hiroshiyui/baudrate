defmodule BaudrateWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BaudrateWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout with navigation bar.

  Applied automatically via `layout:` in `live_session`.
  Shows nav links and user menu when `@current_user` is present;
  otherwise shows only the logo and theme toggle.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the currently authenticated user"
  attr :inner_content, :any, default: nil, doc: "the inner content rendered by the layout"

  def app(assigns) do
    ~H"""
    <header class="navbar bg-base-100 px-4 sm:px-6 lg:px-8">
      <%!-- Mobile hamburger (shown < lg) --%>
      <div :if={@current_user} class="flex-none lg:hidden">
        <div class="dropdown">
          <div tabindex="0" role="button" class="btn btn-ghost">
            <.icon name="hero-bars-3" class="size-5" />
          </div>
          <ul
            tabindex="0"
            class="menu menu-sm dropdown-content bg-base-100 rounded-box z-10 mt-3 w-52 p-2 shadow"
          >
            <li>
              <.link navigate="/">{gettext("Home")}</.link>
            </li>
            <li>
              <.link navigate="/">{gettext("Boards")}</.link>
            </li>
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
            <li class="divider my-1"></li>
            <li class="menu-title flex flex-row items-center gap-2">
              <.avatar user={@current_user} size={36} />
              {@current_user.username} ({@current_user.role.name})
            </li>
            <li>
              <.link navigate="/profile">{gettext("Profile")}</.link>
            </li>
            <li>
              <.link href="/logout" method="delete">{gettext("Sign Out")}</.link>
            </li>
          </ul>
        </div>
      </div>

      <%!-- Logo --%>
      <div class="flex-1">
        <.link navigate="/" class="btn btn-ghost text-xl">Baudrate</.link>
      </div>

      <%!-- Desktop nav links (shown >= lg) --%>
      <div :if={@current_user} class="hidden lg:flex flex-none">
        <ul class="menu menu-horizontal px-1 items-center">
          <li>
            <.link navigate="/" class="btn btn-ghost">{gettext("Home")}</.link>
          </li>
          <li>
            <.link navigate="/" class="btn btn-ghost">{gettext("Boards")}</.link>
          </li>
        </ul>
      </div>

      <%!-- Right side: theme toggle + auth links / user dropdown --%>
      <div class="flex-none flex items-center gap-2">
        <.theme_toggle />

        <%!-- Guest auth links (shown when not logged in) --%>
        <div :if={!@current_user} class="flex items-center gap-2">
          <.link navigate="/login" class="btn btn-ghost btn-sm">{gettext("Sign In")}</.link>
          <.link navigate="/register" class="btn btn-primary btn-sm">{gettext("Register")}</.link>
        </div>

        <%!-- Desktop user dropdown (shown >= lg) --%>
        <div :if={@current_user} class="hidden lg:block dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost gap-2">
            <.avatar user={@current_user} size={36} />
            {@current_user.username}
            <.icon name="hero-chevron-down-micro" class="size-4" />
          </div>
          <ul
            tabindex="0"
            class="menu menu-sm dropdown-content bg-base-100 rounded-box z-10 mt-3 w-52 p-2 shadow"
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
            <li :if={@current_user.role.name == "admin"} class="divider my-1"></li>
            <li>
              <.link navigate="/profile">{gettext("Profile")}</.link>
            </li>
            <li>
              <.link href="/logout" method="delete">{gettext("Sign Out")}</.link>
            </li>
          </ul>
        </div>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {@inner_content}
      </div>
    </main>

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
    <div id={@id} aria-live="polite">
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
    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {@inner_content}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
