defmodule BaudrateWeb.Features.AnnouncementNoticeTest do
  @moduledoc """
  A guest dismisses a site announcement in their own browser (7B): the
  `AnnouncementNoticeHook` keeps the id in `localStorage` and hides the
  notice, and it stays hidden on the next page — which no LiveView test can
  see, because the hook is JavaScript.
  """
  use BaudrateWeb.FeatureCase, async: false

  alias Baudrate.Announcements

  @moduletag :feature

  feature "a guest's dismissal holds from one page to the next", %{session: session} do
    admin = setup_user("admin")
    {:ok, a} = Announcements.create_announcement(admin, %{"body" => "Scheduled maintenance"})
    notice = Query.css("#announcement-notice-#{a.id}")

    session = visit(session, "/")
    assert visible?(session, notice), "the notice should show to a guest"

    click(session, Query.css("#announcement-notice-dismiss-#{a.id}"))
    refute visible?(session, notice)

    # The notice is in the first render and the hook hides it once the
    # socket connects, so wait for that before looking.
    session =
      session
      |> visit("/search")
      |> assert_has(Query.css("[data-phx-main].phx-connected"))

    refute visible?(session, notice), "a dismissed notice came back on the next page"
  end
end
