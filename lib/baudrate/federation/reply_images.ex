defmodule Baudrate.Federation.ReplyImages do
  @moduledoc """
  Timeline item reply image management.

  Handles creation, listing, association, and cleanup of images attached to
  timeline item replies.
  """

  import Ecto.Query
  require Logger
  alias Baudrate.Repo
  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.Federation.TimelineItemReplyImage
  alias Baudrate.Moderation.ContentFilters

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
         %{} = image <- Repo.get_by(TimelineItemReplyImage, id: id, user_id: user_id),
         {:ok, verdict} <- guard_alt(image, user_id, alt) do
      image
      |> TimelineItemReplyImage.changeset(%{alt: alt})
      |> Repo.update()
      |> tap(fn
        {:ok, _} when not is_nil(verdict) ->
          ContentFilters.flag(verdict, %{reported_user_id: user_id}, evidence: alt)

        _ ->
          :ok
      end)
    else
      {:error, reason} when is_atom(reason) and reason != :not_found -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  # A reply that has been sent is published; changing its image's
  # description changes text other people read, so the sanction gate
  # (ADR 0029) and the content filters (ADR 0065) apply, as an edit.
  defp guard_alt(%TimelineItemReplyImage{reply_id: nil}, _user_id, _alt), do: {:ok, nil}

  defp guard_alt(image, user_id, alt) do
    with :ok <- Baudrate.Auth.ensure_can_interact(user_id) do
      verdict =
        ContentFilters.screen(%{body: alt || ""},
          mode: :edit,
          previous: %{body: image.alt || ""},
          target_type: "timeline_reply",
          user_id: user_id
        )

      with :ok <- ContentFilters.refuse_blocked(verdict) do
        ContentFilters.record(verdict)
        {:ok, verdict}
      end
    end
  end

  @doc """
  The descriptions of the member's own reply uploads among `image_ids`,
  screened with the reply (ADR 0065).
  """
  @spec reply_image_alts([integer()], integer() | nil) :: [String.t()]
  def reply_image_alts([_ | _] = image_ids, user_id) when is_integer(user_id) do
    ids = Enum.filter(image_ids, &is_integer/1)

    from(ri in TimelineItemReplyImage,
      where: ri.id in ^ids and ri.user_id == ^user_id and not is_nil(ri.alt),
      select: ri.alt
    )
    |> Repo.all()
  end

  def reply_image_alts(_image_ids, _user_id), do: []

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
  Returns the paths of their files (the caller deletes them from disk).

  The paths are rebuilt from `filename` through `DataPortability.Files`, as
  every other sweep does (ADR 0040). This one returned `storage_path`, an
  absolute path into the release current at upload time — which the deploy
  deletes, so after any deploy the file was never unlinked.
  """
  def delete_orphan_reply_images(cutoff) do
    query =
      from(ri in TimelineItemReplyImage,
        where: is_nil(ri.reply_id) and ri.inserted_at < ^cutoff
      )

    paths =
      from(ri in query, select: ri.filename)
      |> Repo.all()
      |> Enum.flat_map(fn filename ->
        case Baudrate.DataPortability.Files.image_path("article_images", filename) do
          {:ok, path} ->
            [path]

          :error ->
            Logger.info("images.orphan_path_unresolvable: filename=#{inspect(filename)}")
            []
        end
      end)

    Repo.delete_all(query)

    paths
  end
end
