defmodule BaudrateWeb.Locale do
  @moduledoc """
  Shared locale resolution utilities used by `SetLocale` plug and `AuthHooks`.

  ## Locale Resolution Priority

    1. User's `preferred_locales` (if authenticated and non-empty) -- first match wins
    2. `Accept-Language` header (handled by `SetLocale` plug)
    3. Default Gettext locale (`"en"`)

  ## Functions

    * `resolve_from_preferences/1` -- returns the first locale from a list that
      matches a known Gettext locale, or `nil`
    * `locale_display_name/1` -- returns a human-readable name for a locale code
    * `available_locales/0` -- returns `[{code, display_name}, ...]` for all known locales
  """

  @display_names %{
    "en" => "English",
    "zh_TW" => "正體中文"
  }

  @doc """
  Returns the first locale from `locales` that is a known Gettext locale, or `nil`.
  """
  def resolve_from_preferences(locales) when is_list(locales) do
    known = Gettext.known_locales(BaudrateWeb.Gettext)
    Enum.find(locales, &(&1 in known))
  end

  def resolve_from_preferences(_), do: nil

  @doc """
  Returns a human-readable display name for a locale code.

  Falls back to the code itself if no display name is configured.
  """
  def locale_display_name(code) when is_binary(code) do
    Map.get(@display_names, code, code)
  end

  @doc """
  Returns a list of `{code, display_name}` tuples for all known Gettext locales.
  """
  def available_locales do
    BaudrateWeb.Gettext
    |> Gettext.known_locales()
    |> Enum.map(fn code -> {code, locale_display_name(code)} end)
    |> Enum.sort_by(fn {code, _} -> code end)
  end
end
