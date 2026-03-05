defmodule Baudrate.Content.LinkPreview.Fetcher do
  @moduledoc """
  Fetches and parses Open Graph / Twitter Card metadata from URLs.

  Flow:
    1. Check domain against `DomainBlockCache`
    2. Check DB for existing cached preview (7-day TTL, 24-hour failed retry delay)
    3. Check rate limits (per-domain + per-user)
    4. Fetch HTML via `HTTPClient`
    5. Parse OG/Twitter/fallback metadata with Floki
    6. Proxy image if present (re-encode to WebP)
    7. Upsert `LinkPreview` record
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Content.LinkPreview
  alias Baudrate.Content.LinkPreview.ImageProxy
  alias Baudrate.Federation.HTTPClient
  alias Baudrate.Federation.Validator
  alias Baudrate.Repo
  alias Baudrate.Sanitizer.Native, as: Sanitizer
  alias BaudrateWeb.RateLimits

  @stale_days 7
  @failed_retry_hours 24

  @doc """
  Fetches or retrieves a cached link preview for the given URL.

  Returns `{:ok, %LinkPreview{}}` or `{:error, reason}`.
  """
  @spec fetch_or_get(String.t(), integer() | nil) :: {:ok, LinkPreview.t()} | {:error, atom()}
  def fetch_or_get(url, user_id \\ nil) do
    url_hash = LinkPreview.hash_url(url)
    domain = extract_domain(url)

    with :ok <- check_domain_block(domain),
         {:cache, nil} <- {:cache, check_cache(url_hash)},
         :ok <- check_rate_limits(domain, user_id),
         {:ok, metadata} <- fetch_metadata(url),
         {:ok, image_path} <- maybe_proxy_image(metadata[:image_url], url_hash),
         {:ok, preview} <- upsert_preview(url, url_hash, domain, metadata, image_path) do
      {:ok, preview}
    else
      {:cache, %LinkPreview{} = cached} ->
        {:ok, cached}

      {:error, reason} ->
        # Record the failure
        upsert_failed(url, url_hash, domain, to_string(reason))
        {:error, reason}
    end
  end

  @doc """
  Re-fetches a stale preview and updates it in place.

  Returns `{:ok, updated_preview}` or `{:error, reason}`.
  """
  @spec refetch(LinkPreview.t()) :: {:ok, LinkPreview.t()} | {:error, atom()}
  def refetch(%LinkPreview{} = preview) do
    case fetch_metadata(preview.url) do
      {:ok, metadata} ->
        old_image_path = preview.image_path
        url_hash = preview.url_hash

        {:ok, image_path} = maybe_proxy_image(metadata[:image_url], url_hash)

        # Delete old image if it changed
        if old_image_path && old_image_path != image_path do
          ImageProxy.delete_image(old_image_path)
        end

        preview
        |> LinkPreview.fetched_changeset(%{
          title: metadata[:title],
          description: metadata[:description],
          image_url: metadata[:image_url],
          site_name: metadata[:site_name],
          image_path: image_path,
          status: "fetched",
          error: nil
        })
        |> Repo.update()

      {:error, reason} ->
        # Delete cached image on failure
        ImageProxy.delete_image(preview.image_path)

        preview
        |> LinkPreview.fetched_changeset(%{
          status: "failed",
          error: to_string(reason),
          image_path: nil
        })
        |> Repo.update()
    end
  end

  # --- Private ---

  defp check_domain_block(nil), do: :ok

  defp check_domain_block(domain) do
    if Validator.domain_blocked?(domain), do: {:error, :domain_blocked}, else: :ok
  end

  defp check_cache(url_hash) do
    case Repo.one(from(lp in LinkPreview, where: lp.url_hash == ^url_hash)) do
      %LinkPreview{status: "fetched", fetched_at: fetched_at} = preview ->
        if DateTime.diff(DateTime.utc_now(), fetched_at, :day) < @stale_days do
          preview
        else
          nil
        end

      %LinkPreview{status: "failed", fetched_at: fetched_at} = preview ->
        if DateTime.diff(DateTime.utc_now(), fetched_at, :hour) < @failed_retry_hours do
          preview
        else
          nil
        end

      %LinkPreview{status: "pending"} = preview ->
        preview

      nil ->
        nil
    end
  end

  defp check_rate_limits(domain, user_id) do
    with :ok <- maybe_check_domain_rate(domain),
         :ok <- maybe_check_user_rate(user_id) do
      :ok
    end
  end

  defp maybe_check_domain_rate(nil), do: :ok
  defp maybe_check_domain_rate(domain), do: RateLimits.check_link_preview_domain(domain)

  defp maybe_check_user_rate(nil), do: :ok
  defp maybe_check_user_rate(user_id), do: RateLimits.check_link_preview_user(user_id)

  defp fetch_metadata(url) do
    case HTTPClient.get_html(url) do
      {:ok, %{body: body, headers: headers}} ->
        if html_content_type?(headers) do
          {:ok, parse_og_metadata(body, url)}
        else
          {:error, :not_html}
        end

      {:ok, %{body: body}} ->
        {:ok, parse_og_metadata(body, url)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp html_content_type?(headers) when is_map(headers) do
    case Map.get(headers, "content-type") do
      [ct | _] -> String.contains?(ct, "text/html") or String.contains?(ct, "application/xhtml")
      _ -> true
    end
  end

  defp html_content_type?(_), do: true

  defp parse_og_metadata(html, _url) do
    case Floki.parse_document(html) do
      {:ok, tree} ->
        %{
          title: find_title(tree),
          description: find_description(tree),
          image_url: find_image(tree),
          site_name: find_meta(tree, "og:site_name")
        }
        |> sanitize_metadata()

      _ ->
        %{}
    end
  end

  defp find_title(tree) do
    find_meta(tree, "og:title") ||
      find_meta_name(tree, "twitter:title") ||
      find_tag_text(tree, "title")
  end

  defp find_description(tree) do
    find_meta(tree, "og:description") ||
      find_meta_name(tree, "twitter:description") ||
      find_meta_name(tree, "description")
  end

  defp find_image(tree) do
    find_meta(tree, "og:image") || find_meta_name(tree, "twitter:image")
  end

  defp find_meta(tree, property) do
    selector = "meta[property=\"#{property}\"]"

    case Floki.find(tree, selector) do
      [el | _] -> Floki.attribute(el, "content") |> List.first()
      _ -> nil
    end
  end

  defp find_meta_name(tree, name) do
    selector = "meta[name=\"#{name}\"]"

    case Floki.find(tree, selector) do
      [el | _] -> Floki.attribute(el, "content") |> List.first()
      _ -> nil
    end
  end

  defp find_tag_text(tree, tag) do
    case Floki.find(tree, tag) do
      [el | _] -> Floki.text(el) |> String.trim()
      _ -> nil
    end
  end

  defp sanitize_metadata(metadata) do
    metadata
    |> Map.update(:title, nil, &sanitize_text(&1, 300))
    |> Map.update(:description, nil, &sanitize_text(&1, 1000))
    |> Map.update(:site_name, nil, &sanitize_text(&1, 200))
  end

  defp sanitize_text(nil, _max), do: nil

  defp sanitize_text(text, max) do
    text
    |> Sanitizer.strip_tags()
    |> strip_control_chars()
    |> String.trim()
    |> String.slice(0, max)
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp strip_control_chars(text) do
    String.replace(text, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp maybe_proxy_image(nil, _url_hash), do: {:ok, nil}

  defp maybe_proxy_image(image_url, url_hash) do
    case ImageProxy.proxy_image(image_url, url_hash) do
      {:ok, path} -> {:ok, path}
      {:error, _} -> {:ok, nil}
    end
  end

  defp upsert_preview(url, url_hash, domain, metadata, image_path) do
    attrs = %{
      url: url,
      url_hash: url_hash,
      domain: domain,
      title: metadata[:title],
      description: metadata[:description],
      image_url: metadata[:image_url],
      site_name: metadata[:site_name],
      image_path: image_path,
      status: "fetched",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %LinkPreview{}
    |> Ecto.Changeset.cast(attrs, [
      :url,
      :url_hash,
      :domain,
      :title,
      :description,
      :image_url,
      :site_name,
      :image_path,
      :status,
      :fetched_at
    ])
    |> Ecto.Changeset.unique_constraint(:url_hash)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :title,
           :description,
           :image_url,
           :site_name,
           :image_path,
           :status,
           :fetched_at,
           :error,
           :updated_at
         ]},
      conflict_target: :url_hash,
      returning: true
    )
  end

  defp upsert_failed(url, url_hash, domain, error) do
    attrs = %{
      url: url,
      url_hash: url_hash,
      domain: domain,
      status: "failed",
      error: String.slice(error, 0, 255),
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %LinkPreview{}
    |> Ecto.Changeset.cast(attrs, [:url, :url_hash, :domain, :status, :error, :fetched_at])
    |> Ecto.Changeset.unique_constraint(:url_hash)
    |> Repo.insert(
      on_conflict: {:replace, [:status, :error, :fetched_at, :updated_at]},
      conflict_target: :url_hash,
      returning: true
    )
  rescue
    e ->
      Logger.warning("link_preview.upsert_failed: url=#{url} error=#{Exception.message(e)}")
      {:error, :upsert_failed}
  end

  defp extract_domain(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end
end
