defmodule Baudrate.Content.Search do
  @moduledoc """
  Full-text search across articles, comments, and boards.

  Supports PostgreSQL `websearch_to_tsquery` for English text and
  trigram `ILIKE` for CJK queries. Article search supports advanced
  operator syntax (author, board, tag, has, before, after).
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Pagination

  alias Baudrate.Content.{
    Article,
    Board,
    BoardArticle,
    Comment,
    Filters,
    Permissions
  }

  @per_page 20

  @doc """
  Searches boards by name (ILIKE), filtered to boards the user can post in.
  """
  def search_boards(query, user) when is_binary(query) do
    sanitized = "%" <> Filters.sanitize_like(query) <> "%"

    from(b in Board, where: ilike(b.name, ^sanitized), order_by: [asc: b.position, asc: b.name])
    |> Repo.all()
    |> Enum.filter(&Permissions.can_post_in_board?(&1, user))
  end

  @doc """
  Searches boards by name and description, filtered by view permissions.

  Returns a paginated result map with `:boards`, `:total`, `:page`,
  `:per_page`, and `:total_pages`.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — boards per page (default #{@per_page})
    * `:user` — current user (nil for guest)
  """
  def search_visible_boards(query_string, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)
    user = Keyword.get(opts, :user)
    allowed_roles = Filters.allowed_view_roles(user)
    pattern = "%" <> Filters.sanitize_like(query_string) <> "%"

    base_query =
      from(b in Board,
        where: b.min_role_to_view in ^allowed_roles,
        where: ilike(b.name, ^pattern) or ilike(coalesce(b.description, ""), ^pattern)
      )

    Pagination.paginate_query(base_query, pagination,
      result_key: :boards,
      order_by: [asc: dynamic([q], q.position), asc: dynamic([q], q.name)],
      preloads: [:parent]
    )
  end

  @doc """
  Full-text search across articles by title and body.

  Uses a dual strategy: PostgreSQL `websearch_to_tsquery` for English text,
  and trigram `ILIKE` for CJK (Chinese, Japanese, Korean) queries. The strategy
  is auto-detected based on whether the query contains CJK characters.

  Only searches non-deleted articles in boards the user can view.

  ## Search Operators

  The query string supports advanced operators (articles tab only):

  | Operator | Example | Semantics |
  |----------|---------|-----------|
  | `author:username` | `author:alice` | Filter by author (case-insensitive). Multiple = OR. |
  | `board:slug` | `board:general` | Filter by board slug. Multiple = OR. |
  | `tag:tagname` | `tag:elixir` | Filter by tag (lowercase). Multiple = AND. |
  | `has:images` | `has:images` | Articles with attached images. |
  | `before:YYYY-MM-DD` | `before:2026-01-15` | Articles before end of that day (exclusive). |
  | `after:YYYY-MM-DD` | `after:2026-01-01` | Articles on or after that day (inclusive). |

  Remaining text after operator extraction is used as the free-text search term.
  If no free text remains, results are ordered by `inserted_at desc`.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — articles per page (default #{@per_page})
    * `:user` — current user (nil for guests)

  Returns `%{articles, total, page, per_page, total_pages}`.
  """
  def search_articles(query_string, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)
    user = Keyword.get(opts, :user)
    allowed_roles = Filters.allowed_view_roles(user)
    {hidden_uids, hidden_ap_ids} = Filters.hidden_filters(user)

    {text_query, operators} = parse_search_query(query_string)

    {where_clause, order_clause} =
      if text_query == "" do
        {dynamic([a], true), [desc: dynamic([a], a.inserted_at), desc: dynamic([a], a.id)]}
      else
        article_search_clauses(text_query)
      end

    base_query =
      from(a in Article,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where: is_nil(a.deleted_at) and b.min_role_to_view in ^allowed_roles,
        where: ^where_clause,
        distinct: a.id
      )
      |> apply_search_operators(operators)
      |> Filters.apply_hidden_filters(hidden_uids, hidden_ap_ids)

    Pagination.paginate_query(base_query, pagination,
      result_key: :articles,
      order_by: order_clause,
      preloads: [:user, :remote_actor, :boards]
    )
  end

  defp article_search_clauses(query_string) do
    if Filters.contains_cjk?(query_string) do
      pattern = "%#{Filters.sanitize_like(query_string)}%"

      where =
        dynamic([a], ilike(a.title, ^pattern) or ilike(a.body, ^pattern))

      order = [desc: dynamic([a], a.inserted_at)]
      {where, order}
    else
      where =
        dynamic(
          [a],
          fragment(
            "?.search_vector @@ websearch_to_tsquery('english', ?)",
            a,
            ^query_string
          )
        )

      order = [
        desc:
          dynamic(
            [a],
            fragment(
              "ts_rank(?.search_vector, websearch_to_tsquery('english', ?))",
              a,
              ^query_string
            )
          ),
        desc: dynamic([a], a.inserted_at)
      ]

      {where, order}
    end
  end

  # Parses operator tokens from a search query string.
  # Returns `{remaining_text, operators_map}` where operators_map uses string keys
  # (never String.to_atom on user input). List operators (author, board, tag, has)
  # accumulate; date operators (before, after) overwrite.
  defp parse_search_query(query_string) do
    operator_re = ~r/\b(author|board|tag|has|before|after):(\S+)/

    {operators, _} =
      Regex.scan(operator_re, query_string)
      |> Enum.reduce({%{}, nil}, fn [_full, key, value], {acc, _} ->
        case key do
          k when k in ["author", "board", "tag", "has"] ->
            {Map.update(acc, k, [value], &(&1 ++ [value])), nil}

          k when k in ["before", "after"] ->
            case Date.from_iso8601(value) do
              {:ok, date} -> {Map.put(acc, k, date), nil}
              _ -> {acc, nil}
            end
        end
      end)

    remaining =
      Regex.replace(operator_re, query_string, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    {remaining, operators}
  end

  defp apply_search_operators(query, operators) when operators == %{}, do: query

  defp apply_search_operators(query, operators) do
    query
    |> apply_author_filter(Map.get(operators, "author", []))
    |> apply_board_filter(Map.get(operators, "board", []))
    |> apply_tag_filter(Map.get(operators, "tag", []))
    |> apply_has_filter(Map.get(operators, "has", []))
    |> apply_date_filters(Map.get(operators, "before"), Map.get(operators, "after"))
  end

  defp apply_author_filter(query, []), do: query

  defp apply_author_filter(query, usernames) do
    downcased = Enum.map(usernames, &String.downcase/1)

    from(a in query,
      join: u in assoc(a, :user),
      where: fragment("lower(?)", u.username) in ^downcased
    )
  end

  defp apply_board_filter(query, []), do: query

  defp apply_board_filter(query, slugs) do
    from([a, ba, b] in query, where: b.slug in ^slugs)
  end

  defp apply_tag_filter(query, []), do: query

  defp apply_tag_filter(query, tags) do
    Enum.reduce(tags, query, fn tag, q ->
      downcased = String.downcase(tag)

      from(a in q,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM article_tags WHERE article_id = ? AND tag = ?)",
            a.id,
            ^downcased
          )
      )
    end)
  end

  defp apply_has_filter(query, []), do: query

  defp apply_has_filter(query, has_values) do
    Enum.reduce(has_values, query, fn
      "images", q ->
        from(a in q,
          where: fragment("EXISTS (SELECT 1 FROM article_images WHERE article_id = ?)", a.id)
        )

      _, q ->
        q
    end)
  end

  defp apply_date_filters(query, nil, nil), do: query

  defp apply_date_filters(query, before_date, after_date) do
    query
    |> maybe_apply_before(before_date)
    |> maybe_apply_after(after_date)
  end

  defp maybe_apply_before(query, nil), do: query

  defp maybe_apply_before(query, %Date{} = date) do
    # Exclusive: articles before end of that day
    next_day = Date.add(date, 1)
    next_day_dt = DateTime.new!(next_day, ~T[00:00:00], "Etc/UTC")
    from(a in query, where: a.inserted_at < ^next_day_dt)
  end

  defp maybe_apply_after(query, nil), do: query

  defp maybe_apply_after(query, %Date{} = date) do
    # Inclusive: articles on or after that day
    start_dt = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    from(a in query, where: a.inserted_at >= ^start_dt)
  end

  @doc """
  Full-text search across comments by body.

  Uses trigram `ILIKE` for both CJK and English queries (comments have no
  tsvector column). Only searches non-deleted comments on non-deleted articles
  in boards the user can view.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — comments per page (default #{@per_page})
    * `:user` — current user (nil for guests)

  Returns `%{comments, total, page, per_page, total_pages}`.
  """
  def search_comments(query_string, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)
    user = Keyword.get(opts, :user)
    allowed_roles = Filters.allowed_view_roles(user)
    {hidden_uids, hidden_ap_ids} = Filters.hidden_filters(user)

    pattern = "%#{Filters.sanitize_like(query_string)}%"

    base_query =
      from(c in Comment,
        join: a in Article,
        on: a.id == c.article_id,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where:
          is_nil(c.deleted_at) and is_nil(a.deleted_at) and
            b.min_role_to_view in ^allowed_roles,
        where: ilike(c.body, ^pattern),
        distinct: c.id
      )
      |> Filters.apply_hidden_filters(hidden_uids, hidden_ap_ids)

    Pagination.paginate_query(base_query, pagination,
      result_key: :comments,
      order_by: [desc: dynamic([q], q.inserted_at)],
      preloads: [:user, :remote_actor, article: :boards]
    )
  end
end
