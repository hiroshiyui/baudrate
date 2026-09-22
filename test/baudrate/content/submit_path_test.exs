defmodule Baudrate.Content.SubmitPathTest do
  @moduledoc """
  A composer submits; it never creates (ADR 0065).

  `Content.submit_article/3` and `Content.submit_comment/2` are the only ways
  a member's writing can be **held** for a moderator — a new account's first
  posts, or a post a `hold` filter matched. `create_article/3` and
  `create_comment/2` still refuse what a filter blocks and still apply every
  other gate, but they cannot hold: that is right for bots, forwarding and
  approval itself, and wrong for anything a member typed. A LiveView that
  called them would publish, straight away, exactly the posts the operator
  asked to see first — and nothing would say so.

  So this walks the web layer's source and fails if any module calls the
  creating functions, the way `sanctions_gate_test.exs` keeps
  `ensure_not_moved/1` out of the posting paths.
  """
  use ExUnit.Case, async: true

  @forbidden [:create_article, :create_comment]
  @required [:submit_article, :submit_comment]

  test "no LiveView or controller creates content without going through submit" do
    offenders =
      web_sources()
      |> Enum.flat_map(fn path ->
        path |> calls() |> Enum.filter(&(&1 in @forbidden)) |> Enum.map(&{path, &1})
      end)

    assert offenders == [],
           """
           These call Content.create_article/3 or create_comment/2 directly, which
           publishes a post that should have been held for review. Call
           Content.submit_article/3 or submit_comment/2 instead (ADR 0065):

           #{Enum.map_join(offenders, "\n", fn {path, fun} -> "  - #{path}: #{fun}" end)}
           """
  end

  # Otherwise the test above passes because the composers moved somewhere
  # the walk cannot see, not because they call the right thing.
  test "the composers do call submit" do
    called = web_sources() |> Enum.flat_map(&calls/1) |> MapSet.new()

    for fun <- @required do
      assert fun in called, "nothing in lib/baudrate_web calls Content.#{fun} any more"
    end
  end

  defp web_sources, do: Path.wildcard("lib/baudrate_web/**/*.ex")

  # Every `Content.<fun>(...)` and `Baudrate.Content.<fun>(...)` in the file.
  defp calls(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, aliases}, fun]}, _, _} = node, acc
        when aliases in [[:Content], [:Baudrate, :Content]] ->
          {node, [fun | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
