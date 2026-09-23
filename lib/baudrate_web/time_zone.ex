defmodule BaudrateWeb.TimeZone do
  @moduledoc """
  The time zone timestamps are shown in for whoever is reading the page.

  It works the way `Gettext.put_locale/1` does: the zone is kept in the
  process dictionary, set once per page and read by
  `BaudrateWeb.Helpers.format_datetime/2` and `format_date/1`, so none of
  their call sites has to be handed a viewer.

    * `BaudrateWeb.Plugs.ClearTimeZone` clears it on **every** browser
      request. Bandit serves keep-alive requests in one process, and nginx's
      upstream keep-alive can put different people's requests on one
      connection, so a zone must never outlive the request it was set for.
    * `BaudrateWeb.AuthHooks` sets the member's own `time_zone` once it
      knows who they are. A LiveView's dead render runs `on_mount` in the
      request's process, so that covers both renders.
    * Unset — a guest, or a member who never chose — means the site's
      `timezone` setting, read on each call (it is cached) so an admin's
      change applies at once.

  A stored zone can stop existing when the tz database drops a name, so
  `shift/1` falls back to the site zone and then UTC instead of raising:
  a bad value must never take every page down for the member who has it.
  """

  @key :baudrate_time_zone

  @doc "Sets the viewer's zone for this process; `nil` means the site default."
  @spec put(String.t() | nil) :: :ok
  def put(zone) when is_binary(zone) and zone != "" do
    Process.put(@key, zone)
    :ok
  end

  def put(_zone) do
    Process.delete(@key)
    :ok
  end

  @doc "The zone timestamps are shown in: the viewer's, else the site's."
  @spec current() :: String.t()
  def current, do: Process.get(@key) || site_zone()

  @doc "The site's configured zone, or UTC when none is set."
  @spec site_zone() :: String.t()
  def site_zone, do: Baudrate.Setup.get_setting("timezone") || "Etc/UTC"

  @doc """
  Shifts `datetime` into the current zone, falling back to the site zone and
  then UTC when a zone is unknown.
  """
  @spec shift(DateTime.t()) :: DateTime.t()
  def shift(%DateTime{} = datetime) do
    Enum.find_value([current(), site_zone()], DateTime.shift_zone!(datetime, "Etc/UTC"), fn
      zone ->
        case DateTime.shift_zone(datetime, zone) do
          {:ok, shifted} -> shifted
          {:error, _} -> nil
        end
    end)
  end

  @doc """
  The current zone's name and its UTC offset right now, e.g.
  `{"Asia/Taipei", "+08:00"}`, for the footer label.
  """
  @spec label() :: {String.t(), String.t()}
  def label do
    now = shift(DateTime.utc_now())
    offset = now.utc_offset + now.std_offset
    sign = if offset < 0, do: "-", else: "+"
    abs = abs(offset)
    hours = abs |> div(3600) |> Integer.to_string() |> String.pad_leading(2, "0")
    minutes = abs |> rem(3600) |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    {now.time_zone, "#{sign}#{hours}:#{minutes}"}
  end
end
