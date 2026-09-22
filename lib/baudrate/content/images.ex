defmodule Baudrate.Content.Images do
  @moduledoc """
  Article and comment image management.

  Handles creation, listing, association, and cleanup of article images
  and comment images — and the one upload attached to published content as
  it lands, from the article edit page, which is therefore checked here
  (`authorize_article_image/2`, ADR 0064).
  """

  require Logger

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Content.Article
  alias Baudrate.Content.ArticleImage
  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.Content.CommentImage
  alias Baudrate.Content.ImageAlt
  alias Baudrate.Content.Permissions
  alias Baudrate.DataPortability.Files
  alias Baudrate.Federation.HTTPClient
  alias Baudrate.Moderation.ContentFilters

  @doc """
  Creates an article image record.
  """
  def create_article_image(attrs) do
    %ArticleImage{}
    |> ArticleImage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Whether `user` may attach another image to the published `article` from its
  edit page.

  A composer upload is an orphan until the post is submitted, and is checked
  then, with the post. An upload on the edit page is different: it is attached
  to the article as it lands, so it is on the published page before anything
  is submitted, and nothing downstream gets a second look. So it is checked
  here — the uploader must be able to edit the article, the account must be
  allowed to act at all (ADR 0029), and a new account may not take the article
  past its image limit (ADR 0064). Before this, the edit page was a way round
  both gates.

  Returns `:ok`, `{:error, :unauthorized}`, `{:error, :too_many_images}`, or
  either gate's refusal.
  """
  @spec authorize_article_image(%Article{}, map()) :: :ok | {:error, atom()}
  def authorize_article_image(%Article{} = article, user) do
    existing = count_article_images(article.id)

    cond do
      not Permissions.can_edit_article?(user, article) ->
        {:error, :unauthorized}

      existing >= ArticleImage.max_images_per_article() ->
        {:error, :too_many_images}

      true ->
        with :ok <- Baudrate.Auth.ensure_can_interact(user) do
          Baudrate.Auth.check_post(user, article.body, existing + 1,
            previous: {article.body, existing}
          )
        end
    end
  end

  @doc """
  Attaches a processed upload to the published `article`, as `user`, after
  `authorize_article_image/2` agrees. `file_info` is what
  `ArticleImageStorage.process_upload/1` returned.

  On a refusal the stored files are removed, since nothing else will ever
  reference them.
  """
  @spec add_article_image(%Article{}, map(), map()) ::
          {:ok, %ArticleImage{}} | {:error, atom() | Ecto.Changeset.t()}
  def add_article_image(%Article{} = article, file_info, user) do
    with :ok <- authorize_article_image(article, user) do
      file_info
      |> Map.merge(%{user_id: user.id, article_id: article.id})
      |> create_article_image()
    end
    |> case do
      {:ok, image} ->
        {:ok, image}

      {:error, _} = error ->
        ArticleImageStorage.delete_image(file_info)
        error
    end
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

  Once the image belongs to a published post, or to one waiting for review,
  the description is published text: the sanction gate (ADR 0029) and the
  content filters (ADR 0065) apply, and their refusals are returned.

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
         %{} = image <- Repo.get_by(schema, id: id, user_id: user_id),
         {:ok, screened} <- guard_alt(image, user_id, alt) do
      image
      |> changeset_fun.(%{alt: alt})
      |> Repo.update()
      |> tap(fn
        {:ok, _} -> flag_alt(screened)
        _ -> :ok
      end)
    else
      {:error, reason} when is_atom(reason) and reason != :not_found -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  # A description is text other people read. While its upload is still a
  # draft's, it is screened with the post when that is submitted; once the
  # image belongs to a published article or comment — or to a post waiting
  # for review — changing it is changing published text, so it passes the
  # sanction gate (ADR 0029) and the content filters as an edit, judged by
  # what it adds (ADR 0065). Before, a silenced member could rewrite the
  # descriptions on their published posts, and nothing screened them.
  defp guard_alt(image, user_id, alt) do
    {parent, kind} = alt_parent(image)

    if parent || held_image?(image.id, kind) do
      with :ok <- Baudrate.Auth.ensure_can_interact(user_id) do
        verdict =
          ContentFilters.screen(%{body: alt || ""},
            mode: :edit,
            previous: %{body: image.alt || ""},
            target_type: kind,
            user_id: user_id
          )

        with :ok <- ContentFilters.refuse_blocked(verdict) do
          ContentFilters.record(verdict)
          {:ok, {verdict, parent, kind}}
        end
      end
    else
      {:ok, nil}
    end
  end

  defp alt_parent(%ArticleImage{article_id: id}), do: {id, "article"}
  defp alt_parent(%CommentImage{comment_id: id}), do: {id, "comment"}

  defp held_image?(image_id, kind) do
    Repo.exists?(
      from(h in Baudrate.Moderation.HeldPost,
        where:
          h.status == "pending" and h.kind == ^kind and
            fragment("? = ANY(?)", ^image_id, h.image_ids)
      )
    )
  end

  defp flag_alt({verdict, parent, kind}) when is_integer(parent) do
    target = if kind == "article", do: %{article_id: parent}, else: %{comment_id: parent}
    ContentFilters.flag(verdict, target)
  end

  defp flag_alt(_), do: :ok

  @doc """
  The descriptions of the member's own uploads among `image_ids`, which are
  published with the article and so are screened with it (ADR 0065).
  """
  @spec article_image_alts([integer()], integer() | nil) :: [String.t()]
  def article_image_alts(image_ids, user_id), do: alts(ArticleImage, image_ids, user_id)

  @doc "As `article_image_alts/2`, for a comment's uploads."
  @spec comment_image_alts([integer()], integer() | nil) :: [String.t()]
  def comment_image_alts(image_ids, user_id), do: alts(CommentImage, image_ids, user_id)

  defp alts(schema, [_ | _] = image_ids, user_id) when is_integer(user_id) do
    ids = Enum.filter(image_ids, &is_integer/1)

    from(i in schema,
      where: i.id in ^ids and i.user_id == ^user_id and not is_nil(i.alt),
      select: i.alt
    )
    |> Repo.all()
  end

  defp alts(_schema, _image_ids, _user_id), do: []

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

  **An image a saved draft is holding is not an orphan**, and nor is one a
  post waiting for a moderator names (ADR 0065). An upload belongs to no
  article until the post is published, which is exactly the state a draft
  and a held post preserve, so without this a post drafted — or held —
  overnight comes back with its pictures already unlinked from disk. The
  draft's purge, or the held post's approval or rejection, is what eventually
  releases them: once nothing names them they are ordinary orphans again and
  a later pass collects them.
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
        ),
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM held_posts h WHERE h.status = 'pending' AND h.kind = 'article' AND ? = ANY(h.image_ids))",
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

  An image a comment waiting for a moderator names is not an orphan
  (ADR 0065), for the reason `delete_orphan_article_images/1` gives.
  """
  def delete_orphan_comment_images(cutoff) do
    paths =
      orphan_comment_images(cutoff)
      |> select([ci], ci.filename)
      |> Repo.all()
      |> image_paths()

    orphan_comment_images(cutoff) |> Repo.delete_all()

    paths
  end

  defp orphan_comment_images(cutoff) do
    from(ci in CommentImage,
      where: is_nil(ci.comment_id) and ci.inserted_at < ^cutoff,
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM held_posts h WHERE h.status = 'pending' AND h.kind = 'comment' AND ? = ANY(h.image_ids))",
          ci.id
        )
    )
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
