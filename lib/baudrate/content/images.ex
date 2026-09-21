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
  alias Baudrate.Content.ImageAlt
  alias Baudrate.DataPortability.Files
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
  Sets an article image's description (ADR 0060's sibling; see
  `Baudrate.Content.ImageAlt`).

  Scoped to the uploading user, and the id arrives from the client — the
  composer renders one input per already-inserted row, so this is a
  fetch-by-client-id and gets `parse_id/1` plus a `user_id` match rather than a
  bare `Repo.get`. Returns `{:error, :not_found}` for anything else, which is
  the same answer for "no such image" and "not yours".

  It goes through the changeset rather than `update_all` so the length bound
  actually runs.
  """
  @spec update_article_image_alt(term(), integer(), String.t() | nil) ::
          {:ok, %ArticleImage{}} | {:error, Ecto.Changeset.t() | :not_found}
  def update_article_image_alt(image_id, user_id, alt),
    do: set_alt(ArticleImage, &ArticleImage.changeset/2, image_id, user_id, alt)

  @doc """
  Sets a comment image's description. See `update_article_image_alt/3`.
  """
  @spec update_comment_image_alt(term(), integer(), String.t() | nil) ::
          {:ok, %CommentImage{}} | {:error, Ecto.Changeset.t() | :not_found}
  def update_comment_image_alt(image_id, user_id, alt),
    do: set_alt(CommentImage, &CommentImage.changeset/2, image_id, user_id, alt)

  defp set_alt(schema, changeset_fun, image_id, user_id, alt) do
    with {:ok, id} <- image_id(image_id),
         %{} = image <- Repo.get_by(schema, id: id, user_id: user_id) do
      image |> changeset_fun.(%{alt: alt}) |> Repo.update()
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
  Fetches an article image by ID.
  """
  def get_article_image!(id), do: Repo.get!(ArticleImage, id)

  @doc """
  Fetches an article image by ID, returning `nil` if not found or `id` is invalid.
  """
  def get_article_image(id) do
    case BaudrateWeb.Helpers.parse_id(id) do
      {:ok, int_id} -> Repo.get(ArticleImage, int_id)
      :error -> nil
    end
  end

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
  Returns the list of absolute file paths whose rows were deleted
  (caller should delete the files from disk).

  Paths are rebuilt from `filename`, never read from `storage_path` — see
  `image_paths/1`.

  **An image a saved draft is holding is not an orphan.** An upload belongs to
  no article until the post is submitted, which is exactly the state a draft
  preserves, so without this a post drafted overnight is resumed with its
  pictures already unlinked from disk. The draft's own purge is what
  eventually releases them: once the row is gone the images are ordinary
  orphans again and a later pass collects them.
  """
  def delete_orphan_article_images(cutoff) do
    paths =
      orphan_article_images(cutoff)
      |> select([ai], ai.filename)
      |> Repo.all()
      |> image_paths()

    orphan_article_images(cutoff) |> Repo.delete_all()

    paths
  end

  # One definition for both halves: the select and the delete must not be able
  # to disagree about what an orphan is, or the files of images that were
  # spared would be unlinked while their rows stayed.
  defp orphan_article_images(cutoff) do
    from(ai in ArticleImage,
      where: is_nil(ai.article_id) and ai.inserted_at < ^cutoff,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM article_drafts d WHERE ? = ANY(d.image_ids))",
          ai.id
        )
    )
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
  Returns the list of absolute file paths whose rows were deleted
  (caller should delete the files from disk).

  Paths are rebuilt from `filename`, never read from `storage_path` — see
  `image_paths/1`.
  """
  def delete_orphan_comment_images(cutoff) do
    paths =
      from(ci in CommentImage,
        where: is_nil(ci.comment_id) and ci.inserted_at < ^cutoff,
        select: ci.filename
      )
      |> Repo.all()
      |> image_paths()

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
  # sobelow_skip ["Traversal.FileModule"]
  def fetch_and_store_remote_images(article_id, attachments) when is_list(attachments) do
    File.mkdir_p!(ArticleImageStorage.upload_dir())

    attachments
    |> Enum.take(ArticleImage.max_images_per_article())
    |> Enum.each(fn att ->
      url = att["url"]

      case fetch_and_store_one(article_id, url, att["name"]) do
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

  defp fetch_and_store_one(article_id, url, name) when is_binary(url) do
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
        article_id: article_id,
        # The peer described the image; store what they wrote rather than
        # rendering "Image 2" over the top of it. `from_remote/1` strips tags
        # and bounds the length — it is a remote-controlled string reaching a
        # column, with `ImageAlt.validate/1` as the changeset backstop.
        alt: ImageAlt.from_remote(name)
      })
      |> Repo.insert()
    end
  end

  defp fetch_and_store_one(_article_id, _url, _name), do: {:error, :invalid_url}

  defp validate_image_size(body) when byte_size(body) > @max_image_size,
    do: {:error, :image_too_large}

  defp validate_image_size(_body), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
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

  # Absolute paths for the orphan sweeps, rebuilt from `filename`.
  #
  # `storage_path` is deliberately not read, for the same reason
  # `Baudrate.Retention` does not read it (ADR 0040): it is an absolute path
  # into the release directory that was current when the file was uploaded,
  # and the deploy keeps only the newest few releases. A deploy inside the
  # orphan window therefore made `File.rm/1` a silent no-op while the row
  # naming the file was deleted, leaking the bytes in `shared/uploads` with
  # nothing left to find them by. The window is narrower here than retention's
  # ninety days — 24 hours plus the hourly sweep — but the shape is identical,
  # and a deploy is exactly the event that lands inside it.
  #
  # Rebuilding through `DataPortability.Files` also confines every component
  # below the uploads root and rejects anything but a hex `.webp` name, so a
  # tampered row cannot steer the unlink. Comment images are written by
  # `ArticleImageStorage.process_upload/1` too, so both kinds live in
  # `article_images` whatever table indexes them.
  defp image_paths(filenames) do
    Enum.flat_map(filenames, fn filename ->
      case Files.image_path("article_images", filename) do
        {:ok, path} ->
          [path]

        :error ->
          Logger.info("images.orphan_path_unresolvable: filename=#{inspect(filename)}")
          []
      end
    end)
  end
end
