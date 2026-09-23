defmodule BaudrateWeb.Plugs.ClearTimeZoneTest do
  # Not async: the zone is process state, and so is the site setting cache.
  use BaudrateWeb.ConnCase, async: false

  alias BaudrateWeb.Plugs.ClearTimeZone
  alias BaudrateWeb.TimeZone

  test "clears a zone a previous request in this process left behind", %{conn: conn} do
    TimeZone.put("America/New_York")

    ClearTimeZone.call(conn, ClearTimeZone.init([]))

    assert TimeZone.current() == TimeZone.site_zone()
  end

  # Every browser request, not only pages that run the auth hooks: a
  # controller page or a public LiveView would otherwise render in whatever
  # zone the process last served.
  test "runs on every browser request" do
    [_, pipeline] = String.split(File.read!("lib/baudrate_web/router.ex"), "pipeline :browser do")
    [pipeline | _] = String.split(pipeline, "\n  end", parts: 2)

    assert pipeline =~ "plug BaudrateWeb.Plugs.ClearTimeZone"
  end
end
