defmodule BaudrateWeb.RenderedHtmlPassesTest do
  @moduledoc """
  Stored content reaches the page through `BaudrateWeb.SafeHTML` and nowhere
  else.

  Two render-time passes ride on that module: the media-proxy rewrite
  ([ADR 0006](../../doc/adr/0006-media-proxy-no-third-party-subresources.md))
  and the accessible-name fallback
  ([ADR 0061](../../doc/adr/0061-an-image-description-is-not-a-form-field.md)).
  Both are applied on the way out precisely so that they cover rows written
  before they existed — which only works if every render site actually goes
  through them.

  It did not. `SafeHTML.body_html/1` covered the three `body_html` columns,
  while ten sites rendered a Markdown column with a bare
  `raw(Markdown.to_html(...))` — the article body among them — and an eleventh
  assigned the rendered HTML in the LiveView and wrote `raw(@assign)` in the
  template. `Markdown.to_html/1` carries the proxy rewrite itself, so nothing
  hotlinked; what it cannot carry is the `alt` fallback, which is translated
  and has no correct answer until there is a reader. So the article body would
  have kept skipping undescribed images while comments stopped.

  That eleventh site is why this gate is an allow-list of `raw/1` call sites
  rather than a search for one spelling: a pattern match on
  `raw(Markdown.to_html(` cannot see a call that was split across two files,
  and it is the split ones that survive review.
  """
  use ExUnit.Case, async: true

  @sources Path.wildcard("lib/baudrate_web/**/*.heex") ++
             Path.wildcard("lib/baudrate_web/**/*.ex")

  # `raw/1` in any spelling, including the fully qualified one — a template
  # writing `Phoenix.HTML.raw(@body_html)` bypasses the passes exactly as a
  # bare `raw/1` does, so a gate that only saw the short form would be one
  # rename away from useless. The lookbehind keeps `Foo.raw(` from matching.
  @raw_call ~r/(?<![.\w])(?:Phoenix\.HTML\.)?raw\(/

  # Every permitted `raw/1`, with why it is not stored content passing through
  # a render pass. Adding a line here is a deliberate act; the point of the
  # list is that it is short enough to read.
  @allowed %{
    # SafeHTML *is* the pass. Its own `Phoenix.HTML.raw/1` calls are the
    # implementation.
    "lib/baudrate_web/safe_html.ex" => "the module that applies the passes",

    # A gettext string with the article title escaped and wrapped in an <a>
    # built here. No user HTML reaches it and there is no image to describe.
    "lib/baudrate_web/live/user_content_live.html.heex" =>
      "a gettext sentence with an escaped title in a link built in place",

    # The bio is escaped first and then linkified; it is plain text, never
    # Markdown, so it carries no <img>.
    "lib/baudrate_web/live/user_profile_live.html.heex" =>
      "an escaped plain-text bio with hashtags linkified",

    # A JSON-LD <script>, built by LinkedData from typed values.
    "lib/baudrate_web/components/layouts/root.html.heex" => "the JSON-LD script block",

    # A compile-time constant script whose SHA-256 is in the CSP (ADR 0018's
    # no-inline-script rule). Nothing user-supplied reaches it, and changing
    # it changes the hash the router publishes.
    "lib/baudrate_web/theme_bootstrap.ex" => "the CSP-hashed inline theme script"
  }

  describe "stored content" do
    test "is never rendered with a bare raw/1" do
      offenders =
        for path <- @sources,
            Regex.match?(@raw_call, File.read!(path)),
            not Map.has_key?(@allowed, path),
            do: path

      assert offenders == [],
             """
             These call raw/1 outside the allow-list in this test:

             #{Enum.map_join(offenders, "\n", &("  " <> &1))}

             If it renders stored content, use `BaudrateWeb.SafeHTML` —
             `markdown/1` for a Markdown column, `body_html/1` for HTML — so
             the media-proxy rewrite and the accessible-name fallback both
             apply. If it genuinely is not stored content, add it to @allowed
             with the reason.
             """
    end

    test "has no allow-list entry that has gone stale" do
      stale =
        for {path, _why} <- @allowed,
            not (File.exists?(path) and Regex.match?(@raw_call, File.read!(path))),
            do: path

      assert stale == [],
             "these no longer call raw/1 and should leave @allowed: #{inspect(stale)}"
    end
  end

  describe "the replacement" do
    test "is actually used, so this cannot pass vacuously" do
      users =
        for path <- @sources,
            String.contains?(File.read!(path), "SafeHTML.markdown("),
            do: Path.basename(path)

      # If SafeHTML.markdown/1 were renamed or removed, the tests above would
      # go green by finding no violations either. Counting the real users is
      # what makes silence meaningful.
      assert length(users) >= 6, "expected the Markdown render sites, found: #{inspect(users)}"
    end
  end
end
