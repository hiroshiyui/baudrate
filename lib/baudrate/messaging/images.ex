defmodule Baudrate.Messaging.Images do
  @moduledoc """
  Images in direct messages (6D, ADR 0071).

  ## Private files

  An image is written to `uploads/dm_images` and read back only through
  `accessible/2`, which `BaudrateWeb.DmImageController` asks on every
  request. Its `filename` is never rendered or returned to a client: the
  only address a browser ever sees is `/messages/images/:id`. Paths are
  rebuilt from `filename` through `Baudrate.DataPortability.Files`, never
  stored (ADR 0040).

  ## Only between members here

  A conversation with an account on another server gets no images: that
  server would need a URL it can fetch without signing in, and a URL like
  that is a public link. `Messaging.create_message/3` refuses `image_ids`
  there.

  ## Cost is charged before the work

  `create/2` takes a place in the member's hourly and daily buckets and
  checks the cap on unsent uploads **before** the file is decoded and
  re-encoded, because the processing and the disk the backup carries are
  what is being rationed. A refused upload is never processed.

  ## Never screened

  Descriptions are not run past the content filters: direct messages are
  never screened (ADR 0065 decision 12).
  """

  import Ecto.Query
  require Logger

  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.DataPortability.Files
  alias Baudrate.Messaging.{Conversation, DirectMessage, DmImage}
  alias Baudrate.Moderation.Report
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @subdir "dm_images"
  @max_pending 4

  @doc "The most unsent images a member may hold at once."
  def max_pending, do: @max_pending

  @doc """
  Processes the upload at `upload_path` into a new, unsent image owned by
  `user`.

  Refused, without touching the file, with `{:error, :too_many_pending}`
  when the member already holds #{@max_pending} unsent images, or
  `{:error, :rate_limited}` when an hourly or daily bucket is spent. A file
  that is not an image is `{:error, :invalid_image}` (or the processor's
  reason).
  """
  def create(%User{} = user, upload_path) do
    with :ok <- authorize_upload(user),
         {:ok, info} <- ArticleImageStorage.process_upload(upload_path, subdir: @subdir) do
      %DmImage{}
      |> DmImage.changeset(Map.put(info, :user_id, user.id))
      |> Repo.insert()
      |> case do
        {:ok, image} ->
          {:ok, image}

        {:error, _} = error ->
          unlink(info.filename)
          error
      end
    end
  end

  @doc """
  Whether `user` may upload another image now. Checks the cap on unsent
  images, then takes a place in the hourly bucket (smaller for a new
  account, ADR 0064) and the daily one.
  """
  def authorize_upload(%User{} = user) do
    pending =
      Repo.aggregate(
        from(i in DmImage, where: i.user_id == ^user.id and is_nil(i.message_id)),
        :count
      )

    cond do
      pending >= @max_pending ->
        {:error, :too_many_pending}

      true ->
        with :ok <-
               BaudrateWeb.RateLimits.check_dm_image_upload(user.id, Baudrate.Auth.trusted?(user)) do
          BaudrateWeb.RateLimits.check_dm_image_upload_daily(user.id)
        end
    end
  end

  @doc """
  Sets the description of one of `user`'s own images. Another member's id
  answers `{:error, :not_found}`.
  """
  def set_alt(%User{} = user, image_id, attrs) do
    case Repo.get_by(DmImage, id: image_id, user_id: user.id) do
      nil -> {:error, :not_found}
      image -> image |> DmImage.alt_changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Deletes one of `user`'s **unsent** images and its file (removing it from
  the composer). A sent image goes only with its message.
  """
  def delete_unsent(%User{} = user, image_id) do
    case Repo.get_by(DmImage, id: image_id, user_id: user.id) do
      %DmImage{message_id: nil} = image ->
        {:ok, _} = Repo.delete(image)
        unlink(image.filename)
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Attaches `image_ids` — which must be `user_id`'s own and unsent — to
  `message_id`. A step of the message's own transaction. Ids that are not
  the sender's, or already sent, are silently left alone.
  """
  def attach(message_id, image_ids, user_id) when is_list(image_ids) do
    ids = image_ids |> Enum.uniq() |> Enum.take(DmImage.max_per_message())

    from(i in DmImage, where: i.id in ^ids and i.user_id == ^user_id and is_nil(i.message_id))
    |> Repo.update_all(set: [message_id: message_id])
  end

  @doc """
  Returns `{:ok, image, path}` when `viewer` may see image `id`, and
  `:error` otherwise — one answer for every refusal, so the endpoint says
  nothing about whether an image exists.

  A viewer may see an image that:

    * is attached to a message, not deleted, in a conversation they take
      part in;
    * is their own and not yet sent (the composer's preview);
    * is attached to a message an **open report** names, when they hold
      `moderator.sanction_user` — a moderator sees the reported message's
      image and nothing else of the conversation.
  """
  def accessible(nil, _id), do: :error

  def accessible(%User{} = viewer, id) do
    with %DmImage{} = image <- Repo.get(DmImage, id),
         true <- may_view?(viewer, image),
         {:ok, path} <- Files.image_path(@subdir, image.filename) do
      {:ok, image, path}
    else
      _ -> :error
    end
  end

  defp may_view?(%User{id: user_id}, %DmImage{message_id: nil, user_id: user_id}), do: true
  defp may_view?(_viewer, %DmImage{message_id: nil}), do: false

  defp may_view?(viewer, %DmImage{message_id: message_id}) do
    case Repo.get(DirectMessage, message_id) do
      %DirectMessage{deleted_at: nil} = message ->
        participant?(viewer, message) or reported_to?(viewer, message)

      _ ->
        false
    end
  end

  defp participant?(%User{id: user_id}, message) do
    Repo.exists?(
      from(c in Conversation,
        where: c.id == ^message.conversation_id,
        where: c.user_a_id == ^user_id or c.user_b_id == ^user_id
      )
    )
  end

  defp reported_to?(%User{} = viewer, message) do
    viewer = Repo.preload(viewer, :role)

    Baudrate.Setup.has_permission?(viewer.role.name, "moderator.sanction_user") and
      Repo.exists?(from(r in Report, where: r.message_id == ^message.id and r.status == "open"))
  end

  @doc """
  Deletes the images of `message_id` and their files. Called when a message
  is withdrawn: a deleted message keeps nothing its recipient could open.
  """
  def delete_for_message(message_id) do
    {_, filenames} =
      from(i in DmImage, where: i.message_id == ^message_id, select: i.filename)
      |> Repo.delete_all()

    Enum.each(filenames, &unlink/1)
    length(filenames)
  end

  @doc """
  Deletes unsent images older than `hours` and their files — uploads whose
  message was never sent. Run daily from `Baudrate.Auth.SessionCleaner`.
  Returns the number removed.
  """
  def delete_orphans(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    {_, filenames} =
      from(i in DmImage,
        where: is_nil(i.message_id) and i.inserted_at < ^cutoff,
        select: i.filename
      )
      |> Repo.delete_all()

    Enum.each(filenames, &unlink/1)
    length(filenames)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp unlink(filename) do
    case Files.image_path(@subdir, filename) do
      {:ok, path} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("dm_images.delete_failed: reason=#{inspect(reason)}")
        end

      :error ->
        Logger.info("dm_images.file_already_gone")
    end
  end
end
