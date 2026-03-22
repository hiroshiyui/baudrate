defmodule Baudrate.Content.Images do
  @moduledoc """
  Article and comment image management.

  Handles creation, listing, association, and cleanup of article images
  and comment images.
  """

  require Logger

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.ArticleImage
  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.Content.CommentImage
  alias Baudrate.Federation.HTTPClient

  @doc """
  Creates an article image record.
  """
  def create_article_image(attrs) do
    %ArticleImage{}
    |> ArticleImage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists images for an article, ordered by insertion time.
  """
  def list_article_images(article_id) do
    from(ai in ArticleImage,
      where: ai.article_id == ^article_id,
      order_by: [asc: ai.inserted_at, asc: ai.id]
    )
    |> Repo.all()
  end

  @doc """
  Lists orphan images (no article) for a user, for use during article composition.
  """
  def list_orphan_article_images(user_id) do
    from(ai in ArticleImage,
      where: ai.user_id == ^user_id and is_nil(ai.article_id),
      order_by: [asc: ai.inserted_at, asc: ai.id]
    )
    |> Repo.all()
  end

  @doc """
  Deletes an article image record and its file on disk.
  """
  def delete_article_image(%ArticleImage{} = image) do
    Baudrate.Content.ArticleImageStorage.delete_image(image)
    Repo.delete(image)
  end

  @doc """
  Associates orphan article images with an article by setting their `article_id`.
  Only updates images owned by the given user that currently have no article.
  """
  def associate_article_images(article_id, image_ids, user_id) when is_list(image_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(ai in ArticleImage,
      where:
        ai.id in ^image_ids and
          ai.user_id == ^user_id and
          is_nil(ai.article_id)
    )
    |> Repo.update_all(set: [article_id: article_id, updated_at: now])
  end

  @doc """
  Fetches an article image by ID.
  """
  def get_article_image!(id), do: Repo.get!(ArticleImage, id)

  @doc """
  Returns the count of images for an article.
  """
  def count_article_images(article_id) do
    Repo.one(
      from(ai in ArticleImage,
        where: ai.article_id == ^article_id,
        select: count(ai.id)
      )
    ) || 0
  end

  @doc """
  Deletes orphan article images older than the given cutoff.
  Returns the list of storage paths that were deleted from the database
  (caller should delete the files from disk).
  """
  def delete_orphan_article_images(cutoff) do
    query =
      from(ai in ArticleImage,
        where: is_nil(ai.article_id) and ai.inserted_at < ^cutoff,
        select: ai.storage_path
      )

    paths = Repo.all(query)

    from(ai in ArticleImage,
      where: is_nil(ai.article_id) and ai.inserted_at < ^cutoff
    )
    |> Repo.delete_all()

    paths
  end

  # --- Comment Images ---

  @doc """
  Creates a comment image record.
  """
  def create_comment_image(attrs) do
    %CommentImage{}
    |> CommentImage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists images for a comment, ordered by insertion time.
  """
  def list_comment_images(comment_id) do
    from(ci in CommentImage,
      where: ci.comment_id == ^comment_id,
      order_by: [asc: ci.inserted_at, asc: ci.id]
    )
    |> Repo.all()
  end

  @doc """
  Lists orphan images (no comment) for a user, for use during comment composition.
  """
  def list_orphan_comment_images(user_id) do
    from(ci in CommentImage,
      where: ci.user_id == ^user_id and is_nil(ci.comment_id),
      order_by: [asc: ci.inserted_at, asc: ci.id]
    )
    |> Repo.all()
  end

  @doc """
  Deletes a comment image record and its file on disk.
  """
  def delete_comment_image(%CommentImage{} = image) do
    ArticleImageStorage.delete_image(image)
    Repo.delete(image)
  end

  @doc """
  Associates orphan comment images with a comment by setting their `comment_id`.
  Only updates images owned by the given user that currently have no comment.
  """
  def associate_comment_images(comment_id, image_ids, user_id) when is_list(image_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(ci in CommentImage,
      where:
        ci.id in ^image_ids and
          ci.user_id == ^user_id and
          is_nil(ci.comment_id)
    )
    |> Repo.update_all(set: [comment_id: comment_id, updated_at: now])
  end

  @doc """
  Fetches a comment image by ID.
  """
  def get_comment_image!(id), do: Repo.get!(CommentImage, id)

  @doc """
  Returns the count of images for a comment.
  """
  def count_comment_images(comment_id) do
    Repo.one(
      from(ci in CommentImage,
        where: ci.comment_id == ^comment_id,
        select: count(ci.id)
      )
    ) || 0
  end

  @doc """
  Deletes orphan comment images older than the given cutoff.
  Returns the list of storage paths that were deleted from the database
  (caller should delete the files from disk).
  """
  def delete_orphan_comment_images(cutoff) do
    query =
      from(ci in CommentImage,
        where: is_nil(ci.comment_id) and ci.inserted_at < ^cutoff,
        select: ci.storage_path
      )

    paths = Repo.all(query)

    from(ci in CommentImage,
      where: is_nil(ci.comment_id) and ci.inserted_at < ^cutoff
    )
    |> Repo.delete_all()

    paths
  end

  @max_image_size 8 * 1024 * 1024

  @doc """
  Fetches remote image attachments from AP objects and stores them as article images.

  Each attachment map should have `"url"` (required), `"media_type"`, and `"name"`.
  Images are fetched via SSRF-safe HTTP client, validated, re-encoded to WebP,
  and stored locally. Best-effort: failures are logged and skipped.

  Returns `:ok`.
  """
  def fetch_and_store_remote_images(article_id, attachments) when is_list(attachments) do
    File.mkdir_p!(ArticleImageStorage.upload_dir())

    attachments
    |> Enum.take(ArticleImage.max_images_per_article())
    |> Enum.each(fn att ->
      url = att["url"]

      case fetch_and_store_one(article_id, url) do
        {:ok, _image} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "images.remote_fetch_failed: article_id=#{article_id} url=#{url} reason=#{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  def fetch_and_store_remote_images(_article_id, _), do: :ok

  defp fetch_and_store_one(article_id, url) when is_binary(url) do
    with :ok <- HTTPClient.validate_url(url),
         {:ok, %{body: body}} <-
           HTTPClient.get_html(url, headers: [{"accept", "image/*"}], max_size: @max_image_size),
         :ok <- validate_image_size(body),
         {:ok, result} <- process_image_binary(body) do
      %ArticleImage{}
      |> ArticleImage.remote_changeset(%{
        filename: result.filename,
        storage_path: result.storage_path,
        width: result.width,
        height: result.height,
        article_id: article_id
      })
      |> Repo.insert()
    end
  end

  defp fetch_and_store_one(_article_id, _url), do: {:error, :invalid_url}

  defp validate_image_size(body) when byte_size(body) > @max_image_size,
    do: {:error, :image_too_large}

  defp validate_image_size(_body), do: :ok

  defp process_image_binary(body) do
    # Write to temp file for ArticleImageStorage-compatible processing
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "remote_img_#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}"
      )

    try do
      File.write!(tmp_path, body)
      ArticleImageStorage.process_upload(tmp_path)
    after
      File.rm(tmp_path)
    end
  end
end
