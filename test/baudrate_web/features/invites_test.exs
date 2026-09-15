defmodule BaudrateWeb.Features.InvitesTest do
  use BaudrateWeb.FeatureCase, async: false

  import Ecto.Query

  @moduletag :feature

  feature "invites page is accessible when logged in", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/invites")
    |> assert_has(Query.css("h1", text: "My Invites"))
  end

  feature "invites page shows generate button", %{session: session} do
    user = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/invites")
    |> assert_has(Query.button("Generate Code"))
  end

  feature "a member generates an invite code and copies its link", %{session: session} do
    user = setup_user("user")
    week_ago = DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.truncate(:second)

    Baudrate.Repo.update_all(
      from(u in Baudrate.Setup.User, where: u.id == ^user.id),
      set: [inserted_at: week_ago]
    )

    session
    |> log_in_via_browser(user)
    |> visit("/invites")
    |> click(Query.css("#user-invites-generate"))
    |> assert_has(Query.text("Invite code generated."))
    |> assert_has(Query.css("#invite-codes-table .invite-code-copy", count: 1))

    [code] = Baudrate.Auth.list_user_invite_codes(user)

    session
    |> click(Query.css("#copy-invite-#{code.id}"))
    |> assert_has(Query.css(~s(#copy-invite-#{code.id}[aria-label="Copied!"])))

    # The feedback appears only after the clipboard write succeeded; the
    # screen reader announcement follows it (sr-only, so read it by script).
    Process.sleep(200)

    assert js_value(session, "return document.getElementById('copy-announcer').textContent") ==
             "Copied!"
  end
end
