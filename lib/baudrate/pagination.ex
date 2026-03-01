defmodule Baudrate.Pagination do
  @moduledoc """
  Shared pagination helpers for paginated queries across all contexts.

  Extracts the repeated count-paginate-wrap pattern used by Content,
  Auth, Moderation, and Notification contexts.
  """

  import Ecto.Query
  alias Baudrate.Repo

  @doc """
  Extracts pagination options from a keyword list.

  Returns `{page, per_page, offset}` where `page` is at least 1.

  ## Options

    * `:page` — page number (default 1, clamped to min 1)
    * `:per_page` — items per page (default `default_per_page`)
    * `:max_per_page` — maximum allowed per_page (optional, clamps value)

  ## Examples

      iex> Baudrate.Pagination.paginate_opts([page: 3, per_page: 10], 20)
      {3, 10, 20}

      iex> Baudrate.Pagination.paginate_opts([], 20)
      {1, 20, 0}

      iex> Baudrate.Pagination.paginate_opts([page: -1], 20)
      {1, 20, 0}

      iex> Baudrate.Pagination.paginate_opts([per_page: 100], 20, max_per_page: 50)
      {1, 50, 0}
  """
  @spec paginate_opts(keyword(), pos_integer(), keyword()) ::
          {pos_integer(), pos_integer(), non_neg_integer()}
  def paginate_opts(opts, default_per_page, extra_opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = Keyword.get(opts, :per_page, default_per_page)

    per_page =
      case Keyword.get(extra_opts, :max_per_page) do
        nil -> per_page
        max_pp -> min(per_page, max_pp)
      end

    offset = (page - 1) * per_page
    {page, per_page, offset}
  end

  @doc """
  Counts total matching records from a base query, fetches a page of
  results, and returns a pagination result map.

  The `base_query` should include all joins, where clauses, distinct,
  and filters but NO order_by, offset, limit, or preload — those are
  composed on by this function.

  ## Options

    * `:result_key` (required) — atom key for the results list (e.g. `:articles`)
    * `:order_by` (required) — order clause (keyword list or dynamic)
    * `:preloads` (required) — associations to preload (list)

  ## Returns

      %{
        result_key => [results],
        total: integer,
        page: integer,
        per_page: integer,
        total_pages: integer
      }
  """
  @spec paginate_query(
          Ecto.Query.t(),
          {pos_integer(), pos_integer(), non_neg_integer()},
          keyword()
        ) ::
          map()
  def paginate_query(base_query, {page, per_page, offset}, opts) do
    result_key = Keyword.fetch!(opts, :result_key)
    order = Keyword.fetch!(opts, :order_by)
    preloads = Keyword.fetch!(opts, :preloads)

    total = Repo.one(from(q in subquery(base_query), select: count()))

    results =
      base_query
      |> order_by(^order)
      |> offset(^offset)
      |> limit(^per_page)
      |> preload(^preloads)
      |> Repo.all()

    total_pages = max(ceil(total / per_page), 1)

    %{
      result_key => results,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: total_pages
    }
  end
end
