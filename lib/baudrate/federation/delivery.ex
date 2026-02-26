defmodule Baudrate.Federation.Delivery do
  @moduledoc """
  Outgoing activity delivery for ActivityPub federation.

  Handles both immediate delivery (e.g., `Accept(Follow)`) and queued
  delivery via `DeliveryJob` records. The queue provides retry with
  exponential backoff for reliable delivery to remote inboxes.

  ## Delivery Flow

  1. Content hook calls `enqueue_for_article/3` or `enqueue_for_followers/2`
  2. Follower inboxes are resolved, deduplicated by shared inbox
  3. `DeliveryJob` records are created (one per unique inbox), with
     DB-level deduplication via a partial unique index on `(inbox_url,
     actor_uri)` for pending/failed jobs
  4. `DeliveryWorker` polls and calls `deliver_one/1` for each job
  5. Job is signed with the actor's private key and POSTed to the inbox
  6. On failure, job is rescheduled with exponential backoff
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Federation

  alias Baudrate.Federation.{
    DeliveryJob,
    Follower,
    HTTPClient,
    HTTPSignature,
    KeyStore,
    Validator
  }

  @as_context "https://www.w3.org/ns/activitystreams"

  # --- Immediate Delivery (Accept) ---

  @doc """
  Sends an Accept(Follow) activity to the remote actor's inbox.

  Builds the JSON-LD, signs it with the local actor's private key,
  and POSTs to `remote_actor.inbox`.
  """
  def send_accept(follow_activity, local_actor_uri, remote_actor) do
    accept = build_accept(follow_activity, local_actor_uri)
    body = Jason.encode!(accept)

    with {:ok, private_key_pem} <- get_private_key(local_actor_uri),
         key_id = "#{local_actor_uri}#main-key",
         headers = HTTPSignature.sign(:post, remote_actor.inbox, body, private_key_pem, key_id) do
      HTTPClient.post(remote_actor.inbox, body, Map.to_list(headers))
    end
  end

  defp build_accept(follow_activity, local_actor_uri) do
    %{
      "@context" => @as_context,
      "id" => "#{local_actor_uri}#accept-#{System.unique_integer([:positive])}",
      "type" => "Accept",
      "actor" => local_actor_uri,
      "object" => follow_activity
    }
  end

  # --- Queued Delivery ---

  @doc """
  Creates `DeliveryJob` records for each unique inbox URL.

  Deduplicates by inbox URL so that multiple followers on the same
  instance sharing an inbox only result in one delivery.
  """
  def enqueue(activity_json, actor_uri, inboxes) when is_list(inboxes) do
    activity_text =
      case activity_json do
        json when is_binary(json) -> json
        map when is_map(map) -> Jason.encode!(map)
      end

    unique_inboxes = Enum.uniq(inboxes)

    Enum.each(unique_inboxes, fn inbox_url ->
      %DeliveryJob{}
      |> DeliveryJob.create_changeset(%{
        activity_json: activity_text,
        inbox_url: inbox_url,
        actor_uri: actor_uri
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target:
          {:unsafe_fragment, ~s|("inbox_url", "actor_uri") WHERE status IN ('pending', 'failed')|}
      )
    end)

    {:ok, length(unique_inboxes)}
  end

  @doc """
  Signs and POSTs a delivery job to its target inbox.

  On success, marks the job as delivered. On failure, marks it as
  failed with exponential backoff scheduling.
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
      case do_deliver(job) do
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
          Logger.warning("federation.delivery_fail: inbox=#{job.inbox_url} error=#{error_msg}")

          :telemetry.execute(
            [:baudrate, :federation, :delivery, :stop],
            %{duration: duration},
            Map.merge(metadata, %{status: :failed, error: error_msg})
          )

          job
          |> DeliveryJob.mark_failed(error_msg)
          |> Repo.update()
      end
    end
  end

  defp do_deliver(%DeliveryJob{} = job) do
    with {:ok, private_key_pem} <- get_private_key(job.actor_uri) do
      key_id = "#{job.actor_uri}#main-key"

      headers =
        HTTPSignature.sign(:post, job.inbox_url, job.activity_json, private_key_pem, key_id)

      HTTPClient.post(job.inbox_url, job.activity_json, Map.to_list(headers))
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
  """
  def enqueue_for_article(activity_json, actor_uri, article) do
    article = Repo.preload(article, [:boards, :user])

    # Collect inboxes from user followers
    user_uri = Federation.actor_uri(:user, article.user.username)
    user_inboxes = resolve_follower_inboxes(user_uri)

    # Collect inboxes from board followers (public boards only)
    board_inboxes =
      article.boards
      |> Enum.filter(&(&1.min_role_to_view == "guest" and &1.ap_enabled))
      |> Enum.flat_map(fn board ->
        board_uri = Federation.actor_uri(:board, board.slug)
        resolve_follower_inboxes(board_uri)
      end)

    all_inboxes = Enum.uniq(user_inboxes ++ board_inboxes)

    if all_inboxes != [] do
      enqueue(activity_json, actor_uri, all_inboxes)
    else
      {:ok, 0}
    end
  end

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

  # --- Block Delivery ---

  @doc """
  Delivers a Block or Undo(Block) activity to a remote actor's inbox.

  Uses the blocking user's actor as the sender.
  """
  def deliver_block(block_json, remote_actor, actor_uri) do
    inbox = remote_actor.shared_inbox || remote_actor.inbox
    enqueue(block_json, actor_uri, [inbox])
  end

  # --- Shared Helpers ---

  @doc """
  Retrieves the private key PEM for signing outgoing requests.

  Dispatches based on the actor URI prefix to find the correct key:
  - `/ap/users/:username` → user's encrypted private key
  - `/ap/boards/:slug` → board's encrypted private key
  - `/ap/site` → site-level private key
  """
  def get_private_key(actor_uri) do
    base = Federation.base_url()

    cond do
      String.starts_with?(actor_uri, "#{base}/ap/users/") ->
        username = actor_uri |> String.replace_prefix("#{base}/ap/users/", "")
        user = Baudrate.Repo.get_by!(Baudrate.Setup.User, username: username)
        KeyStore.decrypt_private_key(user)

      String.starts_with?(actor_uri, "#{base}/ap/boards/") ->
        slug = actor_uri |> String.replace_prefix("#{base}/ap/boards/", "")
        board = Baudrate.Repo.get_by!(Baudrate.Content.Board, slug: slug)
        KeyStore.decrypt_private_key(board)

      String.starts_with?(actor_uri, "#{base}/ap/site") ->
        KeyStore.decrypt_site_private_key()

      true ->
        {:error, :unknown_actor}
    end
  end

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
