defmodule Baudrate.Federation.Delivery do
  @moduledoc """
  Outgoing activity delivery for ActivityPub federation.

  Every outgoing activity, `Accept(Follow)` included, goes through the
  `DeliveryJob` queue, which retries with exponential backoff and survives a
  restart.

  ## Delivery Flow

  1. Content hook calls `enqueue_for_article/3` or `enqueue_for_followers/2`
  2. Follower inboxes are resolved, deduplicated by shared inbox
  3. `DeliveryJob` records are created (one per unique inbox), with
     DB-level deduplication via a partial unique index on `(inbox_url,
     actor_uri, activity_id)` for pending/failed jobs. The same activity is
     queued once per inbox; different activities from the same actor to the
     same inbox are all queued. (The index once omitted `activity_id`, which
     silently dropped every later activity while one was pending or retrying.)
  4. `DeliveryWorker` is woken when the transaction commits, and calls
     `deliver_one/1` for each job
  5. Job is signed with the actor's private key and POSTed to the inbox
  6. On failure, job is rescheduled with exponential backoff; the outcome is
     also recorded against the inbox's domain (`DeliveryCircuits`)
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Federation

  alias Baudrate.Federation.{
    DeliveryCircuits,
    DeliveryJob,
    Follower,
    HTTPClient,
    HTTPSignature,
    KeyStore,
    Validator
  }

  @as_context "https://www.w3.org/ns/activitystreams"

  # --- Follow responses ---

  @doc """
  Queues an `Accept(Follow)` to the remote actor's inbox.

  It used to be POSTed once from a background task, so a failed request, or a
  restart before the task ran, left the remote side's follow pending for good.
  Queued, it is retried like any other delivery and commits with the follower
  row (Phase 2C). Signed with the local actor's key at delivery time.
  """
  def enqueue_accept(follow_activity, local_actor_uri, remote_actor) do
    enqueue(build_accept(follow_activity, local_actor_uri), local_actor_uri, [remote_actor.inbox])
  end

  defp build_accept(follow_activity, local_actor_uri) do
    %{
      "@context" => @as_context,
      "id" => "#{local_actor_uri}#accept-#{Ecto.UUID.generate()}",
      "type" => "Accept",
      "actor" => local_actor_uri,
      "object" => follow_activity
    }
  end

  @doc """
  Queues a `Reject(Follow)` to the remote actor's inbox.

  Used when a Follow targets a non-federated board actor, or a user who has
  blocked the actor, so the remote actor learns the follow was declined
  rather than silently timing out.
  """
  def enqueue_reject(follow_activity, local_actor_uri, remote_actor) do
    enqueue(build_reject(follow_activity, local_actor_uri), local_actor_uri, [remote_actor.inbox])
  end

  defp build_reject(follow_activity, local_actor_uri) do
    %{
      "@context" => @as_context,
      "id" => "#{local_actor_uri}#reject-#{Ecto.UUID.generate()}",
      "type" => "Reject",
      "actor" => local_actor_uri,
      "object" => follow_activity
    }
  end

  # --- Queued Delivery ---

  @doc """
  Creates `DeliveryJob` records for each unique inbox URL, in one statement.

  Deduplicates by inbox URL so that multiple followers on the same
  instance sharing an inbox only result in one delivery.

  Call it inside the transaction that makes the change being federated: the
  jobs then commit or roll back with it, and a restart can never fall between
  the two (Phase 2C). It also sends a PostgreSQL notification on
  `DeliveryWorker.channel/0`. PostgreSQL delivers a notification only when the
  sending transaction commits, so the worker wakes exactly when the jobs
  become visible, and a rolled-back change wakes nobody.
  """
  def enqueue(activity_json, actor_uri, inboxes) when is_list(inboxes) do
    activity_text =
      case activity_json do
        json when is_binary(json) -> json
        map when is_map(map) -> Jason.encode!(map)
      end

    unique_inboxes = inboxes |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

    if unique_inboxes != [] do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      activity_id = DeliveryJob.activity_id_for(activity_text)

      rows =
        Enum.map(unique_inboxes, fn inbox_url ->
          %{
            activity_json: activity_text,
            activity_id: activity_id,
            inbox_url: inbox_url,
            domain: DeliveryJob.domain_of(inbox_url),
            actor_uri: actor_uri,
            status: "pending",
            attempts: 0,
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(DeliveryJob, rows,
        on_conflict: :nothing,
        conflict_target:
          {:unsafe_fragment,
           ~s|("inbox_url", "actor_uri", "activity_id") WHERE status IN ('pending', 'failed')|}
      )

      Repo.query!("SELECT pg_notify($1, '')", [Baudrate.Federation.DeliveryWorker.channel()])
    end

    {:ok, length(unique_inboxes)}
  end

  @doc """
  Signs and POSTs a delivery job to its target inbox.

  On success, marks the job as delivered. On failure, marks it as failed with
  exponential backoff scheduling, or abandons it at once when the response
  says a retry cannot help (`unsalvageable?/1`). Every HTTP outcome is also
  recorded against the inbox's domain (`DeliveryCircuits`).
  """
  def deliver_one(%DeliveryJob{} = job) do
    start_time = System.monotonic_time()
    metadata = %{inbox_url: job.inbox_url, actor_uri: job.actor_uri, job_id: job.id}

    :telemetry.execute(
      [:baudrate, :federation, :delivery, :start],
      %{system_time: System.system_time()},
      metadata
    )

    # Check domain blocklist before delivery
    inbox_uri = URI.parse(job.inbox_url)

    if inbox_uri.host && Validator.domain_blocked?(inbox_uri.host) do
      duration = System.monotonic_time() - start_time
      Logger.info("federation.delivery_skip: inbox=#{job.inbox_url} reason=domain_blocked")

      :telemetry.execute(
        [:baudrate, :federation, :delivery, :stop],
        %{duration: duration},
        Map.put(metadata, :status, :domain_blocked)
      )

      job
      |> DeliveryJob.mark_abandoned("domain_blocked")
      |> Repo.update()
    else
      result = do_deliver(job)

      DeliveryCircuits.record(
        job.domain || DeliveryJob.domain_of(job.inbox_url),
        DeliveryCircuits.outcome(result),
        elem(result, 1)
      )

      case result do
        {:ok, _response} ->
          duration = System.monotonic_time() - start_time
          Logger.info("federation.delivery_ok: inbox=#{job.inbox_url}")

          :telemetry.execute(
            [:baudrate, :federation, :delivery, :stop],
            %{duration: duration},
            Map.put(metadata, :status, :delivered)
          )

          job
          |> DeliveryJob.mark_delivered()
          |> Repo.update()

        {:error, reason} ->
          duration = System.monotonic_time() - start_time
          error_msg = inspect(reason)

          case reason do
            {:http_error, status, body} when body != "" ->
              Logger.warning(
                "federation.delivery_fail: inbox=#{job.inbox_url} status=#{status} body=#{String.slice(body, 0, 500)}"
              )

            _ ->
              Logger.warning(
                "federation.delivery_fail: inbox=#{job.inbox_url} error=#{error_msg}"
              )
          end

          :telemetry.execute(
            [:baudrate, :federation, :delivery, :stop],
            %{duration: duration},
            Map.merge(metadata, %{status: :failed, error: error_msg})
          )

          if unsalvageable?(reason) do
            job |> DeliveryJob.mark_abandoned(error_msg) |> Repo.update()
          else
            job |> DeliveryJob.mark_failed(error_msg) |> Repo.update()
          end
      end
    end
  end

  @doc """
  Records a delivery whose task was killed or crashed before `deliver_one/1`
  could record it, so the job counts an attempt like any other failure.

  Without this a killed task left its job untouched: a server slower than the
  task deadline had the same job retried on every poll, forever, and it was
  never abandoned.
  """
  @spec record_interrupted(integer(), :timeout | term()) :: :ok
  def record_interrupted(job_id, reason) do
    case Repo.get(DeliveryJob, job_id) do
      %DeliveryJob{status: status} = job when status in ["pending", "failed"] ->
        if reason == :timeout do
          DeliveryCircuits.record(job.domain, :unreachable, :timeout)
        end

        job |> DeliveryJob.mark_failed(inspect(reason)) |> Repo.update()
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Returns true when retrying a failed delivery cannot help: a 4xx response
  other than 401 (the remote server may not have fetched our key yet), 408 and
  429. Mastodon applies the same rule. Such a job is abandoned at once instead
  of taking five more attempts over fifteen hours.
  """
  @spec unsalvageable?(term()) :: boolean()
  def unsalvageable?({:http_error, status, _body})
      when status in 400..499 and status not in [401, 408, 429],
      do: true

  def unsalvageable?(_reason), do: false

  @doc """
  Abandons waiting jobs older than `delivery_max_age` (default 7 days).

  A job whose domain's circuit is open is held back without using up its
  attempts, so this is what eventually ends it when the server never comes
  back. Under ordinary retries a job is abandoned well before this age.
  Returns the number of jobs abandoned.
  """
  @spec expire_held_jobs() :: non_neg_integer()
  def expire_held_jobs do
    max_age =
      Application.get_env(:baudrate, Baudrate.Federation, [])
      |> Keyword.get(:delivery_max_age, 604_800)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    cutoff = DateTime.add(now, -max_age, :second)

    {count, _} =
      from(j in DeliveryJob,
        where: j.status in ["pending", "failed"] and j.inserted_at < ^cutoff
      )
      |> Repo.update_all(
        set: [
          status: "abandoned",
          last_error: "expired: not delivered within the maximum age",
          updated_at: now
        ]
      )

    count
  end

  defp do_deliver(%DeliveryJob{} = job) do
    case get_private_key(job.actor_uri) do
      {:ok, private_key_pem} ->
        key_id = "#{job.actor_uri}#main-key"

        headers =
          HTTPSignature.sign(:post, job.inbox_url, job.activity_json, private_key_pem, key_id)

        HTTPClient.post(job.inbox_url, job.activity_json, Map.to_list(headers))

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns inbox URLs for all followers of the given actor URI.

  Uses shared inbox when available, falls back to individual inbox.
  This provides shared inbox deduplication — multiple followers at the
  same instance result in a single inbox URL.
  """
  def resolve_follower_inboxes(actor_uri) do
    from(f in Follower,
      where: f.actor_uri == ^actor_uri,
      join: ra in assoc(f, :remote_actor),
      select: {ra.inbox, ra.shared_inbox}
    )
    |> Repo.all()
    |> Enum.map(fn {inbox, shared_inbox} ->
      if shared_inbox && shared_inbox != "", do: shared_inbox, else: inbox
    end)
    |> Enum.uniq()
  end

  @doc """
  Resolves follower inboxes for the actor and enqueues delivery jobs.
  """
  def enqueue_for_followers(activity_json, actor_uri) do
    inboxes = resolve_follower_inboxes(actor_uri)

    if inboxes != [] do
      enqueue(activity_json, actor_uri, inboxes)
    else
      {:ok, 0}
    end
  end

  @doc """
  Enqueues delivery for an article to all relevant inboxes.

  Resolves followers of both the article's author and all public boards
  the article is posted to, deduplicates by shared inbox, and creates
  delivery jobs.

  ## Options

    * `:remote_authors` — remote actors who must receive the activity
      themselves, such as the author of the remote article or comment being
      liked or replied to. Their followers are not involved, so without this
      an interaction with a remote post never reached its author. `nil`
      entries are ignored.
    * `:intent` — `:publish` (the default) applies the board federation gate
      to the author's own followers; `:withdraw` does not. Pass `:withdraw`
      for `Delete` and `Undo`, which must reach anyone who may hold the
      object even once the article no longer sits in a federated board.
  """
  def enqueue_for_article(activity_json, actor_uri, article, opts \\ []) do
    article = Repo.preload(article, [:boards, :user])

    # Collect inboxes from user followers (skip for remote articles with no local user)
    #
    # The board gate applies to the author's followers too. Only the board
    # fan-out below was filtered, so an article posted to a staff-only or
    # AP-disabled board was still delivered to everyone following its author —
    # with `to: as#Public`, because local articles are always `visibility:
    # "public"`. One unsolicited Follow of a local user was enough to receive
    # every private-board post they wrote. A board-less article stays public,
    # matching `ArticleHelpers.user_can_view_article?/2`.
    # A withdrawal is never gated. `Delete(Tombstone)` and `Undo` carry no
    # content — their whole purpose is to retract something a remote server
    # may already hold — so refusing to send one cannot protect anything, and
    # does real harm: when moderation took an article out of its last public
    # board, or an admin turned `ap_enabled` off, the author's later delete
    # was dropped and the post stayed published on every follower's server
    # forever. If a peer never had the object, the Delete is a no-op there.
    gated? = Keyword.get(opts, :intent, :publish) == :publish

    user_inboxes =
      if article.user && (not gated? or article_boards_federated?(article)) do
        user_uri = Federation.actor_uri(:user, article.user.username)
        resolve_follower_inboxes(user_uri)
      else
        []
      end

    # Collect inboxes from board followers (public boards only)
    board_inboxes =
      article.boards
      |> Enum.filter(&Board.federated?/1)
      |> Enum.flat_map(fn board ->
        board_uri = Federation.actor_uri(:board, board.slug)
        resolve_follower_inboxes(board_uri)
      end)

    author_inboxes =
      opts
      |> Keyword.get(:remote_authors, [])
      |> Enum.flat_map(fn
        %{shared_inbox: shared, inbox: inbox} ->
          if(is_binary(shared) and shared != "", do: [shared], else: List.wrap(inbox))

        _ ->
          []
      end)

    all_inboxes = Enum.uniq(user_inboxes ++ board_inboxes ++ author_inboxes)

    if all_inboxes != [] do
      enqueue(activity_json, actor_uri, all_inboxes)
    else
      {:ok, 0}
    end
  end

  @doc """
  Whether an article's content may leave this instance at all: board-less (a
  personal post, public by definition here) or in at least one federated
  board.

  Public because the boost fan-out (`Publisher.publish_article_boosted/2`)
  does not go through `enqueue_for_article/4` and needs the same predicate —
  an `Announce` names the article's URI, whose slug is derived from its
  title, so boosting a private-board post told the booster's remote
  followers the post exists and roughly what it is called.

  Remote authors are deliberately *not* gated by this — a reply or like on
  their article must still reach them, since it already exists on the
  fediverse with its own `ap_id` (the exception in CLAUDE.md's federation
  gate).
  """
  def article_boards_federated?(%{boards: boards}) when is_list(boards) do
    boards == [] or Enum.any?(boards, &Board.federated?/1)
  end

  # Fails closed. `enqueue_for_article/4` preloads `:boards`, so the clause
  # above always matches today; a caller that somehow arrives without the
  # association must not be answered "yes, federate it" by default.
  def article_boards_federated?(_article), do: false

  # --- Flag Delivery ---

  @doc """
  Delivers a Flag activity to a remote actor's inbox.

  Uses the site actor as the sender.
  """
  def deliver_flag(flag_json, remote_actor) do
    site_uri = Federation.actor_uri(:site, nil)
    inbox = remote_actor.shared_inbox || remote_actor.inbox
    enqueue(flag_json, site_uri, [inbox])
  end

  # --- Follow Delivery ---

  @doc """
  Delivers a Follow or Undo(Follow) activity to a remote actor's inbox.

  Uses the following user's actor as the sender.
  """
  def deliver_follow(follow_json, remote_actor, actor_uri) do
    inbox = remote_actor.shared_inbox || remote_actor.inbox
    enqueue(follow_json, actor_uri, [inbox])
  end

  # --- Shared Helpers ---

  @doc """
  Retrieves the private key PEM for signing outgoing requests.

  Dispatches based on the actor URI prefix to find the correct key:
  - `/ap/users/:username` → user's encrypted private key
  - `/ap/boards/:slug` → board's encrypted private key
  - `/ap/site` → site-level private key

  For an existing local actor that does not yet have a keypair, one is
  generated lazily (matching the lazy generation at the actor endpoint).
  Returns `{:ok, pem}`, `{:error, :unknown_actor}` when no such local actor
  exists, or `{:error, :no_private_key}` when the key cannot be materialized.
  """
  def get_private_key(actor_uri) do
    base = Federation.base_url()

    cond do
      String.starts_with?(actor_uri, "#{base}/ap/users/") ->
        username = actor_uri |> String.replace_prefix("#{base}/ap/users/", "")

        case Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
          nil -> {:error, :unknown_actor}
          user -> ensure_local_key(KeyStore.ensure_user_keypair(user))
        end

      String.starts_with?(actor_uri, "#{base}/ap/boards/") ->
        slug = actor_uri |> String.replace_prefix("#{base}/ap/boards/", "")

        case Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug) do
          nil -> {:error, :unknown_actor}
          board -> ensure_local_key(KeyStore.ensure_board_keypair(board))
        end

      String.starts_with?(actor_uri, "#{base}/ap/site") ->
        case KeyStore.ensure_site_keypair() do
          {:ok, _} -> normalize_key(KeyStore.decrypt_site_private_key())
          _ -> {:error, :no_private_key}
        end

      true ->
        {:error, :unknown_actor}
    end
  end

  # Lazily generates a keypair for a local actor that lacks one, then decrypts
  # it. New users whose user-signed activities (e.g. a Like on an article in a
  # federated board) are delivered to board followers may never have had their
  # actor fetched, so this is the point where their keypair is first created.
  # Normalizes the bare `:error` that `KeyStore.decrypt_private_key/1` returns
  # so the signing path never crashes with a `CaseClauseError`.
  defp ensure_local_key({:ok, entity}), do: normalize_key(KeyStore.decrypt_private_key(entity))
  defp ensure_local_key(_), do: {:error, :no_private_key}

  defp normalize_key({:ok, _pem} = ok), do: ok
  defp normalize_key(_), do: {:error, :no_private_key}

  @doc """
  Purges old completed and abandoned delivery jobs.

  Deletes `delivered` jobs older than 7 days and `abandoned` jobs older than
  30 days. Returns the total number of deleted rows.
  """
  def purge_completed_jobs do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    delivered_cutoff = DateTime.add(now, -7, :day)
    abandoned_cutoff = DateTime.add(now, -30, :day)

    {delivered_count, _} =
      from(j in DeliveryJob,
        where: j.status == "delivered" and j.inserted_at < ^delivered_cutoff
      )
      |> Repo.delete_all()

    {abandoned_count, _} =
      from(j in DeliveryJob,
        where: j.status == "abandoned" and j.inserted_at < ^abandoned_cutoff
      )
      |> Repo.delete_all()

    delivered_count + abandoned_count
  end
end
