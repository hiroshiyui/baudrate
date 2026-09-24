defmodule Baudrate.Federation do
  @moduledoc """
  The Federation context provides ActivityPub integration for Baudrate.

  ## Features

  - **Actor management** — User (`Person`) and Board (`Group`) AP actors with
    key pairs, WebFinger/NodeInfo discovery, and AP JSON-LD representation
  - **Inbound processing** — HTTP Signature verification, inbox handling for
    Follow, Create, Like, Announce, Delete, Update, Move, and their Undo variants;
    Mastodon/Lemmy compatibility (Page→Article, embedded Announce objects,
    attributedTo arrays, content warnings)
  - **Outbound delivery** — DB-backed delivery queue with exponential backoff
    retry; activities pushed to remote followers' inboxes on article/comment
    CRUD, likes, follows, and polls
  - **Collections** — paginated OrderedCollection endpoints for outbox,
    followers, following, boards index, article replies, and search
  - **User follows** — local users can follow remote actors via Follow/Undo(Follow)
    and local users via auto-accepted follows; both share the `user_follows` table
  - **Personal timeline** — incoming Create activities from followed actors stored
    as `TimelineItem` records; union query merges remote timeline items, local
    articles from followed users, and comment participation
  - **Instance moderation** — blocking a domain and suspending a single remote
    actor (ADR 0030), both named on this facade because they change what every
    visitor sees and who this instance will talk to (ADR 0047)
  - **Public API** — AP endpoints double as public API; accepts `application/json`,
    CORS enabled on GET, `Vary: Accept` on content-negotiated endpoints

  Non-federated boards are excluded from all federation endpoints — WebFinger,
  actor profiles, outbox, inbox, followers, and audience resolution all
  return 404 or skip them. The gate is `Baudrate.Content.Board.federated?/1`,
  which requires `min_role_to_view == "guest"` **and** `ap_enabled`, so
  turning federation off for a guest-readable board takes it out of all of
  them. Articles that live only in non-federated boards are likewise hidden
  from the user outbox and the article endpoints, and are not named in the
  `cc`/`audience` of any object we build (ADR 0004). A withdrawal —
  `Delete(Tombstone)` or `Undo` — is deliberately never gated, because it
  carries no content and refusing one would leave the post published on every
  follower's server for good.

  ## Actor Mapping

    * `User` → `Person`
    * `Board` → `Group`
    * Site → `Organization`
    * `Article` → `Article`

  ## URI Scheme

    * `/ap/users/:username` — user actor
    * `/ap/boards/:slug` — board actor
    * `/ap/boards` — boards index
    * `/ap/site` — site actor
    * `/ap/articles/:slug` — article object
    * `/ap/articles/:slug/replies` — article replies
    * `/ap/search?q=...` — search
    * `/ap/inbox` — shared inbox (POST)
    * `/ap/users/:username/inbox` — user inbox (POST)
    * `/ap/boards/:slug/inbox` — board inbox (POST)
    * `/ap/users/:username/outbox` — user outbox (GET, paginated)
    * `/ap/boards/:slug/outbox` — board outbox (GET, paginated)
    * `/ap/users/:username/followers` — user followers (GET, paginated)
    * `/ap/users/:username/following` — user following (GET, always empty)
    * `/ap/boards/:slug/followers` — board followers (GET, paginated)
    * `/ap/boards/:slug/following` — board following (GET, paginated)

  This module is a facade — all implementations live in focused sub-modules
  under `Baudrate.Federation.*`:

    * `Federation.Discovery` — WebFinger, NodeInfo, remote actor lookup
    * `Federation.ActorRenderer` — JSON-LD actor representations (Person, Group, Organization)
    * `Federation.ObjectBuilder` — JSON-LD objects for articles, comments and polls
    * `Federation.Collections` — outbox, followers/following, boards, search collections
    * `Federation.Follows` — inbound followers, user/board follows, local follows
    * `Federation.Timeline` — timeline items CRUD, timeline item replies, likes, boosts
    * `Federation.InboxHandler` — inbound activity dispatch
    * `Federation.Publisher` — outbound activity building and delivery enqueuing
    * `Federation.Delivery` / `DeliveryWorker` — retry queue and HTTP delivery
    * `Federation.ActorResolver` — remote actor resolution and caching
    * `Federation.HTTPSignature` — HTTP Signature signing and verification
    * `Federation.KeyStore` / `KeyVault` — keypair management, encrypted storage
    * `Federation.Validator` — AP payload validation
    * `Federation.Visibility` — visibility derivation from to/cc addressing, and back
    * `Federation.Mentions` — `@user@domain` handles into `Mention` tags, `cc`
      and delivery targets, behind the board gate (ADR 0051)
    * `Federation.Context` — every JSON-LD `@context` this instance publishes,
      and the `baudrate:` extension terms
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Content.Board

  alias Baudrate.Federation.{
    Announce,
    Delivery,
    DomainBlocks,
    KeyStore,
    Publisher,
    RemoteActors
  }

  alias Baudrate.Federation.{
    ActorRenderer,
    Collections,
    Discovery,
    Timeline,
    Follows,
    ObjectBuilder,
    ReplyImages
  }

  # --- URI Utilities ---

  @doc """
  Returns the base URL from the endpoint configuration.
  """
  def base_url do
    BaudrateWeb.Endpoint.url()
  end

  @doc """
  Builds an actor URI for the given type and identifier.

  ## Examples

      iex> actor_uri(:user, "alice")
      "https://example.com/ap/users/alice"

      iex> actor_uri(:board, "sysop")
      "https://example.com/ap/boards/sysop"

      iex> actor_uri(:site, nil)
      "https://example.com/ap/site"

  `:article`, `:comment` and `:poll` are objects rather than actors; they live
  here because every URI this instance mints is built in one place, and an id
  that is minted in two places drifts. Each one is a path a remote server can
  dereference — never a fragment (ADR 0050).
  """
  def actor_uri(:user, username), do: "#{base_url()}/ap/users/#{username}"
  def actor_uri(:board, slug), do: "#{base_url()}/ap/boards/#{slug}"
  def actor_uri(:site, _), do: "#{base_url()}/ap/site"
  def actor_uri(:article, slug), do: "#{base_url()}/ap/articles/#{slug}"
  def actor_uri(:comment, id), do: "#{base_url()}/ap/comments/#{id}"
  def actor_uri(:poll, id), do: "#{base_url()}/ap/polls/#{id}"

  # --- Discovery ---

  defdelegate webfinger(resource), to: Discovery
  defdelegate nodeinfo_links(), to: Discovery
  defdelegate nodeinfo(), to: Discovery
  defdelegate nodeinfo(version), to: Discovery
  defdelegate get_remote_actor(id), to: Discovery
  defdelegate get_remote_actor_by_ap_id(ap_id), to: Discovery
  defdelegate remote_actors_by_ap_ids(ap_ids), to: Discovery
  defdelegate lookup_remote_actor(query), to: Discovery
  defdelegate fetch_remote_object(url), to: Discovery
  defdelegate lookup_remote_object(url), to: Discovery

  # --- Actor Rendering ---

  defdelegate user_actor(user), to: ActorRenderer
  defdelegate user_tombstone(user), to: ActorRenderer
  defdelegate board_actor(board), to: ActorRenderer
  defdelegate site_actor(), to: ActorRenderer
  defdelegate render_bio_html(bio), to: ActorRenderer

  # --- Objects ---

  defdelegate article_object(article), to: ObjectBuilder
  defdelegate comment_object(comment), to: ObjectBuilder
  defdelegate poll_object(poll), to: ObjectBuilder

  # --- Collections ---

  defdelegate user_outbox(user, page_params \\ %{}), to: Collections
  defdelegate board_outbox(board, page_params \\ %{}), to: Collections
  defdelegate site_outbox(page_params \\ %{}), to: Collections
  defdelegate followers_collection(actor_uri, page_params \\ %{}), to: Collections
  defdelegate following_collection(actor_uri, page_params \\ %{}), to: Collections
  defdelegate boards_collection(), to: Collections
  defdelegate article_replies(article, page_params \\ %{}), to: Collections
  defdelegate search_collection(query, page_params), to: Collections

  # --- Inbound Followers ---

  defdelegate create_follower(actor_uri, remote_actor, activity_id, opts \\ []), to: Follows
  defdelegate refresh_follow(actor_uri, remote_actor, activity_id), to: Follows
  defdelegate list_follow_requests(user), to: Follows
  defdelegate approve_remote_follower(user, follower_row_id), to: Follows
  defdelegate approve_local_follower(user, follower_user_id), to: Follows
  defdelegate approve_all_follow_requests(user), to: Follows
  defdelegate local_follow_state(user_id, followed_user_id), to: Follows
  defdelegate delete_follower(actor_uri, follower_uri), to: Follows
  defdelegate delete_followers_by_remote(remote_actor_ap_id), to: Follows
  defdelegate follower_exists?(actor_uri, follower_uri), to: Follows
  defdelegate list_followers(actor_uri), to: Follows
  defdelegate count_followers(actor_uri), to: Follows

  # --- User Follows (Outbound) ---

  defdelegate create_user_follow(user, remote_actor, opts \\ []), to: Follows
  defdelegate follow_remote_actor(user, remote_actor, opts \\ []), to: Follows
  defdelegate unfollow_remote_actor(user, remote_actor), to: Follows
  defdelegate accept_user_follow(follow_ap_id, signer \\ nil), to: Follows
  defdelegate reject_user_follow(follow_ap_id, signer \\ nil), to: Follows
  defdelegate delete_user_follow(user, remote_actor), to: Follows
  defdelegate sever_remote_follows(user, remote_actor), to: Follows
  defdelegate list_followers_of_user(user), to: Follows
  defdelegate remove_local_follower(user, follower_user_id), to: Follows
  defdelegate remove_remote_follower(user, follower_row_id), to: Follows
  defdelegate get_user_follow(user_id, remote_actor_id), to: Follows
  defdelegate get_user_follow_with_actor(user_id, remote_actor_id), to: Follows
  defdelegate get_user_follow_by_ap_id(ap_id), to: Follows
  defdelegate user_follows?(user_id, remote_actor_id), to: Follows
  defdelegate user_follows_accepted?(user_id, remote_actor_id), to: Follows
  defdelegate list_user_follows(user_id, opts \\ []), to: Follows
  defdelegate count_user_follows(user_id), to: Follows

  # --- Board Follows ---

  defdelegate create_board_follow(board, remote_actor), to: Follows
  defdelegate follow_remote_actor_as_board(board, remote_actor), to: Follows
  defdelegate unfollow_remote_actor_as_board(board, remote_actor), to: Follows
  defdelegate accept_board_follow(follow_ap_id, signer \\ nil), to: Follows
  defdelegate reject_board_follow(follow_ap_id, signer \\ nil), to: Follows
  defdelegate delete_board_follow(board, remote_actor), to: Follows
  defdelegate get_board_follow(board_id, remote_actor_id), to: Follows
  defdelegate get_board_follow_with_actor(board_id, remote_actor_id), to: Follows
  defdelegate get_board_follow_by_ap_id(ap_id), to: Follows
  defdelegate board_follows_actor?(board_id, remote_actor_id), to: Follows
  defdelegate boards_following_actor(remote_actor_id), to: Follows
  defdelegate list_board_follows(board_id, opts \\ []), to: Follows
  defdelegate count_board_follows(board_id), to: Follows

  # --- Local User Follows ---

  defdelegate local_followers_of_remote_actor(remote_actor_id), to: Follows
  defdelegate create_local_follow(follower, followed, opts \\ []), to: Follows
  defdelegate delete_local_follow(follower, followed), to: Follows
  defdelegate get_local_follow(follower_user_id, followed_user_id), to: Follows
  defdelegate batch_local_follow_states(follower_user_id, followed_user_ids), to: Follows
  defdelegate local_follows?(user_id, followed_user_id), to: Follows
  defdelegate local_followers_of_user(followed_user_id), to: Follows
  defdelegate migrate_timeline_items(old_actor_id, new_actor_id), to: Timeline

  # --- Timeline Items ---

  defdelegate create_timeline_item(attrs), to: Timeline
  defdelegate list_timeline_items(user, opts \\ []), to: Timeline
  defdelegate get_timeline_item_by_ap_id(ap_id), to: Timeline
  defdelegate soft_delete_timeline_item_by_ap_id(ap_id, remote_actor_id), to: Timeline
  defdelegate cleanup_timeline_items_for_actor(remote_actor_id), to: Timeline
  defdelegate timeline_item_accessible?(user, timeline_item), to: Timeline
  defdelegate create_timeline_item_reply(timeline_item, user, body, opts \\ []), to: Timeline
  defdelegate list_timeline_item_replies(timeline_item_id), to: Timeline
  defdelegate count_timeline_item_replies(timeline_item_ids), to: Timeline

  # --- Reply Images ---

  defdelegate create_reply_image(attrs), to: ReplyImages
  defdelegate delete_reply_image(image), to: ReplyImages
  defdelegate get_reply_image!(id), to: ReplyImages
  defdelegate update_reply_image_alt(image_id, user_id, alt), to: ReplyImages
  defdelegate delete_orphan_reply_images(cutoff), to: ReplyImages
  defdelegate toggle_timeline_item_like(user, timeline_item_id), to: Timeline
  defdelegate timeline_item_likes_by_user(user_id, timeline_item_ids), to: Timeline
  defdelegate toggle_timeline_item_boost(user, timeline_item_id), to: Timeline
  defdelegate timeline_item_boosts_by_user(user_id, timeline_item_ids), to: Timeline

  # --- Announces ---

  @doc """
  Creates an announce (boost) record for a remote actor.
  """
  def create_announce(attrs) do
    %Announce{}
    |> Announce.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes an announce record by its ActivityPub ID.
  """
  def delete_announce_by_ap_id(ap_id) when is_binary(ap_id) do
    from(a in Announce, where: a.ap_id == ^ap_id)
    |> Repo.delete_all()
  end

  @doc """
  Deletes an announce record by its ActivityPub ID, scoped to the given remote actor.
  Returns `{count, nil}` — only deletes if both ap_id and remote_actor_id match.
  """
  def delete_announce_by_ap_id(ap_id, remote_actor_id) when is_binary(ap_id) do
    from(a in Announce,
      where: a.ap_id == ^ap_id and a.remote_actor_id == ^remote_actor_id
    )
    |> Repo.delete_all()
  end

  @doc """
  Returns the count of announces for the given target AP ID.
  """
  def count_announces(target_ap_id) when is_binary(target_ap_id) do
    Repo.one(from(a in Announce, where: a.target_ap_id == ^target_ap_id, select: count(a.id))) ||
      0
  end

  # --- Board Resolution ---

  @doc """
  Resolves a local board from audience/to/cc fields in an ActivityPub object.

  Scans the list of URIs for one matching the local board actor pattern
  `/ap/boards/:slug` and returns the board if found.
  """
  def resolve_board_from_audience(uris) when is_list(uris) do
    board_prefix = "#{base_url()}/ap/boards/"

    uris
    |> List.flatten()
    |> Enum.find_value(fn uri ->
      case uri do
        <<^board_prefix::binary, slug::binary>> ->
          if Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug) do
            board = Repo.get_by(Board, slug: slug)
            if board && Board.federated?(board), do: board
          end

        _ ->
          nil
      end
    end)
  end

  def resolve_board_from_audience(_), do: nil

  # --- Actor Cleanup ---

  @doc """
  Soft-deletes all content authored by a remote actor when that actor is deleted.

  Marks articles, comments, and direct messages from the actor as deleted
  by setting their `deleted_at` timestamp.
  """
  def cleanup_deleted_actor(remote_actor_ap_id) do
    alias Baudrate.Federation.RemoteActor

    case Repo.get_by(RemoteActor, ap_id: remote_actor_ap_id) do
      nil ->
        :ok

      actor ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        from(a in Baudrate.Content.Article,
          where: a.remote_actor_id == ^actor.id and is_nil(a.deleted_at)
        )
        |> Repo.update_all(set: [deleted_at: now])

        from(c in Baudrate.Content.Comment,
          where: c.remote_actor_id == ^actor.id and is_nil(c.deleted_at)
        )
        |> Repo.update_all(set: [deleted_at: now])

        from(dm in Baudrate.Messaging.DirectMessage,
          where: dm.sender_remote_actor_id == ^actor.id and is_nil(dm.deleted_at)
        )
        |> Repo.update_all(set: [deleted_at: now])

        Timeline.cleanup_timeline_items_for_actor(actor.id)

        :ok
    end
  end

  # --- Instance moderation ---
  #
  # Blocking a domain and suspending a remote actor change what every visitor
  # can see and who this instance will talk to, so they belong on the facade:
  # it is the index of every way a context changes the world (ADR 0047). The
  # read models behind the same screens — `DeliveryStats`, `InstanceStats`,
  # `BlocklistAudit`, the listings — stay addressed directly, because nothing
  # outside `/admin` asks for them.

  @doc """
  Blocks a domain instance-wide (ADR 0030). See `Federation.DomainBlocks`.
  """
  defdelegate block_domain(domain, blocked_by \\ nil, attrs \\ %{}), to: DomainBlocks

  @doc """
  Lifts a domain block. Content becomes visible again by itself (ADR 0030).
  """
  defdelegate unblock_domain(block), to: DomainBlocks

  @doc """
  Suspends one remote actor instance-wide (ADR 0030, decision 6).
  """
  defdelegate suspend_remote_actor(actor, suspended_by, reason),
    to: RemoteActors,
    as: :suspend

  @doc """
  Lifts a remote actor's suspension.
  """
  defdelegate unsuspend_remote_actor(actor), to: RemoteActors, as: :unsuspend

  @doc """
  Queues a `Flag` activity to a remote actor's instance. See `Federation.Delivery`.
  """
  defdelegate deliver_flag(flag, remote_actor), to: Delivery

  # --- Key Rotation ---

  @doc """
  Rotates the keypair for an actor and distributes the new public key
  to followers via an `Update` activity.

  ## Parameters

    * `actor_type` — `:user`, `:board`, or `:site`
    * `entity` — the user/board struct (ignored for `:site`)

  Returns `{:ok, updated_entity}` or `{:error, reason}`.
  """
  @spec rotate_keys(:user | :board | :site, term()) :: {:ok, term()} | {:error, term()}
  def rotate_keys(actor_type, entity) do
    federate(
      fn -> do_rotate(actor_type, entity) end,
      &Publisher.publish_actor_updated(actor_type, &1)
    )
  end

  defp do_rotate(:user, user), do: KeyStore.rotate_user_keypair(user)
  defp do_rotate(:board, board), do: KeyStore.rotate_board_keypair(board)
  defp do_rotate(:site, _), do: KeyStore.rotate_site_keypair()

  # --- Actor updates ---

  @doc """
  Runs a change to a user or board and tells its followers, if the change is
  one they can see.

  The test is the **rendered actor document**, not a list of fields: the change
  is published when `Person`/`Group` JSON before and after differ, and
  otherwise nothing is sent. That way a field added to `ActorRenderer`
  tomorrow federates without anybody remembering to add it here, and a change
  the document does not carry — a signature, a notification preference, a
  `dm_access` narrowing — sends nothing, which is right: an `Update` fans out
  to every follower's inbox.

  The publish commits with the change (`federate/2`, ADR 0034), so a restart
  cannot save a new display name and drop the activity announcing it.

  There is deliberately **no debouncing**. `/profile` saves each section
  separately, so editing four of them sends four `Update`s, and coalescing
  them would mean holding an activity in memory — the one thing ADR 0034 says
  publishing must not do. Profile edits are rare enough that the trade is
  wrong in the other direction. If an instance ever sees queue pressure from
  this, coalesce in the delivery queue where the jobs are durable, not here.
  """
  @spec update_actor(:user | :board, term(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def update_actor(actor_type, entity, change) when is_function(change, 0) do
    before = render_actor(actor_type, entity)

    federate(change, fn updated ->
      if render_actor(actor_type, updated) != before do
        Publisher.publish_actor_updated(actor_type, updated)
      end
    end)
  end

  defp render_actor(:user, user), do: user_actor(user)
  defp render_actor(:board, board), do: board_actor(board)

  # --- Durable publishing ---

  @doc """
  Makes a change and enqueues the federation it causes in one transaction.

  `change` returns `{:ok, result}` or `{:error, reason}`. On success, `publish`
  is called with the result inside the same transaction, so the delivery jobs
  it enqueues commit or roll back with the change. A restart can no longer fall
  between saving something and queueing its activities (Phase 2C, ADR 0034),
  and a publisher that raises rolls the change back instead of leaving it
  silently unfederated.

  Returns `{:ok, result}` or `{:error, reason}`, as `change` did.

  Every publisher and `Delivery` enqueue must run this way (or as a step of
  the change's own `Ecto.Multi`) — never inside `schedule_federation_task/1`.
  `test/baudrate/federation/durable_delivery_test.exs` enforces it.
  """
  @spec federate((-> {:ok, term()} | {:error, term()}), (term() -> term())) ::
          {:ok, term()} | {:error, term()}
  def federate(change, publish) when is_function(change, 0) and is_function(publish, 1) do
    Repo.transaction(fn ->
      case change.() do
        {:ok, result} ->
          publish.(result)
          result

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # --- Task Scheduling ---

  @doc """
  Runs best-effort background work: fetching remote images, warming the media
  cache, link previews.

  Never use it to publish an activity: a task still waiting when the node
  stops is lost. Publishing goes through `federate/2`.

  Controlled by `:federation_async`:

    * `true` (production) — starts the task under
      `Baudrate.Federation.TaskSupervisor`.
    * `false` (tests) — runs it synchronously, avoiding sandbox ownership
      errors.
    * `:discard` — drops it, as a restart would. The durability test uses this
      to prove nothing that must survive depends on a task.
  """
  def schedule_federation_task(fun) do
    case Application.get_env(:baudrate, :federation_async, true) do
      false ->
        fun.()
        :ok

      :discard ->
        :ok

      _ ->
        Task.Supervisor.start_child(Baudrate.Federation.TaskSupervisor, fun)
    end
  end
end
