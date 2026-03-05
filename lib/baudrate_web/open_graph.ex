defmodule BaudrateWeb.OpenGraph do
  @moduledoc """
  Builds Open Graph and Twitter Card meta tag tuples for embedding in `<head>`.

  Each builder returns a list of `{property, content}` tuples that the root
  layout renders as `<meta property="og:*">` and `<meta name="twitter:*">` tags.
  Nil-content tags are automatically filtered out.

  ## Usage

  LiveViews call the relevant builder in `mount/3` and assign `og_meta`:

      assign(socket, :og_meta, OpenGraph.article_tags(article, article_images))

  The root layout iterates `@og_meta` to emit the tags.
  """

  use Gettext, backend: BaudrateWeb.Gettext

  alias Baudrate.Avatar
  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.Setup
  alias BaudrateWeb.Helpers
  alias BaudrateWeb.LinkedData

  @default_image "/images/icon-512.png"

  @doc """
  Builds OG/Twitter tags for an article page.

  Uses the first attached image for `og:image` (with `twitter:card` "summary_large_image"),
  falling back to the author's avatar or the default site icon.

  ## Parameters

    * `article` — a `%Article{}` struct (preloaded with `:user`, `:boards`)
    * `article_images` — list of `%ArticleImage{}` structs
  """
  @spec article_tags(struct(), [struct()]) :: [{String.t(), String.t()}]
  def article_tags(article, article_images) do
    base = base_url()
    url = base <> "/articles/#{article.slug}"
    description = LinkedData.excerpt(article.body)
    board = List.first(article.boards || [])

    {image_url, card_type} = article_image(article, article_images, base)

    tags =
      [
        {"og:type", "article"},
        {"og:title", article.title},
        {"og:description", non_empty(description)},
        {"og:url", url},
        {"og:image", image_url},
        {"article:published_time", format_iso8601(article.inserted_at)},
        {"article:modified_time", format_iso8601(article.updated_at)},
        {"article:section", board && board.name},
        {"article:author", article.user && Helpers.display_name(article.user)},
        {"twitter:card", card_type},
        {"twitter:title", article.title},
        {"twitter:description", non_empty(description)},
        {"twitter:image", image_url}
      ]

    common_tags(base) ++ filter_nil(tags)
  end

  @doc """
  Builds OG/Twitter tags for a board page.

  ## Parameters

    * `board` — a `%Board{}` struct
  """
  @spec board_tags(struct()) :: [{String.t(), String.t()}]
  def board_tags(board) do
    base = base_url()
    url = base <> "/boards/#{board.slug}"

    tags =
      [
        {"og:type", "website"},
        {"og:title", board.name},
        {"og:description", non_empty(board.description)},
        {"og:url", url},
        {"og:image", base <> @default_image},
        {"twitter:card", "summary"},
        {"twitter:title", board.name},
        {"twitter:description", non_empty(board.description)},
        {"twitter:image", base <> @default_image}
      ]

    common_tags(base) ++ filter_nil(tags)
  end

  @doc """
  Builds OG/Twitter tags for a user profile page.

  ## Parameters

    * `user` — a `%User{}` struct
    * `article_count` — number of articles by this user
    * `comment_count` — number of comments by this user
  """
  @spec user_tags(struct(), non_neg_integer(), non_neg_integer()) :: [{String.t(), String.t()}]
  def user_tags(user, article_count, comment_count) do
    base = base_url()
    display = Helpers.display_name(user)
    url = base <> "/users/#{user.username}"

    image_url =
      if user.avatar_id do
        base <> Avatar.avatar_url(user.avatar_id, 120)
      else
        base <> @default_image
      end

    description =
      gettext("%{articles} articles, %{comments} comments",
        articles: article_count,
        comments: comment_count
      )

    tags =
      [
        {"og:type", "profile"},
        {"og:title", display},
        {"og:description", description},
        {"og:url", url},
        {"og:image", image_url},
        {"profile:username", user.username},
        {"twitter:card", "summary"},
        {"twitter:title", display},
        {"twitter:description", description},
        {"twitter:image", image_url}
      ]

    common_tags(base) ++ filter_nil(tags)
  end

  @doc """
  Builds OG/Twitter tags for the home page.

  ## Parameters

    * `site_name` — the configured site name string
  """
  @spec home_tags(String.t()) :: [{String.t(), String.t()}]
  def home_tags(site_name) do
    base = base_url()
    description = Setup.get_setting("site_description")

    tags =
      [
        {"og:type", "website"},
        {"og:title", site_name},
        {"og:description", non_empty(description)},
        {"og:url", base <> "/"},
        {"og:image", base <> @default_image},
        {"twitter:card", "summary"},
        {"twitter:title", site_name},
        {"twitter:description", non_empty(description)},
        {"twitter:image", base <> @default_image}
      ]

    common_tags(base) ++ filter_nil(tags)
  end

  @doc """
  Builds minimal OG/Twitter tags as a fallback for pages without specific metadata.

  ## Parameters

    * `page_title` — the page title string
  """
  @spec default_tags(String.t()) :: [{String.t(), String.t()}]
  def default_tags(page_title) do
    base = base_url()

    tags =
      [
        {"og:type", "website"},
        {"og:title", page_title},
        {"og:image", base <> @default_image},
        {"twitter:card", "summary"},
        {"twitter:title", page_title}
      ]

    common_tags(base) ++ filter_nil(tags)
  end

  # --- Private ---

  defp common_tags(base) do
    site_name = Setup.get_setting("site_name") || "Baudrate"
    [{"og:site_name", site_name}, {"og:locale", site_locale(base)}]
  end

  defp site_locale(_base) do
    # Use default locale from config
    Gettext.get_locale(BaudrateWeb.Gettext)
  end

  defp article_image(article, article_images, base) do
    cond do
      article_images != [] ->
        img = List.first(article_images)
        {base <> ArticleImageStorage.image_url(img.filename), "summary_large_image"}

      article.user && article.user.avatar_id ->
        {base <> Avatar.avatar_url(article.user.avatar_id, 120), "summary"}

      true ->
        {base <> @default_image, "summary"}
    end
  end

  defp base_url, do: BaudrateWeb.Endpoint.url()

  defp format_iso8601(%NaiveDateTime{} = ndt) do
    ndt |> NaiveDateTime.to_iso8601() |> Kernel.<>("Z")
  end

  defp format_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_iso8601(nil), do: nil

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(s), do: s

  defp filter_nil(tags) do
    Enum.reject(tags, fn {_property, content} -> is_nil(content) end)
  end
end
