defmodule BaudrateWeb.NotFoundError do
  @moduledoc """
  Raised when a page's subject does not exist, so the request answers 404.

  `Plug.Exception` reads `:plug_status`, which is how `Ecto.NoResultsError`
  already reaches the 404 page from `ArticleLive` and `BoardLive` through
  `get_article_by_slug!` / `get_board_by_slug!`. This is the same mechanism for
  the cases that are not a missing row: a **banned** account, which must be
  indistinguishable from an account that never existed.

  Redirecting instead tells a crawler the page *moved*, so it keeps asking and
  the target collects the authority of every mistyped URL (ADR 0057).
  """

  defexception message: "Not Found", plug_status: 404
end
