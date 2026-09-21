defmodule Baudrate.Content.Search do
  @moduledoc """
  Full-text search across articles, comments, and boards.

  Supports PostgreSQL `websearch_to_tsquery` for English text and
  trigram `ILIKE` for CJK queries. Articles and comments both support the
  operator syntax parsed by `Baudrate.Content.SearchQuery` (author, board,
  tag, has, before, after).

  ## A search needs a scope

  `search_articles/2` and `search_comments/2` answer with an empty page when
  `SearchQuery.scoped?/1` is false — when the query names no words, no author,
  no board and no tag. A date range on its own is not a search: newest-first
  it returns everything the viewer can see, which is the cross-board river
  [ADR 0055](../../../doc/adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md)
  refused, reachable from the search box. The check lives **here** rather than
  in `BaudrateWeb.SearchLive` because this module also backs the
  unauthenticated `/ap/search`, and because a rule enforced at the page is one
  the next caller forgets.

  ## Ordering

  `:sort` is one of `:relevance` (the default), `:newest` or `:oldest`.
  Relevance is the reader's own query ranked, which is why
  [ADR 0054](../../../doc/adr/0054-attention-follows-the-board-not-a-ranking.md)
  exempts search from the no-ranking rule: *"the query and the ordering are
  the reader's"*. It is **not** an engagement signal, and must never become
  one — no like, boost, comment or view count belongs in an order clause here.

  | Query | Relevance is |
  |-------|--------------|
  | English article | `ts_rank` over the weighted `search_vector` (title `A`, body `B`) |
  | CJK article | `word_similarity` against the title |
  | Comment | `word_similarity` against the body |

  Two things every order clause here must keep:

    * **A trailing `id` tiebreaker.** `ts_rank` ties are ordinary, and OFFSET
      paging over a tied order shows one row twice and skips another.
    * **No `distinct` in the query it orders.** Ecto compiles `distinct: c.id`
      to `DISTINCT ON (c0."id")` and PostgreSQL requires those expressions to
      lead the `ORDER BY`, so Ecto prepends them — which silently *replaces*
      the requested order with `id` ascending. Comment search was written that
      way and returned oldest-first for its whole life while asking for
      newest-first. The board gate is an `exists` subquery instead, so no row
      is duplicated and nothing needs de-duplicating.
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
    Permissions,
    SearchQuery
  }

  @per_page 20
  @sorts [:relevance, :newest, :oldest]
  @default_sort :relevance

  @doc """
  The sort options this module accepts, in the order a control should offer
  them. The first is the default.
  """
  @spec sorts() :: [atom()]
  def sorts, do: @sorts

  @doc """
  Searches boards by name or slug (ILIKE), filtered to boards the user can post in.
  """
  def search_boards(query, user) when is_binary(query) do
    sanitized = "%" <> Filters.sanitize_like(query) <> "%"

    from(b in Board,
      where: ilike(b.name, ^sanitized) or ilike(b.slug, ^sanitized),
      order_by: [asc: b.position, asc: b.name]
    )
    |> Repo.all()
    |> Enum.filter(&Permissions.can_post_in_board?(&1, user))
  end

  @doc """
  Searches boards by name and description, filtered by view permissions.

  Returns a paginated result map with `:boards`, `:total`, `:page`,
  `:per_page`, and `:total_pages`.

  Deliberately takes no `:sort`: the order is `Board.position`, which is the
  admin's arrangement (ADR 0054), and a board's name is not a relevance
  question.

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

  Only searches non-deleted articles in boards the user can view. A query with
  no scope returns an empty page — see the moduledoc.

  ## Search Operators

  The query string supports the operators in `Baudrate.Content.SearchQuery`:

  | Operator | Example | Semantics |
  |----------|---------|-----------|
  | `author:username` | `author:alice` | Filter by author (case-insensitive). Multiple = OR. |
  | `board:slug` | `board:general` | Filter by board slug. Multiple = OR. |
  | `tag:tagname` | `tag:elixir` | Filter by tag (lowercase). Multiple = AND. |
  | `has:images` | `has:images` | Articles with attached images. |
  | `before:YYYY-MM-DD` | `before:2026-01-15` | Articles before end of that day (exclusive). |
  | `after:YYYY-MM-DD` | `after:2026-01-01` | Articles on or after that day (inclusive). |

  Remaining text after operator extraction is used as the free-text search term.
  If no free text remains there is nothing to rank, so `:relevance` falls back
  to newest-first.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — articles per page (default #{@per_page})
    * `:user` — current user (nil for guests)
    * `:sort` — `:relevance` (default), `:newest` or `:oldest`
    * `:federated_only` — also require `ap_enabled` on the board (default
      `false`); see below

  Returns `%{articles, total, page, per_page, total_pages}`.

  ## `:federated_only`

  This function backs two surfaces with different rules. The site's own search
  (`SearchLive`) must list an article in any board the viewer can open, whether
  or not that board federates — turning federation off is not meant to hide
  content from the site. The unauthenticated `/ap/search`
  (`Federation.Collections.search_collection/2`) serves each result as a full
  Article object stamped `as:Public`, so it needs the *whole* outbound gate:
  `min_role_to_view == "guest"` **and** `ap_enabled`, the same predicate
  `ActivityPubController.publicly_servable?/1` applies to
  `GET /ap/articles/:slug`. Without it, an article in a guest-readable board
  whose federation an admin had switched off was still served — with its title,
  body and attachments — to anyone who guessed a search term, while its own
  permalink answered 404.

  The condition belongs in the query rather than in a filter over the results:
  `search_collection/2` reports `totalItems` and pages from the same result, so
  a post-filter would advertise a count the pages could not fill. That caller
  also pins `sort: :newest`, because an `OrderedCollection` is
  reverse-chronological by contract and its pages must stay stable for a
  crawler across a change of default here.
  """
  def search_articles(query_string, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)
    user = Keyword.get(opts, :user)
    federated_only = Keyword.get(opts, :federated_only, false)
    sort = sort_option(opts)

    {text_query, operators} = SearchQuery.parse(query_string)

    if SearchQuery.scoped?(query_string) do
      allowed_roles = Filters.allowed_view_roles(user)
      {hidden_uids, hidden_ap_ids} = Filters.hidden_filters(user)

      base_query =
        from(a in Article,
          as: :article,
          where: is_nil(a.deleted_at),
          where: ^article_text_clause(text_query),
          where:
            exists(
              from(ba in BoardArticle,
                join: b in Board,
                on: b.id == ba.board_id,
                where:
                  ba.article_id == parent_as(:article).id and
                    b.min_role_to_view in ^allowed_roles and
                    (not (^federated_only) or b.ap_enabled)
              )
            )
        )
        |> apply_search_operators(operators)
        |> Filters.apply_hidden_filters(hidden_uids, hidden_ap_ids)
        |> Filters.exclude_unservable_remote()

      Pagination.paginate_query(base_query, pagination,
        result_key: :articles,
        order_by: article_order(sort, text_query),
        preloads: [:user, :remote_actor, :boards]
      )
    else
      empty_page(:articles, pagination)
    end
  end

  @doc """
  The order clause a given surface and sort produce, exposed so a test can
  assert the `id` tiebreaker is still on the end of it.

  A behavioural test cannot prove its absence: with a handful of tied rows
  PostgreSQL returns a consistent order anyway, and the day it stops is the
  day a reader silently loses a result between two pages. So this is checked
  structurally instead.
  """
  @spec order_for(:articles | :comments, atom(), String.t()) :: keyword()
  def order_for(:articles, sort, text_query), do: article_order(sort_value(sort), text_query)
  def order_for(:comments, sort, text_query), do: comment_order(sort_value(sort), text_query)

  defp sort_value(sort) when sort in @sorts, do: sort
  defp sort_value(_sort), do: @default_sort

  defp article_text_clause(""), do: dynamic([a], true)

  defp article_text_clause(text_query) do
    if Filters.contains_cjk?(text_query) do
      pattern = "%#{Filters.sanitize_like(text_query)}%"
      dynamic([a], ilike(a.title, ^pattern) or ilike(a.body, ^pattern))
    else
      dynamic(
        [a],
        fragment("?.search_vector @@ websearch_to_tsquery('english', ?)", a, ^text_query)
      )
    end
  end

  defp article_order(:oldest, _text_query),
    do: [asc: dynamic([a], a.inserted_at), asc: dynamic([a], a.id)]

  defp article_order(:newest, _text_query), do: article_newest()

  defp article_order(:relevance, ""), do: article_newest()

  defp article_order(:relevance, text_query),
    do: [{:desc, article_rank(text_query)} | article_newest()]

  defp article_newest, do: [desc: dynamic([a], a.inserted_at), desc: dynamic([a], a.id)]

  # The raw query text goes in as a bound parameter, never into a LIKE
  # pattern, so it is deliberately not run through `sanitize_like/1` — the
  # escapes would be scored as part of the term.
  defp article_rank(text_query) do
    if Filters.contains_cjk?(text_query) do
      dynamic([a], fragment("word_similarity(?, ?)", ^text_query, a.title))
    else
      dynamic(
        [a],
        fragment("ts_rank(?.search_vector, websearch_to_tsquery('english', ?))", a, ^text_query)
      )
    end
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
    from(a in query,
      where:
        exists(
          from(ba in BoardArticle,
            join: b in Board,
            on: b.id == ba.board_id,
            where: ba.article_id == parent_as(:article).id and b.slug in ^slugs
          )
        )
    )
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
    from(a in query, where: a.inserted_at < ^end_of_day(date))
  end

  defp maybe_apply_after(query, nil), do: query

  defp maybe_apply_after(query, %Date{} = date) do
    from(a in query, where: a.inserted_at >= ^start_of_day(date))
  end

  @doc """
  Full-text search across comments by body.

  Uses trigram `ILIKE` for both CJK and English queries (comments have no
  tsvector column). Only searches non-deleted comments on non-deleted articles
  in boards the user can view, and a query with no scope returns an empty page
  — see the moduledoc.

  ## Search Operators

  The same six operators as `search_articles/2`, read against the comment and
  the article it is on:

  | Operator | On a comment |
  |----------|--------------|
  | `author:` | the comment's **local** author — a remote commenter has no local username, so `author:` never matches one |
  | `board:` | a board the parent article is in |
  | `tag:` | a tag on the parent article |
  | `has:images` | the comment has images of its own |
  | `before:` / `after:` | the comment's own date, not the article's |

  `board:` and `tag:` narrow and never widen: the view gate in the base query
  still decides what is reachable at all.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — comments per page (default #{@per_page})
    * `:user` — current user (nil for guests)
    * `:sort` — `:relevance` (default), `:newest` or `:oldest`

  Returns `%{comments, total, page, per_page, total_pages}`.
  """
  def search_comments(query_string, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)
    user = Keyword.get(opts, :user)
    sort = sort_option(opts)

    {text_query, operators} = SearchQuery.parse(query_string)

    if SearchQuery.scoped?(query_string) do
      allowed_roles = Filters.allowed_view_roles(user)
      {hidden_uids, hidden_ap_ids} = Filters.hidden_filters(user)

      base_query =
        from(c in Comment,
          as: :comment,
          join: a in Article,
          on: a.id == c.article_id,
          as: :article,
          where: is_nil(c.deleted_at) and is_nil(a.deleted_at),
          where: ^comment_text_clause(text_query),
          # The board gate is an `exists` rather than a join so that no comment
          # is duplicated by a cross-posted article — a `distinct` here would
          # take over the ORDER BY. See the moduledoc.
          where:
            exists(
              from(ba in BoardArticle,
                join: b in Board,
                on: b.id == ba.board_id,
                where:
                  ba.article_id == parent_as(:article).id and
                    b.min_role_to_view in ^allowed_roles
              )
            ),
          # A public remote reply to a followers-only remote article would
          # otherwise surface that article's title through the preload.
          where: is_nil(a.remote_actor_id) or a.visibility in ["public", "unlisted"],
          where:
            is_nil(a.remote_actor_id) or
              a.remote_actor_id not in subquery(Filters.hidden_actor_ids())
        )
        |> apply_comment_operators(operators)
        |> Filters.apply_hidden_filters(hidden_uids, hidden_ap_ids)
        |> Filters.exclude_unservable_remote()

      Pagination.paginate_query(base_query, pagination,
        result_key: :comments,
        order_by: comment_order(sort, text_query),
        preloads: [:user, :remote_actor, article: :boards]
      )
    else
      empty_page(:comments, pagination)
    end
  end

  defp comment_text_clause(""), do: dynamic([c], true)

  defp comment_text_clause(text_query) do
    pattern = "%#{Filters.sanitize_like(text_query)}%"
    dynamic([c], ilike(c.body, ^pattern))
  end

  defp comment_order(:oldest, _text_query),
    do: [asc: dynamic([c], c.inserted_at), asc: dynamic([c], c.id)]

  defp comment_order(:newest, _text_query), do: comment_newest()

  defp comment_order(:relevance, ""), do: comment_newest()

  defp comment_order(:relevance, text_query) do
    rank = dynamic([c], fragment("word_similarity(?, ?)", ^text_query, c.body))
    [{:desc, rank} | comment_newest()]
  end

  defp comment_newest, do: [desc: dynamic([c], c.inserted_at), desc: dynamic([c], c.id)]

  defp apply_comment_operators(query, operators) when operators == %{}, do: query

  defp apply_comment_operators(query, operators) do
    query
    |> comment_author_filter(Map.get(operators, "author", []))
    |> comment_board_filter(Map.get(operators, "board", []))
    |> comment_tag_filter(Map.get(operators, "tag", []))
    |> comment_has_filter(Map.get(operators, "has", []))
    |> comment_date_filters(Map.get(operators, "before"), Map.get(operators, "after"))
  end

  defp comment_author_filter(query, []), do: query

  defp comment_author_filter(query, usernames) do
    downcased = Enum.map(usernames, &String.downcase/1)

    from([comment: c] in query,
      join: u in assoc(c, :user),
      where: fragment("lower(?)", u.username) in ^downcased
    )
  end

  defp comment_board_filter(query, []), do: query

  defp comment_board_filter(query, slugs) do
    from(c in query,
      where:
        exists(
          from(ba in BoardArticle,
            join: b in Board,
            on: b.id == ba.board_id,
            where: ba.article_id == parent_as(:article).id and b.slug in ^slugs
          )
        )
    )
  end

  defp comment_tag_filter(query, []), do: query

  defp comment_tag_filter(query, tags) do
    Enum.reduce(tags, query, fn tag, q ->
      downcased = String.downcase(tag)

      from([article: a] in q,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM article_tags WHERE article_id = ? AND tag = ?)",
            a.id,
            ^downcased
          )
      )
    end)
  end

  defp comment_has_filter(query, []), do: query

  defp comment_has_filter(query, has_values) do
    Enum.reduce(has_values, query, fn
      "images", q ->
        from([comment: c] in q,
          where: fragment("EXISTS (SELECT 1 FROM comment_images WHERE comment_id = ?)", c.id)
        )

      _, q ->
        q
    end)
  end

  defp comment_date_filters(query, nil, nil), do: query

  defp comment_date_filters(query, before_date, after_date) do
    query
    |> maybe_comment_before(before_date)
    |> maybe_comment_after(after_date)
  end

  defp maybe_comment_before(query, nil), do: query

  defp maybe_comment_before(query, %Date{} = date) do
    from([comment: c] in query, where: c.inserted_at < ^end_of_day(date))
  end

  defp maybe_comment_after(query, nil), do: query

  defp maybe_comment_after(query, %Date{} = date) do
    from([comment: c] in query, where: c.inserted_at >= ^start_of_day(date))
  end

  # `before:` is exclusive — everything written before that day ended.
  defp end_of_day(%Date{} = date), do: DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")

  # `after:` is inclusive — everything written on that day or later.
  defp start_of_day(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp sort_option(opts), do: sort_value(Keyword.get(opts, :sort, @default_sort))

  defp empty_page(result_key, {page, per_page, _offset}) do
    %{result_key => [], :total => 0, :page => page, :per_page => per_page, :total_pages => 1}
  end
end
