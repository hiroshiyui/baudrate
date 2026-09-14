defmodule BaudrateWeb.PaginationConsistencyTest do
  @moduledoc """
  Keeps every paginated page behaving the same way.

  Paging is shared, not written per page: `<.pagination>` builds the `?page=N`
  links, `BaudrateWeb.PaginationScrollHook` (mounted for every LiveView by
  `use BaudrateWeb, :live_view`) pushes `scroll-to-top` when the page changes,
  and `app.js` scrolls to the pager's `scroll_target` or the page's
  `[data-focus-target]` and moves focus there. Only the board and search pages
  used to scroll, each with its own code, so the feed and eleven other pages
  left the viewer at the bottom of the next page. These checks fail when a
  new page would drift from that again.
  """

  use ExUnit.Case, async: true

  @web "lib/baudrate_web"

  defp sources(glob), do: Path.wildcard(Path.join(@web, glob)) |> Enum.map(&{&1, File.read!(&1)})

  # A LiveView's markup lives in `x.ex` and/or its colocated `x.html.heex`.
  defp page_markup(file) do
    base = String.replace_suffix(String.replace_suffix(file, ".html.heex", ""), ".ex", "")

    [base <> ".ex", base <> ".html.heex"]
    |> Enum.filter(&File.exists?/1)
    |> Enum.map_join("\n", &File.read!/1)
  end

  test "every pager has a list to scroll to" do
    pagers =
      for {file, source} <- sources("live/**/*.{ex,heex}"),
          # Up to the self-closing "/>": attribute values such as
          # `:if={@total_pages > 1}` contain ">" themselves.
          pager <- Regex.scan(~r/^\s*<\.pagination\b.*?\/>/ms, source) |> List.flatten() do
        {file, pager}
      end

    occurrences =
      sources("live/**/*.{ex,heex}")
      |> Enum.map(fn {_file, source} -> length(Regex.scan(~r/^\s*<\.pagination\b/m, source)) end)
      |> Enum.sum()

    assert length(pagers) == occurrences, "a <.pagination> tag was not parsed"
    assert pagers != []

    missing =
      for {file, pager} <- pagers,
          not String.contains?(pager, "scroll_target="),
          not String.contains?(page_markup(file), "data-focus-target") do
        file
      end

    assert missing == [],
           "Mark the paginated list with data-focus-target or pass scroll_target to <.pagination>: #{inspect(Enum.uniq(missing))}"
  end

  test "only the shared hook pushes scroll-to-top" do
    offenders =
      for {file, source} <- sources("**/*.ex"),
          file != Path.join(@web, "live/pagination_scroll_hook.ex"),
          String.contains?(source, ~s("scroll-to-top")) do
        file
      end

    assert offenders == []
  end

  test "every LiveView uses the project macro that mounts the pagination hook" do
    raw =
      for {file, source} <- sources("**/*.ex"),
          Regex.match?(~r/^\s*use Phoenix\.LiveView\s*$/m, source),
          file != Path.join(@web, "../baudrate_web.ex") do
        file
      end

    assert raw == []

    assert File.read!("lib/baudrate_web.ex") =~ "on_mount BaudrateWeb.PaginationScrollHook"
  end
end
