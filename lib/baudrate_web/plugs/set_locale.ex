defmodule BaudrateWeb.Plugs.SetLocale do
  @moduledoc """
  Plug that detects the user's preferred locale and sets it for Gettext.

  ## Locale Resolution Priority

    1. The `locale` **cookie** — an explicit choice made in the footer
       switcher (`BaudrateWeb.LocaleController`). First, because it is the only
       one of these a person actually said out loud. An unknown value is
       ignored rather than trusted: `BaudrateWeb.Locale.known?/1` is the
       allow-list, and nothing else reaches `Gettext.put_locale/1`.
    2. User's `preferred_locales` from the cookie session (stored at login).
       Resolved via `BaudrateWeb.Locale.resolve_from_preferences/1`. This copy
       is a **cache**: only a session write refreshes it, which is why a
       language change on `/profile/account` posts to `LocaleController`.
    3. `Accept-Language` header — parsed, sorted by quality, matched against
       known Gettext locales (exact match first, then prefix fallback).
    4. Default Gettext locale (`"en"`).

  The detected locale is assigned to `conn.assigns.locale` for use in
  templates, and stored in `session[:locale]` so `BaudrateWeb.AuthHooks` can
  apply the same answer in a LiveView mount instead of flipping the language
  after the dead render.
  """

  import Plug.Conn

  alias BaudrateWeb.Locale

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Idempotent, and it keeps the plug correct wherever it is mounted: an
    # unfetched conn answers `%Plug.Conn.Unfetched{}` for `cookies`, which
    # would make the explicit choice silently unreadable.
    conn = fetch_cookies(conn)
    locale = detect_locale(conn)
    Gettext.put_locale(locale)

    conn
    |> assign(:locale, locale)
    |> maybe_put_session_locale(locale)
  end

  defp maybe_put_session_locale(conn, locale) do
    if Map.get(conn.private, :plug_session_fetch) == :done do
      if Plug.Conn.get_session(conn, :locale) == locale do
        conn
      else
        Plug.Conn.put_session(conn, :locale, locale)
      end
    else
      conn
    end
  end

  defp detect_locale(conn) do
    # 1. An explicit choice, from the footer switcher's cookie
    with nil <- chosen_locale(conn),
         # 2. The member's account, as cached in the session at login
         nil <- conn |> Plug.Conn.get_session(:preferred_locales) |> resolve_session_locales() do
      # 3. and 4. The browser's own answer, then the default
      detect_from_accept_language(conn)
    end
  end

  defp chosen_locale(conn) do
    code = Map.get(conn.cookies, Locale.cookie_name())
    if Locale.known?(code), do: code
  end

  defp resolve_session_locales(locales) when is_list(locales) and locales != [] do
    Locale.resolve_from_preferences(locales)
  end

  defp resolve_session_locales(_), do: nil

  defp detect_from_accept_language(conn) do
    default = Gettext.get_locale()
    known = Gettext.known_locales(BaudrateWeb.Gettext)

    conn
    |> get_req_header("accept-language")
    |> parse_accept_language()
    |> find_best_match(known)
    |> case do
      nil -> default
      locale -> locale
    end
  end

  defp parse_accept_language([]), do: []

  defp parse_accept_language([header | _]) do
    header
    |> String.split(",")
    |> Enum.map(&parse_language_tag/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_tag, q} -> q end, :desc)
  end

  defp parse_language_tag(tag_string) do
    tag_string = String.trim(tag_string)

    case String.split(tag_string, ";") do
      [tag] ->
        {normalize(tag), 1.0}

      [tag | params] ->
        q = extract_quality(params)
        {normalize(tag), q}
    end
  end

  defp extract_quality(params) do
    Enum.find_value(params, 1.0, fn param ->
      param = String.trim(param)

      case String.split(param, "=") do
        ["q", value] ->
          case Float.parse(value) do
            {q, _} -> q
            :error -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp normalize(tag) do
    tag
    |> String.trim()
    |> String.replace("-", "_")
  end

  defp find_best_match(preferred_locales, known_locales) do
    known_lower = Map.new(known_locales, fn k -> {String.downcase(k), k} end)

    Enum.find_value(preferred_locales, fn {tag, _q} ->
      downcased = String.downcase(tag)

      cond do
        Map.has_key?(known_lower, downcased) ->
          Map.get(known_lower, downcased)

        true ->
          prefix = downcased |> String.split("_") |> hd()
          find_by_prefix(prefix, known_lower)
      end
    end)
  end

  defp find_by_prefix(prefix, known_lower) do
    Enum.find_value(known_lower, fn {key, original} ->
      key_prefix = key |> String.split("_") |> hd()
      if key_prefix == prefix, do: original
    end)
  end
end
