defmodule BaudrateWeb.Plugs.SetTheme do
  @moduledoc """
  Plug that injects admin-configured theme settings into conn assigns.

  Reads `theme_light` and `theme_dark` from `Baudrate.Setup` and assigns
  them so the root layout can render `data-theme-light` / `data-theme-dark`
  attributes on the `<html>` tag. Client-side JS reads these to resolve
  the user's light/dark/system preference into the correct DaisyUI theme name.
  """

  import Plug.Conn
  alias Baudrate.Setup

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    themes = Setup.get_theme_settings()

    conn
    |> assign(:theme_light, themes.light)
    |> assign(:theme_dark, themes.dark)
  end
end
