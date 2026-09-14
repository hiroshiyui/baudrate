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
  def family(ua) when is_binary(ua) do
    case {match(@browsers, ua), match(@systems, ua)} do
      {nil, nil} -> nil
      {browser, nil} -> browser
      {nil, os} -> os
      {browser, os} -> "#{browser} on #{os}"
    end
  end

  def family(_), do: nil

  defp match(patterns, ua) do
    Enum.find_value(patterns, fn {re, name} -> if Regex.match?(re, ua), do: name end)
  end
end
