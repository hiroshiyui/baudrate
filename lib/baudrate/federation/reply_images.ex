defmodule Baudrate.Federation.ReplyImages do
  @moduledoc """
  Feed item reply image management.

  Handles creation, listing, association, and cleanup of images attached to
  feed item replies.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.Federation.FeedItemReplyImage

  @doc """
  Creates a feed item reply image record.
  """
  def create_reply_image(attrs) do
    %FeedItemReplyImage{}
    |> FeedItemReplyImage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists images for a reply, ordered by insertion time.
  """
  def list_reply_images(reply_id) do
    from(ri in FeedItemReplyImage,
      where: ri.reply_id == ^reply_id,
      order_by: [asc: ri.inserted_at, asc: ri.id]
    )
    |> Repo.all()
  end

  @doc """
  Lists orphan images (no reply) for a user, for use during reply composition.
  """
  def list_orphan_reply_images(user_id) do
    from(ri in FeedItemReplyImage,
      where: ri.user_id == ^user_id and is_nil(ri.reply_id),
      order_by: [asc: ri.inserted_at, asc: ri.id]
    )
    |> Repo.all()
  end

  @doc """
  Deletes a reply image record and its file on disk.
  """
  def delete_reply_image(%FeedItemReplyImage{} = image) do
    ArticleImageStorage.delete_image(image)
    Repo.delete(image)
  end

  @doc """
  Associates orphan reply images with a reply by setting their `reply_id`.
  Only updates images owned by the given user that currently have no reply.
  """
  def associate_reply_images(reply_id, image_ids, user_id) when is_list(image_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(ri in FeedItemReplyImage,
      where:
        ri.id in ^image_ids and
          ri.user_id == ^user_id and
          is_nil(ri.reply_id)
    )
    |> Repo.update_all(set: [reply_id: reply_id, updated_at: now])
  end

  @doc """
  Fetches a reply image by ID.
  """
  def get_reply_image!(id), do: Repo.get!(FeedItemReplyImage, id)

  @doc """
  Deletes orphan reply images older than the given cutoff.
  Returns the list of storage paths that were deleted from the database
  (caller should delete the files from disk).
  """
  def delete_orphan_reply_images(cutoff) do
    query =
      from(ri in FeedItemReplyImage,
        where: is_nil(ri.reply_id) and ri.inserted_at < ^cutoff,
        select: ri.storage_path
      )

    paths = Repo.all(query)

    from(ri in FeedItemReplyImage,
      where: is_nil(ri.reply_id) and ri.inserted_at < ^cutoff
    )
    |> Repo.delete_all()

    paths
  end
end
