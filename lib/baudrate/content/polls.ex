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
  Fetches a poll by its ActivityPub ID, current or previous, preloading
  options.

  Phase 3B rewrote every local poll's `ap_id` from `<article-uri>#poll` to
  `/ap/polls/:id` (ADR 0050) and kept the old value in `legacy_ap_id`. A peer
  that learned the poll before the rewrite still addresses it by the old URI,
  so both have to resolve. `legacy_ap_id` is matched, never asserted.
  """
  def get_poll_by_ap_id(ap_id) when is_binary(ap_id) do
    from(p in Poll,
      where: p.ap_id == ^ap_id or p.legacy_ap_id == ^ap_id,
      order_by: [asc: fragment("? = ?", p.legacy_ap_id, ^ap_id)],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      poll -> Repo.preload(poll, :options)
    end
  end

  @doc """
  Publishes final counts for every local poll that has closed since the last
  run, and marks it so the announcement happens once.

  Runs hourly from `Auth.SessionCleaner`. A poll has no "closed" state —
  `Poll.closed?/1` reads the clock, deliberately — so this is the one place
  that treats closing as an *event*, and `final_update_sent_at` is what makes
  it happen exactly once rather than every hour or, on a missed run, never.
  The same claim tells the poll's author and its local voters that it closed
  (`poll_closed`, ADR 0069).

  Remote polls are skipped: their counts are the originating instance's to
  announce, and ours would be a claim about somebody else's object.

  Returns the number of polls announced.
  """
  @spec sweep_closed_polls() :: non_neg_integer()
  def sweep_closed_polls do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(p in Poll,
      join: a in Baudrate.Content.Article,
      on: a.id == p.article_id,
      where:
        is_nil(p.final_update_sent_at) and not is_nil(p.closes_at) and p.closes_at <= ^now and
          is_nil(a.remote_actor_id) and is_nil(a.deleted_at),
      select: p.id
    )
    |> Repo.all()
    |> Enum.reduce(0, fn poll_id, sent -> announce_closed_poll(poll_id, now, sent) end)
  end

  defp announce_closed_poll(poll_id, now, sent) do
    poll = Poll |> Repo.get(poll_id) |> Repo.preload([:options, article: [:boards, :user]])

    if poll && poll.article do
      Baudrate.Federation.Publisher.publish_poll_closed(poll, poll.article)

      # Stamped whether or not the gate lets the activity out: the question
      # this column answers is "has this poll's close been handled", and a
      # poll in a private board has been handled by deciding not to announce
      # it. Stamping only on delivery would retry it every hour for ever.
      #
      # The stamp is a claim — only the run that sets it tells anyone — so
      # the author and the voters hear once. It is not in one transaction
      # with the notices because creating a notification broadcasts and
      # schedules a push, and neither may happen for a row not yet
      # committed; a crash between the two loses the notices, which is the
      # better failure than sending them twice (ADR 0069).
      {claimed, _} =
        from(p in Poll, where: p.id == ^poll.id and is_nil(p.final_update_sent_at))
        |> Repo.update_all(set: [final_update_sent_at: now])

      if claimed == 1 do
        Baudrate.Notification.Hooks.notify_poll_closed(
          poll.article,
          [poll.article.user_id | local_voter_ids(poll.id)]
        )
      end

      sent + 1
    else
      sent
    end
  end

  # Who voted in a poll, for one purpose: telling them it closed (ADR 0069,
  # amending ADR 0048). This and `get_user_poll_votes/2` are the only reads of
  # `poll_votes.user_id`, and the ids go nowhere but the notification rows,
  # each of which tells its recipient only what they already knew — that they
  # voted. `poll_anonymity_test.exs` fails on a third reader.
  defp local_voter_ids(poll_id) do
    from(v in PollVote,
      where: v.poll_id == ^poll_id and not is_nil(v.user_id),
      distinct: true,
      select: v.user_id
    )
    |> Repo.all()
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
    # A moved, silenced or suspended account cannot vote (ADR 0029).
    gate = Baudrate.Auth.ensure_can_interact(user)

    cond do
      Poll.closed?(poll) -> {:error, :poll_closed}
      gate != :ok -> gate
      true -> do_cast_vote(poll, user, option_ids)
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
          |> Ecto.Multi.run(:federation, fn repo, _ ->
            federate_vote(repo, poll, user, option_ids)
          end)
          |> Repo.transaction()

        case result do
          {:ok, %{recalc_counts: poll}} -> {:ok, poll}
          {:error, :lock_poll, :poll_closed, _} -> {:error, :poll_closed}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  # A vote on a remote article's poll is sent to its author, and its delivery
  # job commits with the vote (Phase 2C). Votes on local polls are not
  # federated one by one.
  defp federate_vote(repo, poll, user, option_ids) do
    case repo.get(Baudrate.Content.Article, poll.article_id) do
      %{remote_actor_id: remote_actor_id} = article when not is_nil(remote_actor_id) ->
        voted_options =
          repo.all(
            from(o in PollOption,
              where: o.poll_id == ^poll.id and o.id in ^option_ids,
              order_by: [asc: o.position]
            )
          )

        Baudrate.Federation.Publisher.publish_vote(user, article, voted_options)
        {:ok, :enqueued}

      _ ->
        {:ok, :local}
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

    # Update poll voters_count (distinct voters).
    #
    # Counts the pair, not a coalesced string. `users.id` and
    # `remote_actors.id` are independent sequences, so `COALESCE(user_id::text,
    # remote_actor_id::text)` gave `'3'` for both local user 3 and remote actor
    # 3 and counted them once — the common case on a small instance, where both
    # sequences sit in the same low range. The undercount was shown to every
    # reader and published to the fediverse as `votersCount`.
    repo.query!(
      """
      UPDATE polls SET voters_count = (
        SELECT COUNT(DISTINCT (user_id, remote_actor_id))
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
