defmodule Baudrate.DataPortability.UserAgent do
  @moduledoc """
  Reduces a User-Agent header to a coarse, display-only family such as
  `"Firefox on Linux"`.

  Used for the data export warning banner, so the real user can recognise a
  request that did not come from their own browser. Only the family is
  stored, never the full header, which is more identifying than the banner
  needs.
  """

  @browsers [
    {~r/Edg\//, "Edge"},
    {~r/OPR\/|Opera/, "Opera"},
    {~r/Firefox\//, "Firefox"},
    {~r/Chrome\/|CriOS\//, "Chrome"},
    {~r/Safari\//, "Safari"}
  ]

  @systems [
    {~r/Android/, "Android"},
    {~r/iPhone|iPad|iPod/, "iOS"},
    {~r/Windows/, "Windows"},
    {~r/Mac OS X|Macintosh/, "macOS"},
    {~r/CrOS/, "ChromeOS"},
    {~r/Linux|X11/, "Linux"}
  ]

  @doc """
  Returns `"<browser> on <os>"`, `"<browser>"`, `"<os>"`, or `nil` when
  nothing is recognised.
  """
  @spec family(String.t() | nil) :: String.t() | nil
  def family(ua) do
    case parts(ua) do
      {nil, nil} -> nil
      {browser, nil} -> browser
      {nil, os} -> os
      {browser, os} -> "#{browser} on #{os}"
    end
  end

  @doc """
  Returns `{browser, os}`, either of which may be `nil`.

  For a page that renders the pair itself: the joining word in `family/1`
  is English, stored as it is in export and move requests, and a page must
  translate it instead.
  """
  @spec parts(String.t() | nil) :: {String.t() | nil, String.t() | nil}
  def parts(ua) when is_binary(ua), do: {match(@browsers, ua), match(@systems, ua)}
  def parts(_), do: {nil, nil}

  defp match(patterns, ua) do
    Enum.find_value(patterns, fn {re, name} -> if Regex.match?(re, ua), do: name end)
  end
end
