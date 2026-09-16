defmodule BaudrateWeb.Features.TermsAcceptTest do
  @moduledoc """
  The accept control on `/terms` must be *visible*, not merely present.

  It was in the DOM and invisible on production, which no LiveView test can
  see: they assert on rendered markup, and the browser crawls deliberately do
  not publish a terms version, so this card had never been drawn.
  """
  use BaudrateWeb.FeatureCase, async: false

  alias Baudrate.Setup

  @moduletag :feature

  feature "a member behind on the terms can see and press the accept button", %{
    session: session
  } do
    # The real document, not a one-liner: if its content is what hides the
    # card, a short fixture would pass while production stayed broken.
    eua =
      "doc/eua.md"
      |> File.read!()
      |> String.split("-->", parts: 2)
      |> List.last()

    Setup.update_eua(eua)
    {:ok, _} = Setup.publish_terms_version()

    user = setup_user("user")
    session = log_in_via_browser(session, user)

    session = visit(session, "/terms")

    assert visible?(session, Query.css("#policy-body")), "the terms text should render"

    assert visible?(session, Query.css("#terms-notice")),
           "the banner should appear for a member who owes an acceptance"

    assert visible?(session, Query.css("#terms-agreement")),
           "the accept card is in the DOM but not visible"

    assert visible?(session, Query.css("#terms-agreement-button")),
           "the accept button is in the DOM but not visible"

    click(session, Query.css("#terms-agreement-button"))

    assert visible?(session, Query.css("#policy-page"))
    refute Baudrate.Auth.terms_pending?(Baudrate.Repo.reload(user))
  end
end
