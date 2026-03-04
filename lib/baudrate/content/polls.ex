defmodule Baudrate.Content.Polls do
  @moduledoc """
  Poll operations for articles.

  Manages poll creation, voting (local and remote), and denormalized
  counter maintenance.
  """

  import Ecto.Query
  alias Baudrate.Repo

  alias Baudrate.Content.{
    Poll,
    PollOption,
    PollVote
  }

  @doc """
  Returns the poll for an article, preloading options, or nil if none.
  """
  def get_poll_for_article(article_id) do
    Poll
    |> Repo.get_by(article_id: article_id)
    |> case do
      nil -> nil
      poll -> Repo.preload(poll, :options)
    end
  end

  @doc """
  Ensures a poll's `:options` association is loaded.
  """
  def preload_poll_options(%Poll{} = poll), do: Repo.preload(poll, :options)

  @doc """
  Returns the list of option IDs a user has voted for in a poll.
  """
  def get_user_poll_votes(poll_id, user_id) do
    from(v in PollVote,
      where: v.poll_id == ^poll_id and v.user_id == ^user_id,
      select: v.poll_option_id
    )
    |> Repo.all()
  end

  @doc """
  Casts a vote (or changes an existing vote) for a local user on a poll.

  For single-choice polls, `option_ids` must contain exactly one option.
  Deletes any previous votes by the user on this poll and inserts the new
  selections within a transaction. Denormalized counters on `poll_options`
  and `polls.voters_count` are recalculated.

  Returns `{:ok, poll}` with updated counters or `{:error, reason}`.
  """
  def cast_vote(%Poll{} = poll, user, option_ids) when is_list(option_ids) do
    if Poll.closed?(poll) do
      {:error, :poll_closed}
    else
      do_cast_vote(poll, user, option_ids)
    end
  end

  defp do_cast_vote(poll, user, option_ids) do
    valid_option_ids =
      from(o in PollOption, where: o.poll_id == ^poll.id, select: o.id)
      |> Repo.all()
      |> MapSet.new()

    requested = MapSet.new(option_ids)

    cond do
      not MapSet.subset?(requested, valid_option_ids) ->
        {:error, :invalid_options}

      poll.mode == "single" and MapSet.size(requested) != 1 ->
        {:error, :single_choice_requires_one}

      MapSet.size(requested) == 0 ->
        {:error, :no_options_selected}

      true ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        result =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:lock_poll, fn repo, _ ->
            poll_locked =
              from(p in Poll, where: p.id == ^poll.id, lock: "FOR UPDATE")
              |> repo.one()

            if poll_locked && !Poll.closed?(poll_locked) do
              {:ok, poll_locked}
            else
              {:error, :poll_closed}
            end
          end)
          |> Ecto.Multi.delete_all(
            :delete_old_votes,
            from(v in PollVote, where: v.poll_id == ^poll.id and v.user_id == ^user.id)
          )
          |> Ecto.Multi.insert_all(
            :insert_votes,
            PollVote,
            Enum.map(option_ids, fn option_id ->
              %{
                poll_id: poll.id,
                poll_option_id: option_id,
                user_id: user.id,
                inserted_at: now,
                updated_at: now
              }
            end)
          )
          |> Ecto.Multi.run(:recalc_counts, fn repo, _ ->
            do_recalc_poll_counts(repo, poll.id)
          end)
          |> Repo.transaction()

        case result do
          {:ok, %{recalc_counts: poll}} -> {:ok, poll}
          {:error, :lock_poll, :poll_closed, _} -> {:error, :poll_closed}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  @doc """
  Creates a remote poll vote received via ActivityPub.
  """
  def create_remote_poll_vote(attrs) do
    %PollVote{}
    |> PollVote.remote_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates denormalized poll counters from an inbound `Update(Question)`.

  Accepts a poll and a map with `voters_count` and a list of option maps
  with `text` and `votes_count`.
  """
  def update_remote_poll_counts(%Poll{} = poll, %{} = data) do
    poll = Repo.preload(poll, :options)

    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :poll,
      Ecto.Changeset.change(poll, voters_count: data[:voters_count] || 0)
    )
    |> Ecto.Multi.run(:options, fn repo, _ ->
      option_counts = data[:option_counts] || []

      Enum.reduce_while(option_counts, {:ok, :done}, fn %{text: text, votes_count: count}, acc ->
        case Enum.find(poll.options, &(&1.text == text)) do
          nil ->
            {:cont, acc}

          option ->
            case repo.update(Ecto.Changeset.change(option, votes_count: count)) do
              {:ok, _} -> {:cont, acc}
              {:error, changeset} -> {:halt, {:error, changeset}}
            end
        end
      end)
    end)
    |> Repo.transaction()
  end

  @doc """
  Recalculates denormalized vote counts on a poll and its options.
  Used by federation handlers after recording remote votes.
  """
  def recalc_poll_counts(poll_id) do
    do_recalc_poll_counts(Repo, poll_id)
  end

  defp do_recalc_poll_counts(repo, poll_id) do
    # Update each option's votes_count
    repo.query!(
      """
      UPDATE poll_options SET votes_count = (
        SELECT COUNT(*) FROM poll_votes WHERE poll_votes.poll_option_id = poll_options.id
      )
      WHERE poll_options.poll_id = $1
      """,
      [poll_id]
    )

    # Update poll voters_count (distinct voters)
    repo.query!(
      """
      UPDATE polls SET voters_count = (
        SELECT COUNT(DISTINCT COALESCE(user_id::text, remote_actor_id::text))
        FROM poll_votes WHERE poll_votes.poll_id = $1
      )
      WHERE polls.id = $1
      """,
      [poll_id]
    )

    poll =
      Poll
      |> repo.get!(poll_id)
      |> repo.preload(:options, force: true)

    {:ok, poll}
  end

  @doc """
  Inserts a poll into an Ecto.Multi pipeline if poll attrs are provided.
  Returns the multi unchanged when `poll_attrs` is nil.
  """
  def maybe_insert_poll(multi, nil), do: multi

  def maybe_insert_poll(multi, poll_attrs) do
    Ecto.Multi.run(multi, :poll, fn repo, %{article: article} ->
      attrs = Map.put(poll_attrs, :article_id, article.id)

      changeset =
        if Map.has_key?(poll_attrs, :ap_id) or Map.has_key?(poll_attrs, :voters_count) do
          Poll.remote_changeset(%Poll{}, attrs)
        else
          Poll.changeset(%Poll{}, attrs)
        end

      repo.insert(changeset)
    end)
  end
end
