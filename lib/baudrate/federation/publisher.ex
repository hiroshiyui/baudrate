defmodule Baudrate.Federation.Publisher do
  @moduledoc """
  Builds ActivityStreams JSON for outgoing local activities and enqueues
  them for delivery to remote followers.

  Each `build_*` function returns a `{activity_map, actor_uri}` tuple.
  The `publish_*` convenience functions build the activity and call the
  appropriate `Delivery` function to fan out to follower inboxes:
  `enqueue_for_article/3` for article-scoped activities (Create, Update,
  Delete, Like) and `enqueue_for_followers/2` for actor-scoped activities
  (user Announce/Undo(Announce) boosts, where delivery targets the booster's
  followers rather than the article author's followers).

  All activities include both the ActivityStreams and W3ID Security
  vocabularies in `@context` for JSON-LD compatibility (`publicKey`
  resolution requires the security context).

  Outbound Note objects include `to`/`cc` addressing for Mastodon
  compatibility — Mastodon requires these fields to determine visibility.

  Direct message activities use restricted addressing (only the recipient
  in `to`, no `as:Public`, no followers collection) and are delivered to
  the recipient's personal inbox (not shared inbox) for privacy.
  """

  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.Delivery
  alias Baudrate.Federation.Context
  alias Baudrate.Federation.Mentions
  alias Baudrate.Federation.ObjectBuilder
  alias Baudrate.Federation.{TimelineItemBoost, TimelineItemLike}
  alias Baudrate.Repo

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  # --- Visibility-aware addressing ---

  # `Federation.Visibility` owns both directions of this mapping, so what we
  # write is what `from_addressing/1` reads back.
  defp visibility_addressing(visibility, followers_uri),
    do: Baudrate.Federation.Visibility.to_addressing(visibility, followers_uri)

  # Builds `{to, cc}` for article activities, merging board URIs and mentioned
  # actors into `cc`.
  #
  # This overwrites whatever `ObjectBuilder.article_object/1` put there, so the
  # two have to agree about mentions — they do, because both ask
  # `Mentions.known/1` behind the same gate.
  defp article_addressing(article, actor_uri) do
    {to, cc} = visibility_addressing(article.visibility, "#{actor_uri}/followers")

    # Only federated boards go in `cc`. A private board's actor URI carries its
    # slug, so listing it told every recipient that the board exists and what
    # it is called.
    board_uris =
      article.boards
      |> Enum.filter(&Board.federated?/1)
      |> Enum.map(&Federation.actor_uri(:board, &1.slug))

    {to, Enum.uniq(cc ++ board_uris ++ Mentions.uris(mentioned_in_article(article)))}
  end

  # A mention addresses; it never widens the audience (ADR 0051). An article
  # that may not leave names nobody.
  defp mentioned_in_article(article) do
    if Delivery.article_boards_federated?(article), do: Mentions.known(article.body), else: []
  end

  defp mentioned_in_comment(comment, article) do
    if Delivery.article_boards_federated?(article), do: Mentions.known(comment.body), else: []
  end

  # --- Activity Builders ---

  @doc """
  Builds a `Create(Article)` activity for a newly published article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_create_article(article) do
    article = Repo.preload(article, [:boards, :user])
    actor_uri = Federation.actor_uri(:user, article.user.username)
    object = Federation.article_object(article)
    {to, cc} = article_addressing(article, actor_uri)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#create-#{Ecto.UUID.generate()}",
      "type" => "Create",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => to,
      "cc" => cc,
      "object" => Map.merge(object, %{"to" => to, "cc" => cc})
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Delete` activity for a soft-deleted article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_delete_article(article) do
    article = Repo.preload(article, [:user])
    actor_uri = Federation.actor_uri(:user, article.user.username)
    article_uri = article.ap_id || Federation.actor_uri(:article, article.slug)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#delete-#{Ecto.UUID.generate()}",
      "type" => "Delete",
      "actor" => actor_uri,
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => %{
        "id" => article_uri,
        "type" => "Tombstone",
        "formerType" => "Article"
      }
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Announce` activity from a board actor wrapping an article URI.

  Returns `{activity_map, board_actor_uri}`.
  """
  def build_announce_article(article, board) do
    board_uri = Federation.actor_uri(:board, board.slug)
    article_uri = article.ap_id || Federation.actor_uri(:article, article.slug)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{board_uri}#announce-#{Ecto.UUID.generate()}",
      "type" => "Announce",
      "actor" => board_uri,
      "published" => DateTime.to_iso8601(article.inserted_at),
      "to" => [@as_public],
      "cc" => ["#{board_uri}/followers"],
      "object" => article_uri
    }

    {activity, board_uri}
  end

  @doc """
  Builds an `Update(Article)` activity for an edited article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_update_article(article) do
    article = Repo.preload(article, [:boards, :user])
    actor_uri = Federation.actor_uri(:user, article.user.username)
    object = Federation.article_object(article)
    {to, cc} = article_addressing(article, actor_uri)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#update-#{Ecto.UUID.generate()}",
      "type" => "Update",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(article.updated_at),
      "to" => to,
      "cc" => cc,
      "object" => Map.merge(object, %{"to" => to, "cc" => cc})
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Create(Note)` activity for a local comment.

  Returns `{activity_map, actor_uri}`.
  """
  def build_create_comment(comment, _article) do
    comment = Repo.preload(comment, :user)
    actor_uri = Federation.actor_uri(:user, comment.user.username)

    # `ObjectBuilder.comment_object/1` is the one definition of what a comment
    # looks like as ActivityPub — the same map `/ap/comments/:id` serves. This
    # used to build its own copy, and the copy is what made every addition
    # (mention tags, then content warnings) a thing to remember twice.
    # Addressing is the activity's to decide, so it is overwritten here, as
    # `build_create_article/1` does.
    object = ObjectBuilder.comment_object(comment)
    {to, cc} = {object["to"], object["cc"]}

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#create-#{Ecto.UUID.generate()}",
      "type" => "Create",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(comment.inserted_at),
      "to" => to,
      "cc" => cc,
      "object" => object
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Update(Note)` activity for an edited comment.

  Returns `{activity_map, actor_uri}`.

  The same shape as `build_update_article/1`, and the same object as
  `build_create_comment/2` — `ObjectBuilder.comment_object/1` is the one
  definition, and it now carries `"updated"`, which is what tells a receiver
  this is an edit rather than a repeat.

  **The activity names the comment's current `ap_id` and nothing else.**
  `build_delete_comment/2`'s sibling publisher sends a second copy under
  `legacy_ap_id` for comments minted before ADR 0050, and an `Update` must not
  do the same: a `Delete` of an object the receiver has never seen is a no-op,
  where an `Update` invites it to dereference the id — and a `#note-N`
  fragment resolves to the Person document, which is the precise failure 0050
  exists to end. The cost is accepted and recorded in ADR 0060: an edit to a
  pre-rewrite comment never reaches a peer that knows only the old URI.
  """
  def build_update_comment(comment, _article) do
    comment = Repo.preload(comment, :user)
    actor_uri = Federation.actor_uri(:user, comment.user.username)

    object = ObjectBuilder.comment_object(comment)
    {to, cc} = {object["to"], object["cc"]}

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#update-#{Ecto.UUID.generate()}",
      "type" => "Update",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(comment.updated_at),
      "to" => to,
      "cc" => cc,
      "object" => object
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Delete(Note)` activity for a soft-deleted comment.

  Returns `{activity_map, actor_uri}`.
  """
  def build_delete_comment(comment, _article) do
    comment = Repo.preload(comment, [:user])
    actor_uri = Federation.actor_uri(:user, comment.user.username)
    note_uri = comment_ap_id_or_derive(comment)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#delete-#{Ecto.UUID.generate()}",
      "type" => "Delete",
      "actor" => actor_uri,
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => %{
        "id" => note_uri,
        "type" => "Tombstone",
        "formerType" => "Note"
      }
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Flag` activity for reporting remote content to an instance admin.

  Returns `flag_map`.
  """
  def build_flag(remote_actor, content_ap_ids, reason) do
    site_uri = Federation.actor_uri(:site, nil)

    %{
      "@context" => Context.activity(),
      "id" => "#{site_uri}#flag-#{Ecto.UUID.generate()}",
      "type" => "Flag",
      "actor" => site_uri,
      "object" => [remote_actor.ap_id | content_ap_ids],
      "content" => reason
    }
  end

  @doc """
  Builds a `Reject(Follow)` activity that ends a remote actor's follow of a
  local user, from the stored `Follower` row. Used when the user blocks the
  actor; no `Block` activity is ever sent (P1-D1).

  Returns `{activity_map, actor_uri}`.
  """
  def build_reject_follow(user, %Baudrate.Federation.Follower{} = follower) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#reject-follow-#{Ecto.UUID.generate()}",
      "type" => "Reject",
      "actor" => actor_uri,
      "object" => %{
        "id" => follower.activity_id,
        "type" => "Follow",
        "actor" => follower.follower_uri,
        "object" => actor_uri
      }
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Follow` activity from a local user to a remote actor.

  Returns `{activity_map, actor_uri}`.
  """
  def build_follow(user, remote_actor, follow_ap_id) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => follow_ap_id,
      "type" => "Follow",
      "actor" => actor_uri,
      "object" => remote_actor.ap_id
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Follow)` activity for cancelling an outbound follow.

  Embeds the original Follow's AP ID as the inner object.
  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_follow(user, user_follow) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#undo-follow-#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "id" => user_follow.ap_id,
        "type" => "Follow",
        "actor" => actor_uri,
        "object" => user_follow.remote_actor.ap_id
      }
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Follow` activity from a board actor to a remote actor.

  Returns `{activity_map, board_actor_uri}`.
  """
  def build_board_follow(board, remote_actor, follow_ap_id) do
    board_uri = Federation.actor_uri(:board, board.slug)

    activity = %{
      "@context" => Context.activity(),
      "id" => follow_ap_id,
      "type" => "Follow",
      "actor" => board_uri,
      "object" => remote_actor.ap_id
    }

    {activity, board_uri}
  end

  @doc """
  Builds an `Undo(Follow)` activity from a board actor for cancelling an outbound follow.

  Embeds the original Follow's AP ID as the inner object.
  Returns `{activity_map, board_actor_uri}`.
  """
  def build_board_undo_follow(board, board_follow) do
    board_uri = Federation.actor_uri(:board, board.slug)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{board_uri}#undo-follow-#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => board_uri,
      "object" => %{
        "id" => board_follow.ap_id,
        "type" => "Follow",
        "actor" => board_uri,
        "object" => board_follow.remote_actor.ap_id
      }
    }

    {activity, board_uri}
  end

  @doc """
  Builds an `Update` activity for an actor (used for key rotation distribution).

  Returns `{activity_map, actor_uri}`.
  """
  def build_update_actor(actor_type, entity) do
    {actor_uri, actor_json} =
      case actor_type do
        :user ->
          uri = Federation.actor_uri(:user, entity.username)
          {uri, Federation.user_actor(entity)}

        :board ->
          uri = Federation.actor_uri(:board, entity.slug)
          {uri, Federation.board_actor(entity)}

        :site ->
          uri = Federation.actor_uri(:site, nil)
          {uri, Federation.site_actor()}
      end

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#update-actor-#{Ecto.UUID.generate()}",
      "type" => "Update",
      "actor" => actor_uri,
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => actor_json
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Move` activity announcing that `user` moved to `target_ap_id`
  (ADR 0025).

  `object` is the moving account itself, as Mastodon and other servers expect.
  Receivers verify that the target lists the account in `alsoKnownAs`, then
  move their follows. Returns `{activity_map, actor_uri}`.
  """
  def build_move(user, target_ap_id) when is_binary(target_ap_id) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#move-#{Ecto.UUID.generate()}",
      "type" => "Move",
      "actor" => actor_uri,
      "object" => actor_uri,
      "target" => target_ap_id,
      "to" => ["#{actor_uri}/followers"]
    }

    {activity, actor_uri}
  end

  @doc """
  Builds the `Delete` of a local account that deleted itself (ADR 0072):
  `object` is the actor URI, the shape Mastodon and others treat as "this
  account is gone" — most of them then remove everything it posted.

  Returns `{activity_map, actor_uri}`.
  """
  def build_delete_actor(user) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#delete-#{Ecto.UUID.generate()}",
      "type" => "Delete",
      "actor" => actor_uri,
      "object" => actor_uri,
      "to" => [@as_public]
    }

    {activity, actor_uri}
  end

  @doc """
  Queues the account's `Delete(Person)` for its followers and for
  `extra_inboxes` — everyone else elsewhere that has the account on record
  (`Baudrate.AccountDeletion` collects them). Shared inboxes are
  deduplicated. A withdrawal, so no board gate applies (ADR 0043).
  """
  def publish_actor_deleted(user, extra_inboxes \\ []) do
    {activity, actor_uri} = build_delete_actor(user)
    inboxes = Enum.uniq(Delivery.resolve_follower_inboxes(actor_uri) ++ extra_inboxes)

    if inboxes == [], do: {:ok, 0}, else: Delivery.enqueue(activity, actor_uri, inboxes)
  end

  @doc """
  Publishes an `Update` activity for an actor to all its followers.

  One activity for every reason an actor document changes: a new public key
  after rotation, a new display name, bio, avatar or profile field, a board's
  new name or description. There is nothing to distinguish — the `Update`
  carries the whole document either way, and a second function would be a
  second thing to remember when a field is added.
  """
  def publish_actor_updated(actor_type, entity) do
    {activity, actor_uri} = build_update_actor(actor_type, entity)
    Delivery.enqueue_for_followers(activity, actor_uri)
  end

  # --- Publish Convenience Functions ---

  @doc """
  Publishes a `Create(Article)` activity to all relevant followers.

  Enqueues delivery to followers of the article's author and to
  followers of all public boards the article is posted to. Also
  enqueues `Announce` activities from each board actor to the board's
  followers.
  """
  def publish_article_created(article) do
    article = Repo.preload(article, [:boards, :user])

    # Create(Article) from user → user's followers + board followers, plus
    # anyone the body mentions (ADR 0051).
    {activity, actor_uri} = build_create_article(article)

    Delivery.enqueue_for_article(activity, actor_uri, article,
      mentioned: mentioned_in_article(article)
    )

    # Announce from each federated board → board's followers.
    # `federated?/1`, not `public?/1`: turning `ap_enabled` off does not
    # remove the followers a board already has, so a guest-viewable board
    # with federation switched off went on announcing to them.
    for board <- article.boards, Board.federated?(board) do
      {announce, board_uri} = build_announce_article(article, board)
      Delivery.enqueue_for_followers(announce, board_uri)
    end

    :ok
  end

  @doc """
  Publishes federation activities when a board-less article is forwarded to a board.

  Sends `Create(Article)` from user to board followers, and `Announce` from board actor.
  Only delivers if the board is public (`min_role_to_view == "guest"`) and AP-enabled.
  """
  def publish_article_forwarded(article, board) do
    article = Repo.preload(article, [:boards, :user])

    if Board.federated?(board) do
      # For local articles, send Create(Article) from user → board followers
      # For remote articles, skip Create — the original already exists on the origin server
      if article.user_id do
        {activity, actor_uri} = build_create_article(article)
        board_uri = Federation.actor_uri(:board, board.slug)
        board_inboxes = Delivery.resolve_follower_inboxes(board_uri)
        if board_inboxes != [], do: Delivery.enqueue(activity, actor_uri, board_inboxes)
      end

      # Announce from board → board's followers
      {announce, board_actor_uri} = build_announce_article(article, board)
      Delivery.enqueue_for_followers(announce, board_actor_uri)
    end

    :ok
  end

  @doc """
  Publishes a `Delete` activity to all relevant followers.
  """
  def publish_article_deleted(article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_delete_article(article)
    Delivery.enqueue_for_article(activity, actor_uri, article, intent: :withdraw)
  end

  @doc """
  Publishes a `Create(Note)` activity for a local comment to all relevant followers.
  """
  def publish_comment_created(comment, article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_create_comment(comment, article)

    Delivery.enqueue_for_article(activity, actor_uri, article,
      remote_authors: reply_authors(comment, article),
      mentioned: mentioned_in_comment(comment, article)
    )
  end

  @doc """
  Publishes an `Update(Note)` activity for an edited comment (ADR 0060).

  Gated like the `Create` it corrects: no `intent:` is passed, so it defaults
  to `:publish` and the board federation gate applies (ADR 0043). An edit is a
  publication, not a withdrawal — a comment in a board that does not federate
  must not start federating because its author fixed a typo.

  Addressed like the `Create` too, through `reply_authors/2` and
  `mentioned_in_comment/2`: an edit can add a mention, and that actor has not
  seen the comment at all, which is the same reason `publish_article_updated/1`
  carries `mentioned:`.
  """
  def publish_comment_updated(comment, article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_update_comment(comment, article)

    Delivery.enqueue_for_article(activity, actor_uri, article,
      remote_authors: reply_authors(comment, article),
      mentioned: mentioned_in_comment(comment, article)
    )
  end

  @doc """
  Publishes a `Delete(Note)` activity for a soft-deleted comment to all relevant
  followers.

  A comment that carries a `legacy_ap_id` is withdrawn **twice**: once under its
  current URI and once under the `<actor>#note-N` one it had before ADR 0050
  rewrote it. Instances that received the comment before the rewrite know it
  only by the old id, and ActivityPub has no way to tell them the id changed —
  a `Move` is for actors. Without the second activity, deleting a pre-backfill
  comment would leave it standing on every instance that had it. A `Delete`
  naming an object the receiver has never seen is a no-op, so the duplicate
  costs one delivery job and risks nothing.
  """
  def publish_comment_deleted(comment, article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_delete_comment(comment, article)
    authors = reply_authors(comment, article)

    for activity <- [activity | legacy_withdrawals(activity, comment)] do
      Delivery.enqueue_for_article(activity, actor_uri, article,
        remote_authors: authors,
        intent: :withdraw
      )
    end

    :ok
  end

  # The same withdrawal, re-addressed to the object id peers knew before the
  # ADR 0050 rewrite. Empty for every row created since, which is all of them
  # after `legacy_ap_id` stops being filled.
  defp legacy_withdrawals(_activity, %{legacy_ap_id: nil}), do: []

  defp legacy_withdrawals(activity, %{legacy_ap_id: legacy}) when is_binary(legacy) do
    [
      activity
      |> Map.put("id", "#{activity["actor"]}#delete-#{Ecto.UUID.generate()}")
      |> Map.update!("object", &Map.put(&1, "id", legacy))
    ]
  end

  defp legacy_withdrawals(_activity, _comment), do: []

  # Remote actors who should hear about a comment: the remote author of the
  # article and of the comment it replies to.
  defp reply_authors(comment, article) do
    article = Repo.preload(article, :remote_actor)

    parent_author =
      case comment.parent_id do
        nil ->
          nil

        parent_id ->
          case Repo.get(Baudrate.Content.Comment, parent_id) do
            %{remote_actor_id: id} when not is_nil(id) ->
              Repo.get(Baudrate.Federation.RemoteActor, id)

            _ ->
              nil
          end
      end

    Enum.uniq([article.remote_actor, parent_author])
  end

  defp remote_author(%{remote_actor_id: nil}), do: []

  defp remote_author(record) do
    [Repo.preload(record, :remote_actor).remote_actor]
  end

  @doc """
  Publishes an `Update(Article)` activity to all relevant followers.
  """
  def publish_article_updated(article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_update_article(article)

    # An edit can add a mention, and the mentioned actor has not seen the
    # article at all — so an `Update` is delivered to them as well.
    Delivery.enqueue_for_article(activity, actor_uri, article,
      mentioned: mentioned_in_article(article)
    )
  end

  # --- Article Like ---

  @doc """
  Builds a `Like` activity for a local user liking an article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_like_article(user, article, like_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)
    article_uri = article.ap_id || Federation.actor_uri(:article, article.slug)
    like_id = like_ap_id || "#{actor_uri}#like-#{Ecto.UUID.generate()}"

    activity = %{
      "@context" => Context.activity(),
      "id" => like_id,
      "type" => "Like",
      "actor" => actor_uri,
      "object" => article_uri,
      "to" => [@as_public]
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Like)` activity for a local user unliking an article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_like_article(user, article, like_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)
    article_uri = article.ap_id || Federation.actor_uri(:article, article.slug)
    like_id = like_ap_id || "#{actor_uri}#like-#{Ecto.UUID.generate()}"

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#undo-like-#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "id" => like_id,
        "type" => "Like",
        "actor" => actor_uri,
        "object" => article_uri
      },
      "to" => [@as_public]
    }

    {activity, actor_uri}
  end

  @doc """
  Publishes a `Like` activity for a local user liking an article.
  """
  def publish_article_liked(user_id, article) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    article = Repo.preload(article, [:boards, :user])

    like = Repo.get_by(Baudrate.Content.ArticleLike, user_id: user_id, article_id: article.id)
    like_ap_id = like && like.ap_id

    {activity, actor_uri} = build_like_article(user, article, like_ap_id)

    Delivery.enqueue_for_article(activity, actor_uri, article,
      remote_authors: remote_author(article)
    )
  end

  @doc """
  Publishes an `Undo(Like)` activity for a local user unliking an article.
  """
  def publish_article_unliked(user_id, article, like_ap_id \\ nil) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_undo_like_article(user, article, like_ap_id)

    Delivery.enqueue_for_article(activity, actor_uri, article,
      remote_authors: remote_author(article),
      intent: :withdraw
    )
  end

  # --- Comment Like ---

  @doc """
  Builds a `Like` activity for a local user liking a comment.

  Returns `{activity_map, actor_uri}`.
  """
  def build_like_comment(user, comment, like_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)
    comment_uri = comment_ap_id_or_derive(comment)
    like_id = like_ap_id || "#{actor_uri}#comment-like-#{Ecto.UUID.generate()}"

    activity = %{
      "@context" => Context.activity(),
      "id" => like_id,
      "type" => "Like",
      "actor" => actor_uri,
      "object" => comment_uri,
      "to" => [@as_public]
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Like)` activity for a local user unliking a comment.

  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_like_comment(user, comment, like_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)
    comment_uri = comment_ap_id_or_derive(comment)
    like_id = like_ap_id || "#{actor_uri}#comment-like-#{Ecto.UUID.generate()}"

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#undo-comment-like-#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "id" => like_id,
        "type" => "Like",
        "actor" => actor_uri,
        "object" => comment_uri
      },
      "to" => [@as_public]
    }

    {activity, actor_uri}
  end

  @doc """
  Publishes a `Like` activity for a local user liking a comment.
  """
  def publish_comment_liked(user_id, comment) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    comment = Repo.preload(comment, article: [:boards, :user])

    like =
      Repo.get_by(Baudrate.Content.CommentLike, user_id: user_id, comment_id: comment.id)

    like_ap_id = like && like.ap_id

    {activity, actor_uri} = build_like_comment(user, comment, like_ap_id)

    Delivery.enqueue_for_article(activity, actor_uri, comment.article,
      remote_authors: remote_author(comment)
    )
  end

  @doc """
  Publishes an `Undo(Like)` activity for a local user unliking a comment.
  """
  def publish_comment_unliked(user_id, comment, like_ap_id \\ nil) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    comment = Repo.preload(comment, article: [:boards, :user])
    {activity, actor_uri} = build_undo_like_comment(user, comment, like_ap_id)

    Delivery.enqueue_for_article(activity, actor_uri, comment.article,
      remote_authors: remote_author(comment),
      intent: :withdraw
    )
  end

  # --- Article Boost (User Announce) ---

  @doc """
  Builds an `Announce` activity from a local user boosting an article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_user_announce_article(user, article, boost_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)
    article_uri = article.ap_id || Federation.actor_uri(:article, article.slug)
    announce_id = boost_ap_id || "#{actor_uri}#announce-#{Ecto.UUID.generate()}"

    activity = %{
      "@context" => Context.activity(),
      "id" => announce_id,
      "type" => "Announce",
      "actor" => actor_uri,
      "object" => article_uri,
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"]
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Announce)` activity for a local user unboosting an article.

  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_user_announce_article(user, article, boost_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)
    article_uri = article.ap_id || Federation.actor_uri(:article, article.slug)
    announce_id = boost_ap_id || "#{actor_uri}#announce-#{Ecto.UUID.generate()}"

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#undo-announce-#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "id" => announce_id,
        "type" => "Announce",
        "actor" => actor_uri,
        "object" => article_uri
      },
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"]
    }

    {activity, actor_uri}
  end

  @doc """
  Publishes an `Announce` activity for a local user boosting an article.

  Delivers to the booster's followers (not the article author's followers),
  since the Announce originates from the booster's actor.
  """
  def publish_article_boosted(user_id, article) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    article = Repo.preload(article, [:boards, :user])

    boost =
      Repo.get_by(Baudrate.Content.ArticleBoost, user_id: user_id, article_id: article.id)

    boost_ap_id = boost && boost.ap_id

    {activity, actor_uri} = build_user_announce_article(user, article, boost_ap_id)

    enqueue_for_followers_and_authors(activity, actor_uri, remote_author(article),
      article: article
    )
  end

  @doc """
  Publishes an `Undo(Announce)` activity for a local user unboosting an article.

  Delivers to the booster's followers.
  """
  def publish_article_unboosted(user_id, article, boost_ap_id \\ nil) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_undo_user_announce_article(user, article, boost_ap_id)

    enqueue_for_followers_and_authors(activity, actor_uri, remote_author(article),
      article: article,
      intent: :withdraw
    )
  end

  # --- Comment Boost (User Announce) ---

  @doc """
  Builds an `Announce` activity from a local user boosting a comment.

  Returns `{activity_map, actor_uri}`.
  """
  def build_user_announce_comment(user, comment, boost_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)
    comment_uri = comment_ap_id_or_derive(comment)

    announce_id =
      boost_ap_id || "#{actor_uri}#comment-announce-#{Ecto.UUID.generate()}"

    activity = %{
      "@context" => Context.activity(),
      "id" => announce_id,
      "type" => "Announce",
      "actor" => actor_uri,
      "object" => comment_uri,
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"]
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Announce)` activity for a local user unboosting a comment.

  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_user_announce_comment(user, comment, boost_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)
    comment_uri = comment_ap_id_or_derive(comment)

    announce_id =
      boost_ap_id || "#{actor_uri}#comment-announce-#{Ecto.UUID.generate()}"

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#undo-comment-announce-#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "id" => announce_id,
        "type" => "Announce",
        "actor" => actor_uri,
        "object" => comment_uri
      },
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"]
    }

    {activity, actor_uri}
  end

  @doc """
  Publishes an `Announce` activity for a local user boosting a comment.

  Delivers to the booster's followers.
  """
  def publish_comment_boosted(user_id, comment) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    comment = Repo.preload(comment, article: [:boards, :user])

    boost =
      Repo.get_by(Baudrate.Content.CommentBoost, user_id: user_id, comment_id: comment.id)

    boost_ap_id = boost && boost.ap_id

    {activity, actor_uri} = build_user_announce_comment(user, comment, boost_ap_id)

    enqueue_for_followers_and_authors(activity, actor_uri, remote_author(comment),
      article: comment.article
    )
  end

  @doc """
  Publishes an `Undo(Announce)` activity for a local user unboosting a comment.

  Delivers to the booster's followers.
  """
  def publish_comment_unboosted(user_id, comment, boost_ap_id \\ nil) do
    user = Repo.get!(Baudrate.Setup.User, user_id)
    comment = Repo.preload(comment, article: [:boards, :user])
    {activity, actor_uri} = build_undo_user_announce_comment(user, comment, boost_ap_id)

    enqueue_for_followers_and_authors(activity, actor_uri, remote_author(comment),
      article: comment.article,
      intent: :withdraw
    )
  end

  # A boost goes to the booster's followers, and also to the boosted post's
  # remote author so their instance counts it.
  #
  # `:article` and `:intent` carry the same board gate `enqueue_for_article/4`
  # applies, because this path does not go through it: an `Announce` names
  # `<base>/ap/articles/<slug>`, and the slug is derived from the title, so a
  # member who can read a private board and boosts a post there was telling
  # their remote followers that the post exists and approximately what it is
  # called. The remote author is never gated, and an `Undo` never is either —
  # withdrawing a boost that did go out must always be possible.
  defp enqueue_for_followers_and_authors(activity, actor_uri, authors, opts) do
    article = Keyword.get(opts, :article)
    gated? = Keyword.get(opts, :intent, :publish) == :publish

    follower_inboxes =
      if gated? and not Delivery.article_boards_federated?(article) do
        []
      else
        Delivery.resolve_follower_inboxes(actor_uri)
      end

    author_inboxes =
      for %{shared_inbox: shared, inbox: inbox} <- authors,
          target = if(is_binary(shared) and shared != "", do: shared, else: inbox),
          is_binary(target) and target != "",
          do: target

    case Enum.uniq(follower_inboxes ++ author_inboxes) do
      [] -> {:ok, 0}
      inboxes -> Delivery.enqueue(activity, actor_uri, inboxes)
    end
  end

  # --- Timeline Item Like/Boost ---

  @doc """
  Builds a `Like` activity for a local user liking a remote timeline item.

  Returns `{activity_map, actor_uri}`.
  """
  def build_like_timeline_item(user, timeline_item, like_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => like_ap_id || "#{actor_uri}#timeline-like-#{Ecto.UUID.generate()}",
      "type" => "Like",
      "actor" => actor_uri,
      "object" => timeline_item.ap_id,
      "to" => [@as_public]
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Like)` activity for unliking a remote timeline item.

  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_like_timeline_item(user, timeline_item, like_ap_id) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#undo-timeline-like-#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "id" => like_ap_id,
        "type" => "Like",
        "actor" => actor_uri,
        "object" => timeline_item.ap_id
      },
      "to" => [@as_public]
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Announce` activity for a local user boosting a remote timeline item.

  Returns `{activity_map, actor_uri}`.
  """
  def build_announce_timeline_item(user, timeline_item, boost_ap_id \\ nil) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => boost_ap_id || "#{actor_uri}#timeline-announce-#{Ecto.UUID.generate()}",
      "type" => "Announce",
      "actor" => actor_uri,
      "object" => timeline_item.ap_id,
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"]
    }

    {activity, actor_uri}
  end

  @doc """
  Builds an `Undo(Announce)` activity for unboosting a remote timeline item.

  Returns `{activity_map, actor_uri}`.
  """
  def build_undo_announce_timeline_item(user, timeline_item, boost_ap_id) do
    actor_uri = Federation.actor_uri(:user, user.username)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#undo-timeline-announce-#{Ecto.UUID.generate()}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => %{
        "id" => boost_ap_id,
        "type" => "Announce",
        "actor" => actor_uri,
        "object" => timeline_item.ap_id
      },
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"]
    }

    {activity, actor_uri}
  end

  @doc """
  Publishes a `Like` activity for a local user liking a remote timeline item.
  Delivers to the remote actor's inbox.
  """
  def publish_timeline_item_liked(user, timeline_item) do
    timeline_item = Repo.preload(timeline_item, [:remote_actor])

    # The stored row's `ap_id`, not a fresh UUID. The `Undo` sends the stored
    # value, so minting a different id here published a `Like` the remote
    # server knew by one id and then withdrew by another — Mastodon matches an
    # `Undo(Like)` on actor + object and so tolerated it, but a peer that
    # matches on the Like's own `id` would keep the like forever. The article
    # path (`build_like_article/3`) already threads the stored id through;
    # this is the same shape.
    {activity, actor_uri} =
      build_like_timeline_item(
        user,
        timeline_item,
        stored_interaction_ap_id(TimelineItemLike, user, timeline_item)
      )

    inbox = timeline_item.remote_actor.shared_inbox || timeline_item.remote_actor.inbox

    if inbox do
      Delivery.enqueue(activity, actor_uri, [inbox])
    else
      {:ok, 0}
    end
  end

  @doc """
  Publishes an `Undo(Like)` activity for unliking a remote timeline item.
  """
  def publish_timeline_item_unliked(user, timeline_item, like_ap_id) do
    timeline_item = Repo.preload(timeline_item, [:remote_actor])
    {activity, actor_uri} = build_undo_like_timeline_item(user, timeline_item, like_ap_id)
    inbox = timeline_item.remote_actor.shared_inbox || timeline_item.remote_actor.inbox

    if inbox do
      Delivery.enqueue(activity, actor_uri, [inbox])
    else
      {:ok, 0}
    end
  end

  @doc """
  Publishes an `Announce` activity for a local user boosting a remote timeline item.
  Delivers to the remote actor's inbox.
  """
  def publish_timeline_item_boosted(user, timeline_item) do
    timeline_item = Repo.preload(timeline_item, [:remote_actor])

    # As for the like above: the id the `Undo` will name.
    {activity, actor_uri} =
      build_announce_timeline_item(
        user,
        timeline_item,
        stored_interaction_ap_id(TimelineItemBoost, user, timeline_item)
      )

    inbox = timeline_item.remote_actor.shared_inbox || timeline_item.remote_actor.inbox

    if inbox do
      Delivery.enqueue(activity, actor_uri, [inbox])
    else
      {:ok, 0}
    end
  end

  @doc """
  Publishes an `Undo(Announce)` activity for unboosting a remote timeline item.
  """
  def publish_timeline_item_unboosted(user, timeline_item, boost_ap_id) do
    timeline_item = Repo.preload(timeline_item, [:remote_actor])
    {activity, actor_uri} = build_undo_announce_timeline_item(user, timeline_item, boost_ap_id)
    inbox = timeline_item.remote_actor.shared_inbox || timeline_item.remote_actor.inbox

    if inbox do
      Delivery.enqueue(activity, actor_uri, [inbox])
    else
      {:ok, 0}
    end
  end

  # The `ap_id` stamped on the like/boost row that was just inserted. Both
  # publishers run inside the transaction that created and stamped it
  # (ADR 0034), so it is there to be read.
  defp stored_interaction_ap_id(schema, user, timeline_item) do
    case Repo.get_by(schema, user_id: user.id, timeline_item_id: timeline_item.id) do
      %{ap_id: ap_id} when is_binary(ap_id) -> ap_id
      _ -> nil
    end
  end

  # --- Poll Vote Builders ---

  @doc """
  Builds `Create(Note)` activities for poll votes.

  Following the Mastodon vote protocol, each selected option produces a
  separate Note with `name` matching the option text and `inReplyTo`
  pointing to the article AP URI.

  Returns a list of `{activity_map, actor_uri}` tuples (one per option).
  """
  def build_create_vote(user, article, voted_options) do
    article = Repo.preload(article, [:user])
    actor_uri = Federation.actor_uri(:user, user.username)
    article_uri = article.ap_id || Federation.actor_uri(:article, article.slug)

    Enum.map(voted_options, fn option ->
      activity = %{
        "@context" => Context.activity(),
        "id" => "#{actor_uri}#vote-#{Ecto.UUID.generate()}",
        "type" => "Create",
        "actor" => actor_uri,
        "to" => [Federation.actor_uri(:user, article.user.username)],
        "object" => %{
          "id" => "#{actor_uri}#vote-note-#{Ecto.UUID.generate()}",
          "type" => "Note",
          "name" => option.text,
          "inReplyTo" => article_uri,
          "attributedTo" => actor_uri,
          "to" => [Federation.actor_uri(:user, article.user.username)]
        }
      }

      {activity, actor_uri}
    end)
  end

  @doc """
  Builds an `Update(Question)` carrying a closed poll's final counts.

  Returns `{activity_map, actor_uri}`.
  """
  def build_update_poll(poll, article) do
    actor_uri = Federation.actor_uri(:user, article.user.username)
    {to, cc} = article_addressing(article, actor_uri)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#update-poll-#{Ecto.UUID.generate()}",
      "type" => "Update",
      "actor" => actor_uri,
      "to" => to,
      "cc" => cc,
      "object" => Map.merge(Federation.poll_object(poll), %{"to" => to, "cc" => cc})
    }

    {activity, actor_uri}
  end

  @doc """
  Publishes a closed poll's final counts to everyone the article reached.

  Gated like any other publication: `enqueue_for_article/4` refuses an article
  whose boards do not federate, so a poll in a private board announces
  nothing. Mastodon shows a poll's results once it has closed, and refetches
  the object to get them — this is what makes the numbers right for an
  instance that does not.
  """
  def publish_poll_closed(poll, article) do
    article = Repo.preload(article, [:boards, :user])
    {activity, actor_uri} = build_update_poll(poll, article)
    Delivery.enqueue_for_article(activity, actor_uri, article)
  end

  @doc """
  Publishes vote activities for a local user's poll vote.

  Delivers to the article author's inbox. For remote articles, delivers
  to the remote author's inbox. For local articles, delivers to followers.
  """
  def publish_vote(user, article, voted_options) do
    article = Repo.preload(article, [:user])
    vote_activities = build_create_vote(user, article, voted_options)

    for {activity, actor_uri} <- vote_activities do
      if article.remote_actor_id do
        remote_actor = Repo.get!(Baudrate.Federation.RemoteActor, article.remote_actor_id)
        inbox = remote_actor.shared_inbox || remote_actor.inbox

        if inbox do
          Delivery.enqueue(activity, actor_uri, [inbox])
        end
      else
        Delivery.enqueue_for_article(activity, actor_uri, article)
      end
    end

    :ok
  end

  # --- Timeline Item Reply Builders ---

  @doc """
  Builds a `Create(Note)` activity for a local user's reply to a remote timeline item.

  The Note's `inReplyTo` points to the timeline item's AP ID so that the remote
  instance threads the reply correctly.

  Returns `{activity_map, actor_uri}`.
  """
  def build_create_timeline_item_reply(reply, timeline_item, user) do
    reply = Repo.preload(reply, :images)
    actor_uri = Federation.actor_uri(:user, user.username)

    note_object =
      %{
        "id" => reply.ap_id,
        "type" => "Note",
        "content" => reply.body_html || reply.body,
        "attributedTo" => actor_uri,
        "inReplyTo" => timeline_item.ap_id,
        "published" => DateTime.to_iso8601(reply.inserted_at),
        "to" => [@as_public],
        "cc" => ["#{actor_uri}/followers"]
      }
      |> maybe_put_content_warning(reply)
      |> maybe_put_reply_attachments(reply)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#create-#{Ecto.UUID.generate()}",
      "type" => "Create",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(reply.inserted_at),
      "to" => [@as_public],
      "cc" => ["#{actor_uri}/followers"],
      "object" => note_object
    }

    {activity, actor_uri}
  end

  @doc """
  Publishes a `Create(Note)` reply to a remote timeline item.

  Ensures the replying user has an RSA keypair, builds the activity,
  resolves the remote actor's inbox plus the user's AP follower inboxes,
  deduplicates, and enqueues for delivery.
  """
  def publish_timeline_item_reply(reply, timeline_item) do
    reply = Repo.preload(reply, user: :role)
    timeline_item = Repo.preload(timeline_item, [:remote_actor])
    user = reply.user

    {:ok, user} = Baudrate.Federation.KeyStore.ensure_user_keypair(user)

    {activity, actor_uri} = build_create_timeline_item_reply(reply, timeline_item, user)

    # Remote actor inbox
    remote_inbox = timeline_item.remote_actor.shared_inbox || timeline_item.remote_actor.inbox

    # User's AP follower inboxes
    follower_inboxes = Delivery.resolve_follower_inboxes(actor_uri)

    inboxes =
      [remote_inbox | follower_inboxes]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if inboxes != [] do
      Delivery.enqueue(activity, actor_uri, inboxes)
    else
      {:ok, 0}
    end
  end

  # --- Direct Message Builders ---

  @doc """
  Builds a `Create(Note)` activity for a direct message.

  Addresses only the recipient in `to` (no public, no followers collection).
  Includes `Mention` tag and `context`/`conversation` fields for Mastodon compat.

  Returns `{activity_map, actor_uri}`.
  """
  def build_create_dm(message, conversation, sender_user) do
    actor_uri = Federation.actor_uri(:user, sender_user.username)
    conversation = Repo.preload(conversation, [:remote_actor_b, :user_b])

    recipient_uri = resolve_dm_recipient_uri(conversation, sender_user.id)
    recipient_acct = resolve_dm_recipient_acct(conversation, sender_user.id)

    message_uri = message.ap_id || "#{actor_uri}#dm-#{message.id}"

    object =
      %{
        "id" => message_uri,
        "type" => "Note",
        "content" => message.body_html || message.body,
        "attributedTo" => actor_uri,
        "published" => DateTime.to_iso8601(message.inserted_at),
        "to" => [recipient_uri],
        "tag" => [
          %{
            "type" => "Mention",
            "href" => recipient_uri,
            "name" => recipient_acct
          }
        ],
        "context" => conversation.ap_context,
        "conversation" => conversation.ap_context
      }
      |> maybe_add_in_reply_to(message)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#create-dm-#{Ecto.UUID.generate()}",
      "type" => "Create",
      "actor" => actor_uri,
      "published" => DateTime.to_iso8601(message.inserted_at),
      "to" => [recipient_uri],
      "object" => object
    }

    {activity, actor_uri}
  end

  @doc """
  Builds a `Delete` activity with `Tombstone` for a deleted DM.

  Returns `{activity_map, actor_uri}`.
  """
  def build_delete_dm(message, sender_user, conversation) do
    actor_uri = Federation.actor_uri(:user, sender_user.username)
    message_uri = message.ap_id || "#{actor_uri}#dm-#{message.id}"
    recipient_uri = resolve_dm_recipient_uri(conversation, sender_user.id)

    activity = %{
      "@context" => Context.activity(),
      "id" => "#{actor_uri}#delete-dm-#{Ecto.UUID.generate()}",
      "type" => "Delete",
      "actor" => actor_uri,
      "to" => [recipient_uri],
      "object" => %{
        "id" => message_uri,
        "type" => "Tombstone",
        "formerType" => "Note"
      }
    }

    {activity, actor_uri}
  end

  # --- Direct Message Publish Convenience Functions ---

  @doc """
  Publishes a `Create(Note)` DM activity to the remote recipient's personal inbox.

  Only delivers if the other participant is a `%RemoteActor{}`.
  Uses the personal inbox (NOT shared inbox) for DM privacy.
  """
  def publish_dm_created(message, conversation, sender_user) do
    conversation = Repo.preload(conversation, [:remote_actor_b])

    if conversation.remote_actor_b do
      {activity, actor_uri} = build_create_dm(message, conversation, sender_user)
      # Use personal inbox for DM privacy, not shared inbox
      Delivery.enqueue(activity, actor_uri, [conversation.remote_actor_b.inbox])
    else
      {:ok, 0}
    end
  end

  @doc """
  Publishes a `Delete` DM activity to the remote recipient's personal inbox.
  """
  def publish_dm_deleted(message, sender_user, conversation) do
    conversation = Repo.preload(conversation, [:remote_actor_b])

    if conversation.remote_actor_b do
      {activity, actor_uri} = build_delete_dm(message, sender_user, conversation)
      Delivery.enqueue(activity, actor_uri, [conversation.remote_actor_b.inbox])
    else
      {:ok, 0}
    end
  end

  # --- DM Helpers ---

  defp resolve_dm_recipient_uri(conversation, sender_user_id) do
    conversation = Repo.preload(conversation, [:user_a, :user_b, :remote_actor_b])

    cond do
      conversation.remote_actor_b && conversation.user_a_id == sender_user_id ->
        conversation.remote_actor_b.ap_id

      conversation.user_b && conversation.user_b_id != sender_user_id ->
        Federation.actor_uri(:user, conversation.user_b.username)

      conversation.user_a && conversation.user_a_id != sender_user_id ->
        Federation.actor_uri(:user, conversation.user_a.username)

      true ->
        nil
    end
  end

  defp resolve_dm_recipient_acct(conversation, sender_user_id) do
    conversation = Repo.preload(conversation, [:user_a, :user_b, :remote_actor_b])

    cond do
      conversation.remote_actor_b && conversation.user_a_id == sender_user_id ->
        "@#{conversation.remote_actor_b.username}@#{conversation.remote_actor_b.domain}"

      conversation.user_b && conversation.user_b_id != sender_user_id ->
        "@#{conversation.user_b.username}"

      conversation.user_a && conversation.user_a_id != sender_user_id ->
        "@#{conversation.user_a.username}"

      true ->
        ""
    end
  end

  defp maybe_add_in_reply_to(object, %{ap_in_reply_to: in_reply_to})
       when is_binary(in_reply_to) and in_reply_to != "" do
    Map.put(object, "inReplyTo", in_reply_to)
  end

  defp maybe_add_in_reply_to(object, _message), do: object

  defp maybe_put_reply_attachments(note_object, %{images: images})
       when is_list(images) and images != [] do
    Map.put(note_object, "attachment", build_image_attachments(images))
  end

  defp maybe_put_reply_attachments(note_object, _reply), do: note_object

  defp maybe_put_content_warning(note_object, record) do
    if Baudrate.Content.ContentWarning.warned?(record) do
      note_object
      |> Map.put("sensitive", true)
      |> then(fn o -> if record.summary, do: Map.put(o, "summary", record.summary), else: o end)
    else
      note_object
    end
  end

  # Returns the comment's stored AP ID, or derives the canonical one when the
  # stored value is missing. Defends against publishers emitting
  # `"object" => null` if post-insert stamping ever fails or for legacy rows.
  # The derivation needs no author lookup any more: since ADR 0050 a comment's
  # URI is `/ap/comments/:id`, built from the row's own id.
  defp comment_ap_id_or_derive(%{ap_id: ap_id}) when is_binary(ap_id) and ap_id != "", do: ap_id

  defp comment_ap_id_or_derive(%{id: id}) when is_integer(id),
    do: Federation.actor_uri(:comment, id)

  defp comment_ap_id_or_derive(_), do: nil

  defp build_image_attachments(images) do
    Enum.map(images, fn img ->
      %{
        "type" => "Image",
        "mediaType" => "image/webp",
        "url" =>
          "#{Federation.base_url()}#{Baudrate.Content.ArticleImageStorage.image_url(img.filename)}",
        "width" => img.width,
        "height" => img.height
      }
      |> then(fn attachment ->
        # The uploader's description, as the attachment `name` — the third of
        # the three builders that emit one, alongside the two in
        # `ObjectBuilder`. Omitted when there is none.
        case Baudrate.Content.ImageAlt.describe(img) do
          nil -> attachment
          alt -> Map.put(attachment, "name", alt)
        end
      end)
    end)
  end
end
