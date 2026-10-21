defmodule Baudrate.DistinctOrderTest do
  @moduledoc """
  No query de-duplicates by primary key with `distinct: x.id`.

  Ecto compiles `distinct: a.id` to `DISTINCT ON (a.id)`, PostgreSQL requires
  those expressions to lead the `ORDER BY`, and Ecto prepends them — silently
  replacing a requested newest-first order with `id` ascending. It was the
  pattern for "articles in at least one visible board" (a board join plus
  `distinct`), and it shipped three times: comment search, the user outbox,
  and the site, user and tag feeds with the profile and tag listings — the
  feeds, being limited, carried the oldest articles. The board test is an
  `exists` subquery instead, which duplicates nothing.

  So this walks `lib/` and fails on the pattern, the way
  `submit_path_test.exs` keeps the creating functions out of the web layer.
  """
  use ExUnit.Case, async: true

  # Code, not the comments and docs that quote it in backticks.
  @pattern ~r/(?<!`)distinct:\s*\w+\.id\b/

  test "no query uses DISTINCT ON a primary key" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ @pattern end)
        |> Enum.map(fn {_, n} -> "#{path}:#{n}" end)
      end)

    assert offenders == [],
           """
           `distinct: x.id` becomes DISTINCT ON (x.id), which overrides the query's
           ORDER BY. Test the joined rows with an `exists` subquery instead:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}
           """
  end
end
