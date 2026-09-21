defmodule Baudrate.Federation.ReplyImages do
  @moduledoc """
  Timeline item reply image management.

  Handles creation, listing, association, and cleanup of images attached to
  timeline item replies.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.Federation.TimelineItemReplyImage

  @doc """
  Creates a timeline item reply image record.
  """
  def create_reply_image(attrs) do
    %TimelineItemReplyImage{}
    |> TimelineItemReplyImage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists images for a reply, ordered by insertion time.
  """
  def list_reply_images(reply_id) do
    from(ri in TimelineItemReplyImage,
      where: ri.reply_id == ^reply_id,
      order_by: [asc: ri.inserted_at, asc: ri.id]
    )
    |> Repo.all()
  end

  @doc """
  Lists orphan images (no reply) for a user, for use during reply composition.
  """
  def list_orphan_reply_images(user_id) do
    from(ri in TimelineItemReplyImage,
      where: ri.user_id == ^user_id and is_nil(ri.reply_id),
      order_by: [asc: ri.inserted_at, asc: ri.id]
    )
    |> Repo.all()
  end

  @doc """
  Deletes a reply image record and its file on disk.
  """
  def delete_reply_image(%TimelineItemReplyImage{} = image) do
    ArticleImageStorage.delete_image(image)
    Repo.delete(image)
  end

  @doc """
  Associates orphan reply images with a reply by setting their `reply_id`.
  Only updates images owned by the given user that currently have no reply.
  """
  def associate_reply_images(reply_id, image_ids, user_id) when is_list(image_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(ri in TimelineItemReplyImage,
      where:
        ri.id in ^image_ids and
          ri.user_id == ^user_id and
          is_nil(ri.reply_id)
    )
    |> Repo.update_all(set: [reply_id: reply_id, updated_at: now])
  end

  @doc """
  Sets a reply image's description (see `Baudrate.Content.ImageAlt`).

  The reply-side twin of `Baudrate.Content.Images.update_article_image_alt/3`,
  and scoped the same way: the id comes from the client, so it is parsed and
  matched against the uploader.
  """
  @spec update_reply_image_alt(term(), integer(), String.t() | nil) ::
          {:ok, %TimelineItemReplyImage{}} | {:error, Ecto.Changeset.t() | :not_found}
  def update_reply_image_alt(image_id, user_id, alt) do
    with {:ok, id} <- image_id(image_id),
         %{} = image <- Repo.get_by(TimelineItemReplyImage, id: id, user_id: user_id) do
      image |> TimelineItemReplyImage.changeset(%{alt: alt}) |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  # `phx-value-id` always arrives as a string, but this is a context function
  # and an integer is the natural thing for any other caller to pass. Both are
  # accepted; anything else is refused rather than raising.
  defp image_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp image_id(id) when is_binary(id), do: BaudrateWeb.Helpers.parse_id(id)
  defp image_id(_), do: :error

  @doc """
  Fetches a reply image by ID.
  """
  def get_reply_image!(id), do: Repo.get!(TimelineItemReplyImage, id)

  @doc """
  Deletes orphan reply images older than the given cutoff.
  Returns the list of storage paths that were deleted from the database
  (caller should delete the files from disk).
  """
  def delete_orphan_reply_images(cutoff) do
    query =
      from(ri in TimelineItemReplyImage,
        where: is_nil(ri.reply_id) and ri.inserted_at < ^cutoff,
        select: ri.storage_path
      )

    paths = Repo.all(query)

    from(ri in TimelineItemReplyImage,
      where: is_nil(ri.reply_id) and ri.inserted_at < ^cutoff
    )
    |> Repo.delete_all()

    paths
  end
end
