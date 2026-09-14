defmodule BaudrateWeb.ThemeBootstrap do
  @moduledoc """
  The tiny inline script in the root layout that applies the stored theme and
  font size to `<html>` before the stylesheet is parsed, so pages do not flash
  the wrong theme. `app.js` keeps the full logic; this only covers the window
  before it loads.

  The content security policy allows no inline script (`script-src 'self'`),
  so the router adds this script's SHA-256 hash to `script-src`
  (`csp_source/0`). The hash is computed at compile time from the same bytes
  the layout renders, so editing the script cannot silently get it blocked.
  Before v1.18.2 the policy had no hash and browsers never ran it.
  """

  @script "(function(){try{var h=document.documentElement;var t=localStorage.getItem('phx:theme');t=(t==='light'||t==='dark')?t:'system';h.dataset.themePref=t;var c={light:h.dataset.themeLight||'light',dark:h.dataset.themeDark||'dark'};var v=t==='light'?c.light:t==='dark'?c.dark:(window.matchMedia('(prefers-color-scheme: dark)').matches?c.dark:c.light);h.setAttribute('data-theme',v);var s=Number(localStorage.getItem('phx:font-size'))||100;s=Math.max(75,Math.min(150,s));h.style.fontSize=s+'%';}catch(e){}})();"

  @csp_source "'sha256-#{Base.encode64(:crypto.hash(:sha256, @script))}'"

  @doc "The script body, without the surrounding `<script>` tag."
  def script, do: @script

  @doc "The `<script>` element for the root layout."
  def script_tag, do: Phoenix.HTML.raw("<script>" <> @script <> "</script>")

  @doc "The `script-src` source expression (a quoted hash) that allows `script/0`."
  def csp_source, do: @csp_source
end
