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
    CRUD, likes, follows, blocks, and polls
  - **Collections** — paginated OrderedCollection endpoints for outbox,
    followers, following, boards index, article replies, and search
  - **User follows** — local users can follow remote actors via Follow/Undo(Follow)
    and local users via auto-accepted follows; both share the `user_follows` table
  - **Personal feed** — incoming Create activities from followed actors stored as
    `FeedItem` records; union query merges remote feed, local articles from
    followed users, and comment participation
  - **Public API** — AP endpoints double as public API; accepts `application/json`,
    CORS enabled on GET, `Vary: Accept` on content-negotiated endpoints

  Private boards are excluded from all federation endpoints — WebFinger,
  actor profiles, outbox, inbox, followers, and audience resolution all
  return 404 or skip private boards. Articles exclusively in private
  boards are also hidden from user outbox and article endpoints.

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
    * `Federation.ObjectBuilder` — JSON-LD article object serialization
    * `Federation.Collections` — outbox, followers/following, boards, search collections
    * `Federation.Follows` — inbound followers, user/board follows, local follows
    * `Federation.Feed` — feed items CRUD, feed item replies, likes, boosts
    * `Federation.InboxHandler` — inbound activity dispatch
    * `Federation.Publisher` — outbound activity building and delivery enqueuing
    * `Federation.Delivery` / `DeliveryWorker` — retry queue and HTTP delivery
    * `Federation.ActorResolver` — remote actor resolution and caching
    * `Federation.HTTPSignature` — HTTP Signature signing and verification
    * `Federation.KeyStore` / `KeyVault` — keypair management, encrypted storage
    * `Federation.Validator` — AP payload validation
    * `Federation.Visibility` — visibility derivation from to/cc addressing
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Content.Board

  alias Baudrate.Federation.{
    Announce,
    KeyStore,
    Publisher
  }

  alias Baudrate.Federation.{
    ActorRenderer,
    Collections,
    Discovery,
    Feed,
    Follows,
    ObjectBuilder
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
  """
  def actor_uri(:user, username), do: "#{base_url()}/ap/users/#{username}"
  def actor_uri(:board, slug), do: "#{base_url()}/ap/boards/#{slug}"
  def actor_uri(:site, _), do: "#{base_url()}/ap/site"
  def actor_uri(:article, slug), do: "#{base_url()}/ap/articles/#{slug}"

  # --- Discovery ---

  defdelegate webfinger(resource), to: Discovery
  defdelegate nodeinfo_links(), to: Discovery
  defdelegate nodeinfo(), to: Discovery
  defdelegate get_remote_actor(id), to: Discovery
  defdelegate lookup_remote_actor(query), to: Discovery
  defdelegate fetch_remote_object(url), to: Discovery
  defdelegate lookup_remote_object(url), to: Discovery

  # --- Actor Rendering ---

  defdelegate user_actor(user), to: ActorRenderer
  defdelegate board_actor(board), to: ActorRenderer
  defdelegate site_actor(), to: ActorRenderer
  defdelegate render_bio_html(bio), to: ActorRenderer

  # --- Article Object ---

  defdelegate article_object(article), to: ObjectBuilder

  # --- Collections ---

  defdelegate user_outbox(user, page_params \\ %{}), to: Collections
  defdelegate board_outbox(board, page_params \\ %{}), to: Collections
  defdelegate followers_collection(actor_uri, page_params \\ %{}), to: Collections
  defdelegate following_collection(actor_uri, page_params \\ %{}), to: Collections
  defdelegate boards_collection(), to: Collections
  defdelegate article_replies(article), to: Collections
  defdelegate search_collection(query, page_params), to: Collections

  # --- Inbound Followers ---

  defdelegate create_follower(actor_uri, remote_actor, activity_id), to: Follows
  defdelegate delete_follower(actor_uri, follower_uri), to: Follows
  defdelegate delete_followers_by_remote(remote_actor_ap_id), to: Follows
  defdelegate follower_exists?(actor_uri, follower_uri), to: Follows
  defdelegate list_followers(actor_uri), to: Follows
  defdelegate count_followers(actor_uri), to: Follows

  # --- User Follows (Outbound) ---

  defdelegate create_user_follow(user, remote_actor), to: Follows
  defdelegate accept_user_follow(follow_ap_id), to: Follows
  defdelegate reject_user_follow(follow_ap_id), to: Follows
  defdelegate delete_user_follow(user, remote_actor), to: Follows
  defdelegate get_user_follow(user_id, remote_actor_id), to: Follows
  defdelegate get_user_follow_with_actor(user_id, remote_actor_id), to: Follows
  defdelegate get_user_follow_by_ap_id(ap_id), to: Follows
  defdelegate user_follows?(user_id, remote_actor_id), to: Follows
  defdelegate user_follows_accepted?(user_id, remote_actor_id), to: Follows
  defdelegate list_user_follows(user_id, opts \\ []), to: Follows
  defdelegate count_user_follows(user_id), to: Follows

  # --- Board Follows ---

  defdelegate create_board_follow(board, remote_actor), to: Follows
  defdelegate accept_board_follow(follow_ap_id), to: Follows
  defdelegate reject_board_follow(follow_ap_id), to: Follows
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
  defdelegate create_local_follow(follower, followed), to: Follows
  defdelegate delete_local_follow(follower, followed), to: Follows
  defdelegate get_local_follow(follower_user_id, followed_user_id), to: Follows
  defdelegate batch_local_follow_states(follower_user_id, followed_user_ids), to: Follows
  defdelegate local_follows?(user_id, followed_user_id), to: Follows
  defdelegate local_followers_of_user(followed_user_id), to: Follows
  defdelegate migrate_user_follows(old_actor_id, new_actor_id), to: Follows

  # --- Feed Items ---

  defdelegate create_feed_item(attrs), to: Feed
  defdelegate list_feed_items(user, opts \\ []), to: Feed
  defdelegate get_feed_item_by_ap_id(ap_id), to: Feed
  defdelegate soft_delete_feed_item_by_ap_id(ap_id, remote_actor_id), to: Feed
  defdelegate cleanup_feed_items_for_actor(remote_actor_id), to: Feed
  defdelegate create_feed_item_reply(feed_item, user, body), to: Feed
  defdelegate list_feed_item_replies(feed_item_id), to: Feed
  defdelegate count_feed_item_replies(feed_item_ids), to: Feed
  defdelegate toggle_feed_item_like(user, feed_item_id), to: Feed
  defdelegate feed_item_likes_by_user(user_id, feed_item_ids), to: Feed
  defdelegate toggle_feed_item_boost(user, feed_item_id), to: Feed
  defdelegate feed_item_boosts_by_user(user_id, feed_item_ids), to: Feed

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

        Feed.cleanup_feed_items_for_actor(actor.id)

        :ok
    end
  end

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
    with {:ok, updated} <- do_rotate(actor_type, entity) do
      Publisher.publish_key_rotation(actor_type, updated)
      {:ok, updated}
    end
  end

  defp do_rotate(:user, user), do: KeyStore.rotate_user_keypair(user)
  defp do_rotate(:board, board), do: KeyStore.rotate_board_keypair(board)
  defp do_rotate(:site, _), do: KeyStore.rotate_site_keypair()

  # --- Task Scheduling ---

  @doc """
  Schedules a federation task for async delivery.

  In production, starts the task under `Baudrate.Federation.TaskSupervisor`.
  In test (when `federation_async: false`), runs synchronously to avoid
  sandbox ownership errors.
  """
  def schedule_federation_task(fun) do
    if Application.get_env(:baudrate, :federation_async, true) do
      Task.Supervisor.start_child(Baudrate.Federation.TaskSupervisor, fun)
    else
      fun.()
      :ok
    end
  end
end
