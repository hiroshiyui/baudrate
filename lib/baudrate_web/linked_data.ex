defmodule BaudrateWeb.LinkedData do
  @moduledoc """
  Builds JSON-LD and Dublin Core metadata for embedding in HTML `<head>`.

  Describes Baudrate entities (site, boards, articles, users) using standard
  RDF vocabularies — SIOC, FOAF, and Dublin Core — so search engines, crawlers,
  and linked-data consumers can understand the data relationships.

  ## Vocabularies

  | Prefix     | URI                                | Used for                              |
  |------------|------------------------------------|---------------------------------------|
  | `sioc`     | `http://rdfs.org/sioc/ns#`         | Site, Forum, Post, UserAccount        |
  | `foaf`     | `http://xmlns.com/foaf/0.1/`       | Person, name, nick, depiction         |
  | `dc`       | `http://purl.org/dc/elements/1.1/` | title, creator, date, description     |
  | `dcterms`  | `http://purl.org/dc/terms/`        | created, modified                     |

  ## Usage

  Each builder function returns a plain map suitable for `Jason.encode!/1`.
  LiveViews call the relevant builder in `mount/3`, encode the result, and
  assign `linked_data_json` (+ optionally `dc_meta`) to the socket.
  The root layout renders them as `<script type="application/ld+json">` and
  `<meta name="DC.*">` tags.
  """

  alias Baudrate.Avatar
  alias Baudrate.Content
  alias Baudrate.Sanitizer.Native, as: Sanitizer
  alias BaudrateWeb.Helpers

  @context %{
    "sioc" => "http://rdfs.org/sioc/ns#",
    "foaf" => "http://xmlns.com/foaf/0.1/",
    "dc" => "http://purl.org/dc/elements/1.1/",
    "dcterms" => "http://purl.org/dc/terms/"
  }

  @doc """
  Builds a `sioc:Site` JSON-LD map for the homepage.

  ## Parameters

    * `site_name` — the configured site name string

  ## Example

      iex> BaudrateWeb.LinkedData.site_jsonld("My BBS")
      %{"@context" => ..., "@type" => "sioc:Site", ...}
  """
  @spec site_jsonld(String.t()) :: map()
  def site_jsonld(site_name) do
    base = base_url()

    %{
      "@context" => @context,
      "@type" => "sioc:Site",
      "@id" => base <> "/",
      "sioc:name" => site_name || "Baudrate",
      "foaf:name" => site_name || "Baudrate",
      "foaf:homepage" => base <> "/"
    }
  end

  @doc """
  Builds a `sioc:Forum` JSON-LD map for a board page.

  ## Parameters

    * `board` — a `%Board{}` struct
    * `opts` — keyword options:
      * `:parent_slug` — slug of the parent board (for `sioc:has_parent`)

  ## Example

      iex> BaudrateWeb.LinkedData.board_jsonld(board, parent_slug: "general")
      %{"@context" => ..., "@type" => "sioc:Forum", ...}
  """
  @spec board_jsonld(struct(), keyword()) :: map()
  def board_jsonld(board, opts \\ []) do
    base = base_url()

    data = %{
      "@context" => @context,
      "@type" => "sioc:Forum",
      "@id" => base <> "/boards/#{board.slug}",
      "sioc:name" => board.name,
      "dc:title" => board.name,
      "sioc:has_host" => %{"@id" => base <> "/"}
    }

    data =
      if board.description && board.description != "" do
        Map.put(data, "dc:description", board.description)
      else
        data
      end

    parent_slug = Keyword.get(opts, :parent_slug)

    if parent_slug do
      Map.put(data, "sioc:has_parent", %{"@id" => base <> "/boards/#{parent_slug}"})
    else
      data
    end
  end

  @doc """
  Builds a `sioc:Post` JSON-LD map for an article page.

  Expects the article to have `:user` and `:boards` preloaded.

  ## Parameters

    * `article` — a `%Article{}` struct (preloaded with `:user`, `:boards`)

  ## Example

      iex> BaudrateWeb.LinkedData.article_jsonld(article)
      %{"@context" => ..., "@type" => "sioc:Post", ...}
  """
  @spec article_jsonld(struct()) :: map()
  def article_jsonld(article) do
    base = base_url()
    comment_count = Content.count_comments_for_article(article)

    data = %{
      "@context" => @context,
      "@type" => "sioc:Post",
      "@id" => base <> "/articles/#{article.slug}",
      "dc:title" => article.title,
      "dcterms:created" => format_iso8601(article.inserted_at),
      "dcterms:modified" => format_iso8601(article.updated_at),
      "sioc:num_replies" => comment_count
    }

    data =
      if article.user do
        creator_name = Helpers.display_name(article.user)

        data
        |> Map.put("dc:creator", creator_name)
        |> Map.put("sioc:has_creator", %{
          "@type" => "foaf:Person",
          "@id" => base <> "/users/#{article.user.username}",
          "foaf:name" => creator_name,
          "foaf:nick" => article.user.username
        })
      else
        data
      end

    data =
      if article.boards && article.boards != [] do
        containers =
          Enum.map(article.boards, fn board ->
            %{"@id" => base <> "/boards/#{board.slug}"}
          end)

        Map.put(data, "sioc:has_container", containers)
      else
        data
      end

    data =
      if article.body do
        description = excerpt(article.body)

        if description != "" do
          Map.put(data, "dc:description", description)
        else
          data
        end
      else
        data
      end

    data
  end

  @doc """
  Builds a `foaf:Person` + `sioc:UserAccount` JSON-LD map for a user profile page.

  ## Parameters

    * `user` — a `%User{}` struct

  ## Example

      iex> BaudrateWeb.LinkedData.user_jsonld(user)
      %{"@context" => ..., "@type" => ["foaf:Person", "sioc:UserAccount"], ...}
  """
  @spec user_jsonld(struct()) :: map()
  def user_jsonld(user) do
    base = base_url()
    display = Helpers.display_name(user)

    data = %{
      "@context" => @context,
      "@type" => ["foaf:Person", "sioc:UserAccount"],
      "@id" => base <> "/users/#{user.username}",
      "foaf:name" => display,
      "foaf:nick" => user.username,
      "foaf:homepage" => base <> "/users/#{user.username}"
    }

    if user.avatar_id do
      avatar_path = Avatar.avatar_url(user.avatar_id, 48)
      Map.put(data, "foaf:depiction", base <> avatar_path)
    else
      data
    end
  end

  @doc """
  Returns Dublin Core `<meta>` tag tuples for a given entity type.

  ## Parameters

    * `type` — `:board`, `:article`, or `:user`
    * `entity` — the corresponding struct

  ## Returns

  A list of `{name, content}` tuples, e.g. `[{"DC.title", "General"}]`.
  """
  @spec dublin_core_meta(atom(), struct()) :: [{String.t(), String.t()}]
  def dublin_core_meta(:board, board) do
    meta = [{"DC.title", board.name}]

    if board.description && board.description != "" do
      meta ++ [{"DC.description", board.description}]
    else
      meta
    end
  end

  def dublin_core_meta(:article, article) do
    meta = [
      {"DC.title", article.title},
      {"DC.date", format_iso8601(article.inserted_at)},
      {"DC.type", "Text"}
    ]

    meta =
      if article.user do
        meta ++ [{"DC.creator", Helpers.display_name(article.user)}]
      else
        meta
      end

    if article.body do
      desc = excerpt(article.body)

      if desc != "" do
        meta ++ [{"DC.description", desc}]
      else
        meta
      end
    else
      meta
    end
  end

  def dublin_core_meta(:user, user) do
    [{"DC.title", Helpers.display_name(user)}]
  end

  @doc """
  Encodes a JSON-LD map to a JSON string safe for embedding in `<script>`.

  Escapes `</script>` sequences to prevent XSS via script injection.
  """
  @spec encode_jsonld(map()) :: String.t()
  def encode_jsonld(data) do
    data
    |> Jason.encode!()
    |> String.replace("</", "<\\/")
  end

  # --- Private ---

  defp base_url, do: BaudrateWeb.Endpoint.url()

  defp format_iso8601(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.to_iso8601()
    |> Kernel.<>("Z")
  end

  defp format_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_iso8601(nil), do: nil

  defp excerpt(text) do
    text
    |> Sanitizer.strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> then(fn plain ->
      if String.length(plain) > 200 do
        String.slice(plain, 0, 200) <> "…"
      else
        plain
      end
    end)
  end
end
