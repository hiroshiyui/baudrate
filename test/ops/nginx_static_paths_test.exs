defmodule Ops.NginxStaticPathsTest do
  @moduledoc """
  Keeps nginx's static-file rule from outliving the files it serves.

  nginx sits in front of the application and answers some paths from disk so
  the request never reaches Phoenix. That is a performance choice, and it
  quietly becomes a correctness one the moment a path stops being a file: the
  `location` block still matches, `root` finds nothing, and **nginx answers its
  own 404** before the router is ever consulted. The application is correct,
  every test passes, and the endpoint is dead in production only.

  That is not hypothetical. `robots.txt` became a route in v1.33.0 — its
  `Sitemap:` directive needs an absolute URL, which only the application knows
  ([ADR 0057](../../doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md))
  — and `priv/static/robots.txt` was deleted with it. The nginx template still
  matched `robots[^/]*\\.txt`, so the deploy left the instance serving a 404
  there: no sitemap advertised, and no `Disallow` for `/ap/`, `/api/` or
  `/exports/` at all.

  The rule this enforces: **every alternative in the static `location` regex
  must name something `BaudrateWeb.static_paths/0` actually serves as a file.**
  Anything the application generates belongs in `location /`.

  The converse is deliberately not checked. A static path with no nginx rule is
  proxied to Phoenix, which is slower but correct.
  """

  use ExUnit.Case, async: true

  @template "ansible/roles/nginx/templates/baudrate.conf.j2"

  # The static `location ~ ^/(…)` block, captured up to its opening brace.
  @location_re ~r/location\s+~\s+\^\/\((?<alts>.+?)\)\s*\{/

  setup_all do
    conf = File.read!(@template)

    alts =
      case Regex.named_captures(@location_re, conf) do
        %{"alts" => alts} ->
          alts

        nil ->
          flunk("""
          no static `location ~ ^/(…)` block found in #{@template}.

          If the block was renamed or restructured, update @location_re — do
          not delete this test. It is the only thing standing between a path
          that stops being a file and a production-only 404.
          """)
      end

    {:ok, alternatives: split_top_level(alts)}
  end

  test "the static location block was found and names something", %{alternatives: alts} do
    refute alts == [], "the static location regex has no alternatives"
  end

  test "every alternative names a path the application serves as a file", %{alternatives: alts} do
    served = Enum.map(BaudrateWeb.static_paths(), &("/" <> &1))

    for alt <- alts do
      {:ok, re} = Regex.compile("^/(?:" <> alt <> ")")

      assert Enum.any?(served, &Regex.match?(re, &1)), """
      the nginx static block matches #{inspect(alt)}, but nothing in
      BaudrateWeb.static_paths/0 matches it:

        #{Enum.join(served, "\n  ")}

      nginx serves this pattern from disk with `root`, so if the file no
      longer exists it answers its own 404 and the request never reaches the
      router. If this path became a route, remove it from the `location`
      regex in #{@template}; if it is still a file, add it to static_paths/0.
      """
    end
  end

  # Split an alternation on its top-level `|` only, so a nested group such as
  # `favicon[^/]*\.(ico|svg)` stays in one piece.
  defp split_top_level(alts) do
    alts
    |> String.graphemes()
    |> Enum.reduce({[], [], 0, 0, false}, &scan/2)
    |> close()
  end

  defp scan(char, {done, current, parens, brackets, escaped}) do
    cond do
      escaped -> {done, [char | current], parens, brackets, false}
      char == "\\" -> {done, [char | current], parens, brackets, true}
      char == "[" -> {done, [char | current], parens, brackets + 1, false}
      char == "]" -> {done, [char | current], parens, brackets - 1, false}
      char == "(" and brackets == 0 -> {done, [char | current], parens + 1, brackets, false}
      char == ")" and brackets == 0 -> {done, [char | current], parens - 1, brackets, false}
      char == "|" and parens == 0 and brackets == 0 -> {[finish(current) | done], [], 0, 0, false}
      true -> {done, [char | current], parens, brackets, false}
    end
  end

  defp close({done, current, _parens, _brackets, _escaped}) do
    [finish(current) | done]
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp finish(current), do: current |> Enum.reverse() |> Enum.join() |> String.trim()
end
