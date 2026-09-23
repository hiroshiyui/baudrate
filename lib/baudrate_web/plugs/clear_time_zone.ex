defmodule BaudrateWeb.Plugs.ClearTimeZone do
  @moduledoc """
  Clears the viewer's time zone (`BaudrateWeb.TimeZone`) at the start of
  every browser request.

  The zone lives in the process dictionary, and one process can serve
  several keep-alive requests — from different people, once nginx pools its
  upstream connections. Without this, a page rendered for a guest could come
  out in the zone of the member served before them. `BaudrateWeb.AuthHooks`
  sets it again once it knows who is reading.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    BaudrateWeb.TimeZone.put(nil)
    conn
  end
end
