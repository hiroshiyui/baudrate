defmodule BaudrateWeb.Plugs.SetLocale do
  @moduledoc """
  Plug that detects the user's preferred locale and sets it for Gettext.

  ## Locale Resolution Priority

    1. User's `preferred_locales` from the cookie session (stored at login).
       Resolved via `BaudrateWeb.Locale.resolve_from_preferences/1`.
    2. `Accept-Language` header — parsed, sorted by quality, matched against
       known Gettext locales (exact match first, then prefix fallback).
    3. Default Gettext locale (`"en"`).

  The detected locale is assigned to `conn.assigns.locale` for use in templates.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    locale = detect_locale(conn)
    Gettext.put_locale(locale)

    conn
    |> assign(:locale, locale)
  end

  defp detect_locale(conn) do
    # 1. Check user's preferred_locales from session
    case conn |> Plug.Conn.get_session(:preferred_locales) |> resolve_session_locales() do
      nil ->
        # 2. Fall back to Accept-Language header
        detect_from_accept_language(conn)

      locale ->
        locale
    end
  end

  defp resolve_session_locales(locales) when is_list(locales) and locales != [] do
    BaudrateWeb.Locale.resolve_from_preferences(locales)
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
