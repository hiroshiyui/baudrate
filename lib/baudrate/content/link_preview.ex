defmodule Baudrate.Content.LinkPreview do
  @moduledoc """
  Schema for cached link preview metadata (Open Graph / Twitter Card).

  Each preview is deduplicated by `url_hash` (SHA-256 of the URL). The
  `status` field tracks the fetch lifecycle:

    * `"pending"` — queued for fetch
    * `"fetched"` — metadata successfully extracted
    * `"failed"` — fetch or parse error (see `error` field)

  Images are proxied through the server: fetched, re-encoded to WebP, and
  served from `image_path` to prevent user IP leakage and hotlink tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @max_title_length 300
  @max_description_length 1000
  @max_site_name_length 200
  @max_domain_length 253

  schema "link_previews" do
    field :url, :string
    field :url_hash, :binary
    field :title, :string
    field :description, :string
    field :image_url, :string
    field :site_name, :string
    field :domain, :string
    field :image_path, :string
    field :status, :string, default: "pending"
    field :error, :string
    field :fetched_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a pending link preview."
  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [:url])
    |> validate_required([:url])
    |> compute_url_hash()
    |> extract_domain()
    |> unique_constraint(:url_hash)
  end

  @doc "Changeset for updating a preview with fetched metadata."
  def fetched_changeset(preview, attrs) do
    preview
    |> cast(attrs, [:title, :description, :image_url, :site_name, :image_path, :status, :error])
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:description, max: @max_description_length)
    |> validate_length(:site_name, max: @max_site_name_length)
    |> validate_length(:domain, max: @max_domain_length)
    |> validate_inclusion(:status, ~w(pending fetched failed))
    |> put_fetched_at()
  end

  @doc "Computes SHA-256 hash for a URL."
  def hash_url(url) when is_binary(url) do
    :crypto.hash(:sha256, url)
  end

  defp compute_url_hash(changeset) do
    case get_change(changeset, :url) do
      nil -> changeset
      url -> put_change(changeset, :url_hash, hash_url(url))
    end
  end

  defp extract_domain(changeset) do
    case get_change(changeset, :url) do
      nil ->
        changeset

      url ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) and host != "" ->
            put_change(changeset, :domain, String.downcase(host))

          _ ->
            changeset
        end
    end
  end

  defp put_fetched_at(changeset) do
    if get_change(changeset, :status) in ["fetched", "failed"] do
      put_change(changeset, :fetched_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      changeset
    end
  end
end
