defmodule Baudrate.Content.Tags do
  @moduledoc """
  Article tag extraction, syncing, and querying.

  Hashtags are extracted from article bodies and stored as `ArticleTag`
  records. Supports tag-based article browsing and prefix search.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Pagination

  alias Baudrate.Content.{
    Article,
    ArticleTag,
    Board,
    BoardArticle,
    Filters
  }

  @per_page 20
  @hashtag_re ~r/(?:^|(?<=\s|[^\w&]))#(\p{L}[\w]{0,63})/u

  @doc """
  Extracts hashtag strings from text.

  Strips code blocks and inline code before scanning. Returns a list of
  unique lowercase tag strings.

  ## Examples

      iex> Baudrate.Content.extract_tags("Hello #Elixir and #Phoenix!")
      ["elixir", "phoenix"]

      iex> Baudrate.Content.extract_tags("`#not_a_tag`")
      []
  """
  @spec extract_tags(String.t() | nil) :: [String.t()]
  def extract_tags(nil), do: []
  def extract_tags(""), do: []

  def extract_tags(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/```[\s\S]*?```/u, "")
      |> String.replace(~r/`[^`]+`/, "")

    Regex.scan(@hashtag_re, cleaned, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  @doc """
  Syncs article_tags for the given article based on its body.

  Extracts hashtags from the body, compares with existing tags in the DB,
  inserts new ones and deletes removed ones. Returns `:ok`.
  """
  @spec sync_article_tags(%Article{}) :: :ok
  def sync_article_tags(%Article{} = article) do
    new_tags = extract_tags(article.body)

    existing_tags =
      from(at in ArticleTag, where: at.article_id == ^article.id, select: at.tag)
      |> Repo.all()

    to_add = new_tags -- existing_tags
    to_remove = existing_tags -- new_tags

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if to_add != [] do
      entries =
        Enum.map(to_add, fn tag ->
          %{article_id: article.id, tag: tag, inserted_at: now}
        end)

      Repo.insert_all(ArticleTag, entries, on_conflict: :nothing)
    end

    if to_remove != [] do
      from(at in ArticleTag, where: at.article_id == ^article.id and at.tag in ^to_remove)
      |> Repo.delete_all()
    end

    :ok
  end

  @doc """
  Lists articles matching a given tag, with pagination.

  Respects board visibility, mute/block filters, and excludes soft-deleted
  articles. Articles are ordered newest first with user and boards preloaded.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — articles per page (default #{@per_page})
    * `:user` — current user (nil for guests)

  Returns `%{articles, total, page, per_page, total_pages}`.
  """
  def articles_by_tag(tag, opts \\ []) do
    pagination = Pagination.paginate_opts(opts, @per_page)
    user = Keyword.get(opts, :user)
    allowed_roles = Filters.allowed_view_roles(user)
    {hidden_uids, hidden_ap_ids} = Filters.hidden_filters(user)

    base_query =
      from(a in Article,
        join: at in ArticleTag,
        on: at.article_id == a.id,
        join: ba in BoardArticle,
        on: ba.article_id == a.id,
        join: b in Board,
        on: b.id == ba.board_id,
        where: at.tag == ^tag and is_nil(a.deleted_at) and b.min_role_to_view in ^allowed_roles,
        distinct: a.id
      )
      |> Filters.apply_hidden_filters(hidden_uids, hidden_ap_ids)

    Pagination.paginate_query(base_query, pagination,
      result_key: :articles,
      order_by: [desc: dynamic([q], q.inserted_at)],
      preloads: [:user, :remote_actor, :boards]
    )
  end

  @doc """
  Searches for tags matching a prefix.

  Returns up to `limit` distinct tag strings sorted alphabetically.

  ## Options

    * `:limit` — max results (default 10)
  """
  @spec search_tags(String.t(), keyword()) :: [String.t()]
  def search_tags(prefix, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    pattern = Filters.sanitize_like(String.downcase(prefix)) <> "%"

    from(at in ArticleTag,
      where: like(at.tag, ^pattern),
      group_by: at.tag,
      order_by: at.tag,
      limit: ^limit,
      select: at.tag
    )
    |> Repo.all()
  end
end
