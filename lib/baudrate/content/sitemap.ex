defmodule Baudrate.Content.Sitemap do
  @moduledoc """
  The inventory `sitemap.xml` publishes: which boards, articles and tag pages
  exist for a crawler to fetch.

  **One predicate, and it is the one a guest already sees**
  ([ADR 0057](../../../doc/adr/0057-a-sitemap-invites-only-what-a-guest-sees.md)).
  An article is in the inventory when it is local (`user_id` not nil), not
  soft-deleted, `visibility == "public"`, and in at least one board whose
  `min_role_to_view` is `"guest"` — the same gate the syndication feeds and
  `Board.public?/1` use. A slug here is an existence signal that machines
  copy and repeat, so nothing widens it.

  **What is deliberately absent, because each reads like an oversight:**

    * **Member profiles.** `/users/:name` stays public and crawlable through
      every byline; it is simply not *enumerated*. Nobody opted into a
      machine-readable member list.
    * **Unlisted articles.** The word promises it, and the page carries
      `noindex` to match — a sitemap is an invitation, not a gate.
    * **Remote articles.** They are published on the instance that minted
      them, under that instance's URI.
    * **Private-board content**, which is the whole point of the predicate.

  Tag pages *are* here: [ADR 0055](../../../doc/adr/0055-unanswered-is-a-river-and-tags-is-a-ranking.md)
  refused a `/tags` index on the grounds that an inventory of tags is wanted by
  a crawler, and this is where an inventory belongs. A tag appears only when a
  guest-visible article carries it, so the list cannot become an existence
  signal for a private board.
  """

  import Ecto.Query

  alias Baudrate.Content.{Article, ArticleTag, Board, BoardArticle, Boards}
  alias Baudrate.Repo

  @doc """
  Returns `[{slug, lastmod}]` for every guest-viewable board, ordered by
  position then id.

  `lastmod` comes from `Boards.last_activity_by_board/1` — the same
  last-activity query the home page's board cards use, which shares the unread
  badge's filters — and is `nil` for a board with nothing in it.
  """
  @spec public_boards() :: [{String.t(), DateTime.t() | nil}]
  def public_boards do
    boards =
      from(b in Board,
        where: b.min_role_to_view == "guest",
        order_by: [asc: b.position, asc: b.id],
        select: {b.id, b.slug}
      )
      |> Repo.all()

    activity = boards |> Enum.map(&elem(&1, 0)) |> Boards.last_activity_by_board()

    Enum.map(boards, fn {id, slug} -> {slug, Map.get(activity, id)} end)
  end

  @doc "Counts the articles the sitemap may list."
  @spec count_public_articles() :: non_neg_integer()
  def count_public_articles do
    Repo.one(from(a in public_articles_query(), select: count(a.id))) || 0
  end

  @doc """
  Returns `[{slug, lastmod}]` for one page of the article inventory.

  Ordered by `id` so paging is stable while articles are being written, and
  `lastmod` is `last_activity_at` falling back to `updated_at` — a new comment
  changes the page, so it changes the date a crawler is given.
  """
  @spec public_article_slugs(non_neg_integer(), pos_integer()) ::
          [{String.t(), DateTime.t() | nil}]
  def public_article_slugs(offset, limit) do
    from(a in public_articles_query(),
      order_by: [asc: a.id],
      offset: ^offset,
      limit: ^limit,
      select: {a.slug, type(coalesce(a.last_activity_at, a.updated_at), :utc_datetime)}
    )
    |> Repo.all()
  end

  @doc """
  Returns the newest `lastmod` anywhere in the article inventory, or `nil`.

  The sitemap index uses this as each article page's `<lastmod>`: an upper
  bound on that page's own newest date, which is the safe direction to be
  wrong in — a crawler may refetch a page that has not changed, and is never
  told a changed page is current.
  """
  @spec newest_article_date() :: DateTime.t() | nil
  def newest_article_date do
    Repo.one(
      from(a in public_articles_query(),
        select: type(max(coalesce(a.last_activity_at, a.updated_at)), :utc_datetime)
      )
    )
  end

  @doc """
  Returns every tag carried by an article in the inventory, alphabetically.

  Alphabetical because a sitemap has no ordering semantics and a use-count
  order would be the ranking ADR 0055 refused, written into a machine-readable
  file instead of a page.
  """
  @spec public_tags() :: [String.t()]
  def public_tags do
    from(t in ArticleTag,
      join: a in subquery(public_articles_query()),
      on: a.id == t.article_id,
      distinct: t.tag,
      order_by: [asc: t.tag],
      select: t.tag
    )
    |> Repo.all()
  end

  # The one predicate. Every function above starts here.
  defp public_articles_query do
    from(a in Article,
      as: :article,
      where: is_nil(a.deleted_at),
      where: not is_nil(a.user_id),
      where: a.visibility == "public",
      where:
        exists(
          from(ba in BoardArticle,
            join: b in Board,
            on: b.id == ba.board_id,
            where: ba.article_id == parent_as(:article).id and b.min_role_to_view == "guest",
            select: 1
          )
        )
    )
  end
end
