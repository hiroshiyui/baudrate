defmodule BaudrateWeb.HTTPCaching do
  @moduledoc """
  Conditional-GET helpers for the documents this instance serves to machines.

  The syndication feeds and the sitemap are both polled on a schedule by
  clients that keep the previous response — a feed reader every few minutes, a
  crawler every few days. Both answer `Last-Modified` and honour
  `If-Modified-Since` with a 304, so a poll that finds nothing new costs a
  header exchange instead of a rendered document.

  **Date parsing is deliberately non-bang.** The RFC 7231 regex happily matches
  day 32 and hour 99, so `Date.new!`/`Time.new!` turned a malformed
  `If-Modified-Since` into an `ArgumentError` — a 500 on an unauthenticated
  route, repeatable at will. Anything that does not parse is treated as "no
  condition given", which serves the document.
  """

  import Plug.Conn

  @http_days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @http_months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @month_map %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  @doc """
  Returns true when the request's `If-Modified-Since` is at or after
  `last_modified`, meaning the caller already has this document.

  A `nil` `last_modified` (an empty document with nothing to date) is never
  considered unmodified.
  """
  @spec not_modified_since?(Plug.Conn.t(), DateTime.t() | nil) :: boolean()
  def not_modified_since?(_conn, nil), do: false

  def not_modified_since?(conn, %DateTime{} = last_modified) do
    case get_req_header(conn, "if-modified-since") do
      [ims_string] ->
        case parse_http_date(ims_string) do
          {:ok, ims_dt} -> DateTime.compare(last_modified, ims_dt) in [:lt, :eq]
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Sets `Last-Modified` from a `DateTime`, or leaves the connection alone when
  there is no date to give.
  """
  @spec put_last_modified(Plug.Conn.t(), DateTime.t() | nil) :: Plug.Conn.t()
  def put_last_modified(conn, nil), do: conn

  def put_last_modified(conn, %DateTime{} = dt) do
    put_resp_header(conn, "last-modified", format_http_date(dt))
  end

  @doc "Formats a `DateTime` as an RFC 7231 IMF-fixdate in GMT."
  @spec format_http_date(DateTime.t()) :: String.t()
  def format_http_date(%DateTime{} = dt) do
    day_name = Enum.at(@http_days, Date.day_of_week(dt) - 1)
    month_name = Enum.at(@http_months, dt.month - 1)

    "#{day_name}, #{pad2(dt.day)} #{month_name} #{dt.year} " <>
      "#{pad2(dt.hour)}:#{pad2(dt.minute)}:#{pad2(dt.second)} GMT"
  end

  @doc """
  Parses an RFC 7231 IMF-fixdate (`"Sun, 23 Feb 2026 05:57:22 GMT"`).

  Returns `{:ok, datetime}` or `:error`; see the module note on why nothing
  here raises.
  """
  @spec parse_http_date(String.t()) :: {:ok, DateTime.t()} | :error
  def parse_http_date(string) when is_binary(string) do
    case Regex.run(~r/\w+, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT/, string) do
      [_, day, month_str, year, hour, min, sec] ->
        with month when is_integer(month) <- Map.get(@month_map, month_str),
             {:ok, date} <- Date.new(String.to_integer(year), month, String.to_integer(day)),
             {:ok, time} <-
               Time.new(String.to_integer(hour), String.to_integer(min), String.to_integer(sec)) do
          DateTime.new(date, time)
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_http_date(_), do: :error

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"
end
