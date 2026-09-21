defmodule Baudrate.Content.Drafts do
  @moduledoc """
  Unfinished articles kept on the server, beside the composer's
  `localStorage` autosave rather than instead of it.

  The two halves fail in opposite directions and that is the point. The
  browser hook keeps working when the socket is down and is the only one that
  helps on a flaky train connection; it cannot follow a member to another
  device, because `localStorage` belongs to one browser on one machine. A row
  here can be resumed anywhere the member signs in; it cannot be written at
  all while the connection is gone. Keeping both means a lost draft needs both
  failures at once.

  ## Every read is scoped to the owner

  A draft is private writing. There is no listing for anyone else, no
  moderator view and no admin view, and every function here takes the owner's
  id and matches on it in the query rather than fetching by id and checking
  afterwards — `get/2` returns `nil` for another member's draft exactly as it
  does for one that never existed. That is deliberate: a "not yours" that is
  distinguishable from "no such draft" tells a stranger how many drafts
  somebody has.

  ## The cap is counted, never stored

  `quota_remaining/1` is a `COUNT` at save time, following
  `Baudrate.Auth.Invites.invite_quota_remaining/1`. A counter column would
  have to be maintained by every path that creates or deletes a draft —
  including the hourly purge and the cascade when an account is deleted — and
  it drifts silently in both directions when one of them is missed.

  The cap applies to **creating** a draft, never to updating one. A member at
  the limit can still type: their open composer keeps saving into the row it
  already has, and the `localStorage` half is untouched. What they cannot do
  is start a twenty-first.
  """

  import Ecto.Query

  alias Baudrate.Content.ArticleDraft
  alias Baudrate.Repo

  @max_drafts 20
  @stale_after_days 90

  @doc "The most drafts one member may hold."
  def max_drafts, do: @max_drafts

  @doc "How long an untouched draft is kept."
  def stale_after_days, do: @stale_after_days

  @doc """
  Lists a member's drafts, most recently touched first.

  Ordered by `updated_at` with an `id` tiebreaker, because a member who saves
  two drafts inside the same second would otherwise see them swap places
  between renders.
  """
  @spec list(integer()) :: [ArticleDraft.t()]
  def list(user_id) when is_integer(user_id) do
    from(d in ArticleDraft,
      where: d.user_id == ^user_id,
      order_by: [desc: d.updated_at, desc: d.id]
    )
    |> Repo.all()
  end

  @doc """
  Fetches one of the member's own drafts, or `nil`.

  Scoped in the query, never fetched and then checked.
  """
  @spec get(integer(), integer()) :: ArticleDraft.t() | nil
  def get(user_id, draft_id) when is_integer(user_id) and is_integer(draft_id) do
    Repo.get_by(ArticleDraft, id: draft_id, user_id: user_id)
  end

  def get(_, _), do: nil

  @doc """
  The member's most recently touched draft, or `nil`.

  This is what a fresh composer restores. It deliberately ignores drafts with
  neither a title nor a body: an empty row is the residue of opening the
  composer and closing it again, and putting it back would be indistinguishable
  from a bug.
  """
  @spec latest(integer()) :: ArticleDraft.t() | nil
  def latest(user_id) when is_integer(user_id) do
    from(d in ArticleDraft,
      where: d.user_id == ^user_id,
      where:
        (not is_nil(d.title) and d.title != "") or
          (not is_nil(d.body) and d.body != ""),
      order_by: [desc: d.updated_at, desc: d.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Saves a draft for `user_id`, creating one or updating the one named.

  Returns `{:ok, draft}`, `{:error, :quota_exceeded}` when a *new* draft would
  exceed the cap, or `{:error, changeset}`.

  `draft_id` is checked against the owner before anything is written, so a
  client-supplied id from another member's account creates nothing and
  updates nothing.
  """
  @spec save(integer(), map(), integer() | nil) ::
          {:ok, ArticleDraft.t()} | {:error, :quota_exceeded | Ecto.Changeset.t()}
  def save(user_id, attrs, draft_id \\ nil) when is_integer(user_id) do
    case draft_id && get(user_id, draft_id) do
      %ArticleDraft{} = draft ->
        draft |> ArticleDraft.changeset(attrs) |> Repo.update()

      _ ->
        create(user_id, attrs)
    end
  end

  defp create(user_id, attrs) do
    if count(user_id) >= @max_drafts do
      {:error, :quota_exceeded}
    else
      %ArticleDraft{user_id: user_id}
      |> ArticleDraft.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Deletes one of the member's own drafts. Returns `:ok` either way."
  @spec delete(integer(), integer()) :: :ok
  def delete(user_id, draft_id) when is_integer(user_id) and is_integer(draft_id) do
    from(d in ArticleDraft, where: d.id == ^draft_id and d.user_id == ^user_id)
    |> Repo.delete_all()

    :ok
  end

  def delete(_, _), do: :ok

  @doc "How many drafts the member currently holds."
  @spec count(integer()) :: non_neg_integer()
  def count(user_id) when is_integer(user_id) do
    Repo.aggregate(from(d in ArticleDraft, where: d.user_id == ^user_id), :count, :id)
  end

  @doc "How many more drafts the member may create (0–#{@max_drafts})."
  @spec quota_remaining(integer()) :: non_neg_integer()
  def quota_remaining(user_id) when is_integer(user_id) do
    max(@max_drafts - count(user_id), 0)
  end

  @doc """
  Every image id any draft is holding on to.

  The orphan image sweep asks this: an uploaded image belongs to no article
  until the post is submitted, so without it a draft left overnight is resumed
  with its pictures already deleted from disk.
  """
  @spec held_image_ids() :: [integer()]
  def held_image_ids do
    from(d in ArticleDraft, select: fragment("unnest(?)", d.image_ids))
    |> Repo.all()
  end

  @doc """
  Deletes drafts untouched for #{@stale_after_days} days. Returns the count.

  Run hourly from `Baudrate.Auth.SessionCleaner`. Their images become ordinary
  orphans once the row is gone and are collected by the image sweep on a later
  pass, so there is no file handling here.
  """
  @spec purge_stale() :: non_neg_integer()
  def purge_stale do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_after_days * 86_400, :second)

    {count, _} =
      from(d in ArticleDraft, where: d.updated_at < ^cutoff)
      |> Repo.delete_all()

    count
  end
end
