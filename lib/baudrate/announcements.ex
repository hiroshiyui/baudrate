defmodule Baudrate.Announcements do
  @moduledoc """
  Site announcements (Phase 7B): a short notice an admin shows on every
  page, and optionally sends as a notification.

  ## Rules

    * **Only an admin** creates or ends one, checked here rather than only in
      the LiveView.
    * **Everyone sees it**, guests included. A member's dismissal is a row
      (`Dismissal`), so it holds on every device; a guest's is kept in their
      own browser by the notice's hook and never reaches the server.
    * **A dismissal is final.** A notice that comes back after it was
      dismissed is the manufactured urgency ADR 0056 refuses; an admin who
      has something new to say posts a new announcement.
    * **The notification is optional and goes to members only** — active
      people, not bots, pending, banned or deleted accounts — and is sent in
      the background, so a large membership never holds up the admin's
      request.
    * At most three announcements are shown at once, newest first.
  """

  import Ecto.Query

  alias Baudrate.Announcements.{Announcement, Dismissal}
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @shown 3

  @doc """
  The live announcements `viewer` should see: not ended, not dismissed by
  them, newest first, at most #{@shown}. A guest (`nil`) sees every live one;
  their browser hides the ones they dismissed.
  """
  @spec active_for(User.t() | nil) :: [Announcement.t()]
  def active_for(viewer) do
    now = DateTime.utc_now(:second)

    from(a in Announcement,
      as: :announcement,
      where: is_nil(a.ends_at) or a.ends_at > ^now,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: @shown
    )
    |> exclude_dismissed(viewer)
    |> Repo.all()
  end

  defp exclude_dismissed(query, %User{id: user_id}) do
    where(
      query,
      [a],
      not exists(
        from(d in Dismissal,
          where: d.announcement_id == parent_as(:announcement).id and d.user_id == ^user_id,
          select: 1
        )
      )
    )
  end

  defp exclude_dismissed(query, _guest), do: query

  @doc "Every announcement, live and ended, newest first, for the admin page."
  @spec list_announcements(pos_integer()) :: [Announcement.t()]
  def list_announcements(limit \\ 50) do
    from(a in Announcement,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit,
      preload: [:created_by]
    )
    |> Repo.all()
  end

  @doc "Whether an announcement is still being shown at `now`."
  @spec live?(Announcement.t(), DateTime.t()) :: boolean()
  def live?(%Announcement{ends_at: nil}, _now), do: true
  def live?(%Announcement{ends_at: ends_at}, now), do: DateTime.compare(ends_at, now) == :gt

  @doc "A blank changeset for the admin form."
  def change_announcement(attrs \\ %{}),
    do: Announcement.create_changeset(%Announcement{}, attrs)

  @doc """
  Creates an announcement as `admin`. `attrs` carries `body` and an optional
  `ends_at`, which must be in the future.

  Options: `notify: true` also sends it as an `admin_announcement`
  notification to every active member.

  Returns `{:ok, announcement}`, `{:error, :unauthorized}` or
  `{:error, changeset}`.
  """
  @spec create_announcement(User.t(), map(), keyword()) ::
          {:ok, Announcement.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_announcement(admin, attrs, opts \\ [])

  def create_announcement(%User{} = admin, attrs, opts) do
    with :ok <- authorize(admin) do
      now = DateTime.utc_now(:second)

      %Announcement{created_by_id: admin.id}
      |> Announcement.create_changeset(attrs)
      |> Ecto.Changeset.validate_change(:ends_at, fn :ends_at, ends_at ->
        if DateTime.compare(ends_at, now) == :gt, do: [], else: [ends_at: "must be in the future"]
      end)
      |> Repo.insert()
      |> tap(fn
        {:ok, announcement} ->
          if Keyword.get(opts, :notify, false), do: notify(admin, announcement)

        _ ->
          :ok
      end)
    end
  end

  @doc """
  Ends a live announcement now, as `admin`. `{:error, :not_found}` when it
  does not exist or has already ended.
  """
  @spec end_announcement(User.t(), integer()) ::
          {:ok, Announcement.t()} | {:error, :unauthorized | :not_found}
  def end_announcement(%User{} = admin, id) when is_integer(id) do
    with :ok <- authorize(admin) do
      now = DateTime.utc_now(:second)

      from(a in Announcement,
        where: a.id == ^id and (is_nil(a.ends_at) or a.ends_at > ^now),
        select: a
      )
      |> Repo.update_all(set: [ends_at: now, updated_at: now])
      |> case do
        {1, [announcement]} -> {:ok, announcement}
        _ -> {:error, :not_found}
      end
    end
  end

  @doc """
  Records that `user` dismissed announcement `id`. Dismissing one that is
  unknown or already dismissed is a no-op; either way it is `:ok`, because
  the only effect is on what this member sees.
  """
  @spec dismiss(User.t(), integer()) :: :ok
  def dismiss(%User{id: user_id}, id) when is_integer(id) do
    if Repo.exists?(from(a in Announcement, where: a.id == ^id)) do
      Repo.insert_all(
        Dismissal,
        [%{announcement_id: id, user_id: user_id, inserted_at: DateTime.utc_now(:second)}],
        on_conflict: :nothing,
        conflict_target: [:user_id, :announcement_id]
      )
    end

    :ok
  end

  defp authorize(%User{role: %{name: "admin"}}), do: :ok
  defp authorize(_), do: {:error, :unauthorized}

  # Best-effort, like every other fan-out of notices: each one broadcasts and
  # may push, so it runs outside the admin's request.
  defp notify(admin, announcement) do
    Baudrate.Federation.schedule_federation_task(fn ->
      Baudrate.Notification.create_admin_announcement(admin, announcement)
    end)
  end
end
