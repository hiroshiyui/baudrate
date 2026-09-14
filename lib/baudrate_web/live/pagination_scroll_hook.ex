defmodule BaudrateWeb.PaginationScrollHook do
  @moduledoc """
  Scrolls a paginated page back to its list when the `page` query parameter
  changes. It is mounted for every LiveView by `use BaudrateWeb, :live_view`,
  so a new paginated page gets it without doing anything.

  To page consistently, a page renders `<.pagination>` (which builds the
  `?page=N` links this hook watches) and either marks its list with
  `data-focus-target` or passes `scroll_target`.
  `test/baudrate_web/pagination_consistency_test.exs` fails when a template
  renders the pager without one of them.

  The hook attaches to `handle_params` and pushes `"scroll-to-top"` whenever
  the page number differs from the one last handled, whether the change came
  from the pager, a `push_patch` or browser back/forward. The initial load
  never scrolls. The `phx:scroll-to-top` handler in `app.js` scrolls to the
  pager's `data-scroll-target` (`<.pagination scroll_target="…">`, e.g. the
  comments section of an article) or else to the page's `[data-focus-target]`,
  and moves focus into it.

  Before this, only `BoardLive` and `SearchLive` pushed the event themselves,
  so paging the feed, comments, tags, bookmarks, notifications, a user's
  content and the admin lists left the viewer at the bottom of the new page.
  """

  import Phoenix.LiveView

  @private_key :pagination_scroll_page

  @doc false
  # `handle_params` hooks need a LiveView mounted at the router; nested or
  # isolated (live_isolated/3) LiveViews have no URL to page through.
  def on_mount(:default, _params, _session, %{router: nil} = socket), do: {:cont, socket}

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :pagination_scroll, :handle_params, &handle_params/3)}
  end

  @doc false
  def handle_params(params, _uri, socket) do
    page = page_number(params)

    socket =
      case Map.fetch(socket.private, @private_key) do
        {:ok, previous} when previous != page -> push_event(socket, "scroll-to-top", %{})
        _ -> socket
      end

    {:cont, put_private(socket, @private_key, page)}
  end

  # "?page=1", no page and an invalid page all mean the first page, so moving
  # between them does not scroll.
  defp page_number(%{"page" => page}) when is_binary(page) do
    case Integer.parse(page) do
      {number, ""} when number > 1 -> number
      _ -> 1
    end
  end

  defp page_number(_params), do: 1
end
