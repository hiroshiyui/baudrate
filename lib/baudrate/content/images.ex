defmodule Baudrate.Content.Images do
  @moduledoc """
  Article image management.

  Handles creation, listing, association, and cleanup of article images.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.ArticleImage

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
      order_by: [asc: ai.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists orphan images (no article) for a user, for use during article composition.
  """
  def list_orphan_article_images(user_id) do
    from(ai in ArticleImage,
      where: ai.user_id == ^user_id and is_nil(ai.article_id),
      order_by: [asc: ai.inserted_at]
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
end
