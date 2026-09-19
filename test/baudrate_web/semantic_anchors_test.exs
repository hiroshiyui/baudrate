defmodule BaudrateWeb.SemanticAnchorsTest do
  @moduledoc """
  Gate for the parts of [ADR 0018](../../doc/adr/0018-semantic-ids-and-classes-for-accessibility.md)
  that can be falsified.

  **What this does not check.** 0018's headline rule — "every meaningful
  element carries a stable, semantic `id` and/or `class`" — is a judgement:
  "meaningful" excludes presentational wrappers and leaf components, and no
  test can draw that line. Measuring the obvious approximations showed why
  they would be worse than nothing: 23 of 118 `:for` elements carry no
  `class`, nearly all of them `<option>`s and layout wrappers, so a gate on
  that would fail the build for correct code. That half of 0018 stays
  review-held, and `doc/baudrate-spec.md` says so rather than implying
  coverage this file does not give.

  What *is* falsifiable is the **uniqueness** clause, and the rule that
  stylesheets hang off semantic selectors. Both are checked here.

  Four things that look like violations and are not, established when this was
  written — each is why a check is shaped the way it is rather than the obvious
  way:

    * `conversation_live` renders `id="conversation-heading"` twice and
      `search_live` renders `id="search-actor-follow"` twice, each under
      complementary `:if` branches. Exactly one reaches the DOM, and keeping
      the id stable across both is *good* practice. So duplicates are checked
      against **rendered output**, never by counting literals in a template.
    * `search_live` and `admin/pending_users_live` each carry
      `data-focus-target` *and* `autofocus`, which 0018's Consequences and
      `CLAUDE.md` both forbid. `assets/js/app.js` already reconciles them —
      the focus handler returns early when the page has an `[autofocus]` — so
      the combination is inert, not a fight. No check here fails the build for
      it; the rule is real as guidance and the code defends it at runtime.
  """

  use BaudrateWeb.ConnCase, async: false

  alias Baudrate.Repo
  alias Baudrate.Setup

  @web_root "lib/baudrate_web"
  @app_css "assets/css/app.css"

  # Every parameterless page a guest can reach. Loop-heavy templates
  # (`/`, `/search`) are the ones where a duplicate id would actually bite.
  @public_pages [
    "/",
    "/search",
    "/rules",
    "/terms",
    "/privacy",
    "/login",
    "/register",
    "/password-reset"
  ]

  # Selectors in app.css that chain structural classes deliberately. Each
  # restyles a daisyUI *component* generically rather than one meaningful
  # element, so there is no semantic handle to hang it on — the same
  # distinction settled for the Aqua themes on 2026-09-19 (doc/TODOs.md).
  # A new entry here is a decision, which is the point of listing them.
  @structural_exemptions [
    ".dropdown:focus-within > .dropdown-content::after",
    ".dropdown.dropdown-open > .dropdown-content::after"
  ]

  describe "uniqueness (ADR 0018)" do
    test "a :for element never carries a literal id" do
      offenders =
        template_files()
        |> Enum.flat_map(fn path ->
          source = File.read!(path)

          for {tag, offset} <- tags(source),
              String.contains?(tag, ":for="),
              [_, value] = Regex.run(~r/\sid="([^"]*)"/, tag) || [nil, nil],
              is_binary(value),
              not String.contains?(value, "\#{") do
            "#{path}:#{line_of(source, offset)} id=\"#{value}\""
          end
        end)

      assert offenders == [],
             """
             A `:for` element with a fixed `id` renders that id once per item,
             so the page has as many duplicates as the list is long. Derive it
             from the record (`id={"thing-\#{thing.id}"}`) and keep the shared
             class for styling — ADR 0018, Uniqueness.

             #{Enum.join(offenders, "\n")}
             """
    end

    test "no page renders a duplicate id" do
      Setup.seed_roles_and_permissions()
      Repo.insert!(%Setup.Setting{key: "setup_completed", value: "true"})

      for path <- @public_pages do
        conn = get(build_conn(), path)

        assert conn.status == 200,
               "#{path} answered #{conn.status}. This list is the gate's coverage — " <>
                 "fix the path or remove it deliberately, do not let it rot."

        body = html_response(conn, 200)

        dups =
          ~r/\sid="([^"]+)"/
          |> Regex.scan(body, capture: :all_but_first)
          |> List.flatten()
          |> Enum.frequencies()
          |> Enum.filter(fn {_id, n} -> n > 1 end)
          |> Enum.sort()

        assert dups == [],
               "#{path} renders duplicate ids: #{inspect(dups)}. An `id` must be " <>
                 "unique per rendered page (ADR 0018) — `aria-labelledby`, " <>
                 "`for`/`id` and LiveView patching all resolve by it, and a " <>
                 "duplicate silently binds the wrong one."
      end
    end
  end

  describe "stylesheets target semantic selectors (ADR 0018)" do
    test "app.css adds no structural or positional selector" do
      found =
        @app_css
        |> File.read!()
        |> strip_comments()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(fn line ->
          String.contains?(line, "> .") or String.contains?(line, ":nth-child(") or
            String.contains?(line, ":nth-of-type(")
        end)
        |> Enum.map(&String.trim_trailing(&1, ","))
        |> Enum.map(&String.trim_trailing(&1, " {"))
        |> Enum.reject(&(&1 in @structural_exemptions))

      assert found == [],
             """
             app.css gained a structural or positional selector. ADR 0018 names
             `.card > .card-body` as the anti-pattern by example, and its stated
             remedy is to give the element a semantic handle first.

             If the rule genuinely targets a daisyUI *component* rather than one
             meaningful element — as the two `.dropdown` rules do — add it to
             @structural_exemptions with a comment saying which, so the decision
             is visible rather than absorbed.

             #{Enum.join(found, "\n")}
             """
    end
  end

  # --- helpers ---

  defp template_files do
    Path.wildcard(Path.join(@web_root, "**/*.{ex,heex}"))
  end

  # Opening tags, with their byte offset, so a failure can name a line.
  defp tags(source) do
    Regex.scan(~r/<[.\w][^>]*?>/s, source, return: :index)
    |> Enum.map(fn [{start, len} | _] -> {binary_part(source, start, len), start} end)
  end

  defp line_of(source, offset) do
    source
    |> binary_part(0, offset)
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
    |> Kernel.+(1)
  end

  defp strip_comments(css), do: Regex.replace(~r|/\*.*?\*/|s, css, "")
end
