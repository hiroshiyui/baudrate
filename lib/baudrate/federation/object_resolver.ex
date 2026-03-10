defmodule Baudrate.Federation.ObjectResolver do
  @moduledoc """
  Resolves remote ActivityPub objects (articles, notes) by URL.

  Two-phase approach:

  1. `fetch/1` — fetches and parses a remote object for preview display
     (no database write). Returns a map with title, body, author, etc.
  2. `resolve/1` — fetches + materializes as a local remote article for
     interaction (like, boost, forward). Deduplicates by `ap_id`.

  **Loop-safe:** `resolve/1` uses `Content.create_remote_article/3` with
  empty board_ids, which does NOT trigger outbound federation publishing.
  """

  require Logger

  alias Baudrate.Content
  alias Baudrate.Content.TitleDeriver
  alias Baudrate.Federation

  alias Baudrate.Federation.{
    ActorResolver,
    AttachmentExtractor,
    HTTPClient,
    KeyStore,
    Sanitizer,
    Validator,
    Visibility
  }

  @supported_types ["Note", "Article", "Page"]

  @doc """
  Fetches a remote AP object for preview display without storing it.

  Returns `{:ok, preview}` where preview is a map with:
  - `:ap_id` — the object's AP ID
  - `:title` — derived title
  - `:body` — plain text body
  - `:body_html` — sanitized HTML body
  - `:visibility` — derived from to/cc addressing
  - `:url` — source URL for the original post
  - `:published_at` — publication timestamp
  - `:remote_actor` — resolved `%RemoteActor{}` (the author)
  - `:object` — the raw AP object JSON (for later materialization)

  If the object already exists locally as an article, returns
  `{:ok, :existing, article}` instead.
  """
  @spec fetch(String.t()) ::
          {:ok, map()} | {:ok, :existing, %Content.Article{}} | {:error, term()}
  def fetch(url) when is_binary(url) do
    with :ok <- validate_url(url),
         {:dedup, nil} <- {:dedup, Content.get_article_by_ap_id(url)},
         {:ok, object} <- fetch_object(url),
         {:ok, object} <- validate_object(object),
         {:ok, remote_actor} <- resolve_author(object),
         {:ok, body, body_html} <- sanitize_content(object) do
      title = TitleDeriver.derive_title(object, body)
      visibility = Visibility.from_addressing(object)
      image_attachments = AttachmentExtractor.extract_image_attachments(object)

      {:ok,
       %{
         ap_id: object["id"],
         title: title,
         body: body,
         body_html: body_html,
         visibility: visibility,
         url: extract_source_url(object),
         published_at: parse_published(object),
         remote_actor: remote_actor,
         image_attachments: image_attachments,
         object: object
       }}
    else
      {:dedup, %Content.Article{} = article} ->
        {:ok, :existing, Baudrate.Repo.preload(article, [:remote_actor, :user, :boards])}

      {:error, reason} ->
        Logger.warning("federation.object_fetch_failed: url=#{url} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Materializes a remote AP object as a local article for interaction.

  If an article with the same `ap_id` already exists, returns it (dedup).
  Otherwise creates a new remote article with empty board_ids (loop-safe).
  """
  @spec resolve(String.t()) :: {:ok, %Content.Article{}} | {:error, term()}
  def resolve(url) when is_binary(url) do
    with :ok <- validate_url(url),
         {:dedup, nil} <- {:dedup, Content.get_article_by_ap_id(url)},
         {:ok, object} <- fetch_object(url),
         {:ok, object} <- validate_object(object),
         {:ok, remote_actor} <- resolve_author(object),
         {:ok, article} <- materialize(object, remote_actor) do
      {:ok, Baudrate.Repo.preload(article, [:remote_actor, :user, :boards])}
    else
      {:dedup, %Content.Article{} = article} ->
        {:ok, Baudrate.Repo.preload(article, [:remote_actor, :user, :boards])}

      {:error, reason} ->
        Logger.warning("federation.object_resolve_failed: url=#{url} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp validate_url(url) do
    cond do
      not Validator.valid_https_url?(url) -> {:error, :invalid_url}
      Validator.local_actor?(url) -> {:error, :local_url}
      true -> :ok
    end
  end

  defp fetch_object(url) do
    with {:ok, _} <- KeyStore.ensure_site_keypair(),
         {:ok, private_key} <- KeyStore.decrypt_site_private_key() do
      site_uri = Federation.actor_uri(:site, nil)
      key_id = "#{site_uri}#main-key"

      case HTTPClient.signed_get(url, private_key, key_id) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, object} when is_map(object) -> {:ok, object}
            _ -> {:error, :invalid_json}
          end

        {:error, reason} ->
          {:error, {:fetch_failed, reason}}
      end
    end
  end

  defp validate_object(object) do
    type = object["type"]

    cond do
      type not in @supported_types ->
        {:error, {:unsupported_type, type}}

      not is_binary(object["id"]) ->
        {:error, :missing_id}

      true ->
        {:ok, object}
    end
  end

  defp resolve_author(object) do
    case extract_attributed_to(object) do
      nil ->
        {:error, :missing_author}

      author_uri ->
        case ActorResolver.resolve(author_uri) do
          {:ok, actor} -> {:ok, actor}
          {:error, reason} -> {:error, {:author_resolve_failed, reason}}
        end
    end
  end

  defp extract_attributed_to(%{"attributedTo" => attributed_to}) do
    case attributed_to do
      uri when is_binary(uri) -> uri
      [uri | _] when is_binary(uri) -> uri
      [%{"id" => uri} | _] when is_binary(uri) -> uri
      _ -> nil
    end
  end

  defp extract_attributed_to(_), do: nil

  defp materialize(object, remote_actor) do
    with {:ok, body, _body_html} <- sanitize_content(object) do
      ap_id = object["id"]
      title = TitleDeriver.derive_title(object, body)
      slug = Content.generate_slug(title)
      visibility = Visibility.from_addressing(object)
      source_url = extract_source_url(object)
      image_attachments = AttachmentExtractor.extract_image_attachments(object)

      attrs = %{
        title: title,
        body: body,
        slug: slug,
        ap_id: ap_id,
        remote_actor_id: remote_actor.id,
        visibility: visibility,
        url: source_url,
        forwardable: visibility in ["public", "unlisted"]
      }

      # Empty board_ids = no board routing = loop-safe
      case Content.create_remote_article(attrs, [], image_attachments: image_attachments) do
        {:ok, %{article: article}} -> {:ok, article}
        {:error, _} = error -> error
      end
    end
  end

  defp sanitize_content(object) do
    raw_content = extract_body(object)

    case Validator.validate_content_size(raw_content) do
      :ok ->
        body_html = Sanitizer.sanitize(raw_content)
        body = strip_html(raw_content)
        {:ok, body, body_html}

      error ->
        error
    end
  end

  defp extract_body(object) do
    raw =
      case object do
        %{"content" => content} when is_binary(content) and content != "" ->
          content

        %{"source" => %{"content" => source}} when is_binary(source) and source != "" ->
          source

        _ ->
          ""
      end

    prepend_content_warning(raw, object)
  end

  defp prepend_content_warning(body, %{"sensitive" => true, "summary" => summary})
       when is_binary(summary) and summary != "" do
    "[CW: #{summary}]\n\n#{body}"
  end

  defp prepend_content_warning(body, _object), do: body

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>\s*<p[^>]*>/, "\n\n")
    |> Baudrate.Sanitizer.Native.strip_tags()
    |> decode_html_entities()
    |> String.trim()
  end

  defp strip_html(_), do: ""

  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&apos;", "'")
  end

  defp extract_source_url(object) do
    case object do
      %{"url" => url} when is_binary(url) -> url
      %{"url" => [%{"href" => href} | _]} when is_binary(href) -> href
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp parse_published(%{"published" => published}) when is_binary(published) do
    case DateTime.from_iso8601(published) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp parse_published(_), do: DateTime.utc_now() |> DateTime.truncate(:second)
end
