defmodule BaudrateWeb.ErrorHTMLTest do
  use BaudrateWeb.ConnCase, async: true
  use Gettext, backend: BaudrateWeb.Gettext

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders the 404 page with the translated heading and a home link" do
    html = render_to_string(BaudrateWeb.ErrorHTML, "404", "html", [])

    assert html =~ gettext("Page not found")
    assert html =~ ~s(href="/")
    assert html =~ gettext("Back to home")
  end

  test "renders the 500 page with the translated heading and a home link" do
    html = render_to_string(BaudrateWeb.ErrorHTML, "500", "html", [])

    assert html =~ gettext("Something went wrong")
    assert html =~ ~s(href="/")
    assert html =~ gettext("Back to home")
  end

  test "page_title/1 returns localized titles for error statuses only" do
    assert BaudrateWeb.ErrorHTML.page_title(404) == gettext("Page not found")
    assert BaudrateWeb.ErrorHTML.page_title(500) == gettext("Something went wrong")
    assert BaudrateWeb.ErrorHTML.page_title(503) == gettext("Something went wrong")
    assert BaudrateWeb.ErrorHTML.page_title(nil) == nil
    assert BaudrateWeb.ErrorHTML.page_title(200) == nil
  end

  test "falls back to the Phoenix plain-text message for status codes without a template" do
    # The fallback path HTML-escapes the raw status message before embedding.
    assert render_to_string(BaudrateWeb.ErrorHTML, "418", "html", []) =~ "teapot"
  end
end
