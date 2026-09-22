defmodule Baudrate.Federation.InboxHandler do
  @moduledoc """
  Dispatches incoming ActivityPub activities to appropriate handlers.

  Supported activity types:
    * `Follow` — auto-accept, create follower record, send Accept(Follow)
    * `Undo(Follow)` — remove follower record
    * `Undo(Like)` — remove article like
    * `Undo(Announce)` — remove announce record
    * `Create(Note)` — store as remote comment (if `inReplyTo` resolves to a local
      article or comment, including via remote reply chain walking), or as a
      direct message (if privately addressed to a local user)
    * `Create(Note) as DM` — private note addressed only to a local user (no public/followers)
    * `Create(Article)` — store as remote article in target board
    * `Create(Page)` — treat as `Create(Article)` (Lemmy interop)
    * `Like` — create article like for target article
    * `Announce` — record boost/share (bare URI or embedded object map);
      when the booster is followed by boards, routes Article/Page content to
      those boards; when followed by local users, creates a timeline item with
      `activity_type: "Announce"` and boost attribution. No outbound re-announce
      is triggered (loop-safe).
    * `Update(Article/Note/Page)` — update remote content with authorship check
    * `Update(Person/Group)` — refresh cached RemoteActor
    * `Delete(actor)` — remove all follower records and soft-delete all content
    * `Delete(content)` — soft-delete matching remote content with authorship check
    * `Accept(Follow)` — stub handler (future: mark outbound follow as accepted)
    * `Reject(Follow)` — stub handler (future: mark outbound follow as rejected)
    * `Move` — stub handler (future: migrate followers to new actor)

  ## Mastodon/Lemmy Compatibility

    * `attributedTo` may be an array — the first binary URI is used
    * `sensitive` + `summary` are handled as content warnings
    * Lemmy `Page` objects are treated identically to `Article`
    * Lemmy `Announce` with embedded object maps extracts the inner `id`
    * Cross-post deduplication: when a remote article with the same `ap_id`
      arrives via a second board inbox, it is linked to the additional board
      instead of being silently ignored
  """

  require Logger

  alias Baudrate.Content
  alias Baudrate.Federation

  alias Baudrate.Federation.{
    ActorResolver,
    AttachmentExtractor,
    Delivery,
    Sanitizer,
    Validator,
    Visibility
  }

  alias Baudrate.Messaging
  alias Baudrate.Moderation.ContentFilters

  # Reply-chain walking is rate limited (see `walk_remote_reply_chain/2`). The
  # context → `BaudrateWeb.RateLimits` direction follows the existing precedent
  # in `Baudrate.Content.LinkPreview.Fetcher`.
  alias BaudrateWeb.RateLimits

  # A Lemmy community does not boost a post; it **relays** the activity that
  # made it (FEP-1b12, ADR 0053). These are the activity types a group may
  # carry. `Announce` is deliberately absent: wrapping is bounded to one
  # level, so an Announce inside an Announce is refused rather than unwrapped
  # recursively by an attacker-chosen depth.
  @carried_activity_types ~w(Create Update Delete Like Undo)

  @doc """
  The checks an activity must pass before the inbox stores it
  (`Federation.Inbound`): well-formed with an id on the actor's host, from a
  domain that is not blocked, from an actor that is not suspended, not claiming
  to be a local actor, and signed by the actor it names.

  Returns `{:ok, activity}` or `{:error, reason}`.
  """
  def admit(activity, remote_actor) do
    with {:ok, activity} <- Validator.validate_activity(activity),
         :ok <- validate_domain(remote_actor),
         :ok <- validate_not_suspended(remote_actor),
         :ok <- validate_not_local(activity),
         :ok <- validate_actor_match(activity, remote_actor) do
      {:ok, activity}
    end
  end

  @doc """
  Handles an incoming activity from a verified remote actor.

  Repeats `admit/2` first: the inbox stored the activity earlier, and the
  domain may have been blocked or the actor suspended since.

  Returns `:ok` or `{:error, reason}`.
  """
  def handle(activity, remote_actor, target) do
    with {:ok, activity} <- admit(activity, remote_actor) do
      dispatch(activity, remote_actor, target)
    end
  end

  # --- Follow ---

  defp dispatch(%{"type" => "Follow"} = activity, remote_actor, target) do
    actor_uri = resolve_target_uri(activity, target)

    if actor_uri do
      # Reject follows targeting non-federated board actors (ap_enabled: false).
      # Board federation controls whether remote actors may follow the board.
      # This guard is needed for the shared inbox path where the controller
      # cannot pre-filter by ap_enabled.
      # A user who has blocked the actor refuses its follow, as Mastodon does.
      if non_federated_board_actor?(actor_uri, target) or
           follow_blocked_by_target?(actor_uri, remote_actor) do
        Delivery.enqueue_reject(activity, actor_uri, remote_actor)
        :ok
      else
        # The follower row and its Accept commit together (Phase 2C).
        Federation.federate(
          fn -> Federation.create_follower(actor_uri, remote_actor, activity["id"]) end,
          fn _follower -> Delivery.enqueue_accept(activity, actor_uri, remote_actor) end
        )
        |> case do
          {:ok, _follower} ->
            notify_follow_target(actor_uri, remote_actor)
            :ok

          {:error, %Ecto.Changeset{} = changeset} ->
            if has_unique_error?(changeset) do
              # Already a follower: the remote side asked again, so answer again.
              Delivery.enqueue_accept(activity, actor_uri, remote_actor)
              :ok
            else
              {:error, :follow_failed}
            end
        end
      end
    else
      {:error, :not_found}
    end
  end

  # --- Undo(Follow) ---

  defp dispatch(
         %{"type" => "Undo", "object" => %{"type" => "Follow"} = follow},
         remote_actor,
         _target
       ) do
    actor_uri = follow["object"]

    if is_binary(actor_uri) do
      Federation.delete_follower(actor_uri, remote_actor.ap_id)
      :ok
    else
      {:error, :invalid_undo}
    end
  end

  # --- Undo(Like) ---

  defp dispatch(
         %{"type" => "Undo", "object" => %{"type" => "Like", "id" => like_ap_id}},
         remote_actor,
         _target
       )
       when is_binary(like_ap_id) do
    Content.delete_article_like_by_ap_id(like_ap_id, remote_actor.id)
    Content.delete_comment_like_by_ap_id(like_ap_id, remote_actor.id)
    :ok
  end

  # --- Undo(Announce) ---

  defp dispatch(
         %{"type" => "Undo", "object" => %{"type" => "Announce", "id" => announce_ap_id}},
         remote_actor,
         _target
       )
       when is_binary(announce_ap_id) do
    Federation.delete_announce_by_ap_id(announce_ap_id, remote_actor.id)
    Content.delete_article_boost_by_ap_id(announce_ap_id, remote_actor.id)
    Content.delete_comment_boost_by_ap_id(announce_ap_id, remote_actor.id)
    :ok
  end

  # --- Create(Note) — DM or comment on a local article ---

  defp dispatch(
         %{"type" => "Create", "object" => %{"type" => "Note"} = object},
         remote_actor,
         _target
       ) do
    # Check if this is a poll vote first (vote Notes look like DMs — addressed
    # directly to the poll author with no public addressing)
    case maybe_handle_poll_vote(object, remote_actor) do
      :ok ->
        :ok

      :not_a_vote ->
        if direct_message?(object) do
          # Direct messages are never screened (ADR 0065).
          handle_incoming_dm(object, remote_actor)
        else
          screened(object, remote_actor, fn ->
            case handle_create_note_comment(object, remote_actor) do
              :ok ->
                :ok

              {:error, reason} when reason in [:article_not_found, :missing_in_reply_to] ->
                # Try auto-routing to boards that follow this actor, then fall back to timeline item
                maybe_auto_route_to_boards(object, remote_actor, "Note")

              other ->
                other
            end
          end)
        end
    end
  end

  # --- Create(Article/Page/Question) — remote article posted to a local board ---
  # Lemmy sends `Page` instead of `Article`; both are handled identically.
  # Question objects are treated as articles with an attached poll.

  defp dispatch(
         %{"type" => "Create", "object" => %{"type" => type} = object},
         remote_actor,
         _target
       )
       when type in ["Article", "Page", "Question"] do
    screened(object, remote_actor, fn -> create_article_object(object, remote_actor, type) end)
  end

  # --- Like ---

  defp dispatch(%{"type" => "Like", "object" => object_uri} = activity, remote_actor, _target)
       when is_binary(object_uri) do
    ap_id = activity["id"]

    case resolve_local_article_by_ap_or_uri(object_uri) do
      %{id: article_id} = article ->
        if not article_federated?(article) or blocked_by_author?(article, remote_actor) do
          :ok
        else
          case Content.create_remote_article_like(%{
                 ap_id: ap_id,
                 article_id: article_id,
                 remote_actor_id: remote_actor.id
               }) do
            {:ok, _like} ->
              Logger.info("federation.activity: type=Like(Article) ap_id=#{ap_id}")
              :ok

            {:error, %Ecto.Changeset{} = changeset} ->
              if has_unique_error?(changeset), do: :ok, else: {:error, :like_failed}
          end
        end

      nil ->
        # Try resolving as a local comment
        case Content.get_comment_by_ap_id(object_uri) do
          %{article_id: aid} = comment ->
            like_article = Baudrate.Repo.get(Baudrate.Content.Article, aid)

            if like_article && article_federated?(like_article) &&
                 not blocked_by_author?(comment, remote_actor) do
              case Content.create_remote_comment_like(%{
                     ap_id: ap_id,
                     comment_id: comment.id,
                     remote_actor_id: remote_actor.id
                   }) do
                {:ok, _like} ->
                  Logger.info("federation.activity: type=Like(Comment) ap_id=#{ap_id}")
                  :ok

                {:error, %Ecto.Changeset{} = changeset} ->
                  if has_unique_error?(changeset), do: :ok, else: {:error, :like_failed}
              end
            else
              :ok
            end

          nil ->
            # Target not local — ignore gracefully
            :ok
        end
    end
  end

  # --- Announce ---

  defp dispatch(%{"type" => "Announce", "object" => object_uri} = activity, remote_actor, _target)
       when is_binary(object_uri) do
    ap_id = activity["id"]

    # Track in general announces table
    case Federation.create_announce(%{
           ap_id: ap_id,
           target_ap_id: object_uri,
           activity_id: ap_id,
           remote_actor_id: remote_actor.id
         }) do
      {:ok, _announce} ->
        Logger.info("federation.activity: type=Announce ap_id=#{ap_id}")

      {:error, %Ecto.Changeset{} = changeset} ->
        unless has_unique_error?(changeset), do: Logger.info("federation.announce: failed")
    end

    # Also create article/comment boost if target is local content
    maybe_create_local_boost(object_uri, ap_id, remote_actor)

    # Route boosted content to boards and/or personal timelines
    handle_announce_content(ap_id, object_uri, remote_actor)

    :ok
  end

  # --- Announce carrying an activity (Lemmy groups, FEP-1b12) ---

  defp dispatch(
         %{"type" => "Announce", "object" => %{"type" => inner_type} = inner} = activity,
         group_actor,
         target
       )
       when inner_type in @carried_activity_types do
    handle_group_announce(activity, inner, group_actor, target)
  end

  # --- Announce with embedded object map (Lemmy interop) ---
  # Lemmy sends the full object as a map instead of a bare URI string.

  defp dispatch(
         %{"type" => "Announce", "object" => %{"id" => object_id} = embedded_object} = activity,
         remote_actor,
         _target
       )
       when is_binary(object_id) do
    # Same rule as the fetched path: an embedded object must never name one of
    # our own URIs. Otherwise a followed booster could Announce
    # `{"id": "<base>/ap/articles/<private-slug>"}` and have the existing local
    # article linked into every public board that follows them.
    if not Validator.valid_https_url?(object_id) or Validator.local_actor?(object_id) do
      Logger.warning(
        "federation.activity: type=Announce rejected invalid embedded object id=#{inspect(object_id)}"
      )

      {:error, :invalid_object_id}
    else
      ap_id = activity["id"]

      case Federation.create_announce(%{
             ap_id: ap_id,
             target_ap_id: object_id,
             activity_id: ap_id,
             remote_actor_id: remote_actor.id
           }) do
        {:ok, _announce} ->
          Logger.info("federation.activity: type=Announce(embedded) ap_id=#{ap_id}")

        {:error, %Ecto.Changeset{} = changeset} ->
          if has_unique_error?(changeset), do: :ok, else: {:error, :announce_failed}
      end

      # Route boosted content using the embedded object directly
      handle_announce_content(ap_id, object_id, remote_actor, embedded_object)

      :ok
    end
  end

  # --- Update(Note/Article/Page) — content update ---

  # --- Update(Question) — poll count refresh ---

  defp dispatch(
         %{"type" => "Update", "object" => %{"type" => "Question"} = object},
         remote_actor,
         _target
       ) do
    handle_update_question(object, remote_actor)
  end

  defp dispatch(
         %{"type" => "Update", "object" => %{"type" => type} = object},
         remote_actor,
         _target
       )
       when type in ["Note", "Article", "Page"] do
    with :ok <- validate_attribution_match(object, remote_actor) do
      case type do
        # Screened whatever the Update's own addressing says. The handler
        # rewrites the stored comment found by `ap_id`, so an exemption keyed
        # on the Update looking like a message let a peer post a clean public
        # reply and then edit filtered text into it with a privately
        # addressed Update. A message's own edits are never applied here at
        # all, so the one object this spares is a message we hold.
        "Note" ->
          if Messaging.get_message_by_ap_id(object["id"] || ""),
            do: :ok,
            else:
              screened(object, remote_actor, fn -> handle_update_note(object, remote_actor) end)

        t when t in ["Article", "Page"] ->
          screened(object, remote_actor, fn -> handle_update_article(object, remote_actor) end)
      end
    end
  end

  # --- Update(Person/Group/etc) — actor profile refresh ---

  defp dispatch(%{"type" => "Update", "actor" => actor_uri}, _remote_actor, _target) do
    Logger.info("federation.activity: type=Update actor=#{actor_uri}")
    ActorResolver.refresh(actor_uri)
    :ok
  end

  # --- Delete (actor deletion: object == actor_uri) ---

  defp dispatch(
         %{"type" => "Delete", "actor" => actor_uri, "object" => object},
         _remote_actor,
         _target
       )
       when object == actor_uri do
    Logger.info("federation.activity: type=Delete(actor) actor=#{actor_uri}")
    Federation.delete_followers_by_remote(actor_uri)
    Federation.cleanup_deleted_actor(actor_uri)
    :ok
  end

  # --- Delete (content deletion: object is a URI string != actor_uri) ---

  defp dispatch(
         %{"type" => "Delete", "actor" => _actor_uri, "object" => object_uri},
         remote_actor,
         _target
       )
       when is_binary(object_uri) do
    handle_delete_content(object_uri, remote_actor)
  end

  # --- Delete (content deletion: object is a Tombstone map) ---

  defp dispatch(
         %{"type" => "Delete", "actor" => _actor_uri, "object" => %{"id" => object_uri}},
         remote_actor,
         _target
       )
       when is_binary(object_uri) do
    handle_delete_content(object_uri, remote_actor)
  end

  # --- Block (remote actor blocking a local user) ---

  defp dispatch(%{"type" => "Block", "object" => object_uri} = _activity, remote_actor, _target)
       when is_binary(object_uri) do
    Logger.info(
      "federation.activity: type=Block actor=#{remote_actor.ap_id} target=#{object_uri}"
    )

    # Store informational record: remote actor blocked a local user.
    # We suppress delivery to this actor but don't enforce locally.
    :ok
  end

  # --- Undo(Block) ---

  defp dispatch(
         %{"type" => "Undo", "object" => %{"type" => "Block", "object" => _object_uri}},
         remote_actor,
         _target
       ) do
    Logger.info("federation.activity: type=Undo(Block) actor=#{remote_actor.ap_id}")
    :ok
  end

  # --- Flag (incoming report from remote instance) ---

  # The signer is the reporter (often the remote instance actor). The Flag's
  # objects name what is reported: local accounts, articles and comments.
  # Reports about nothing local are dropped, and `content` is optional.
  defp dispatch(%{"type" => "Flag"} = activity, remote_actor, _target) do
    objects = List.wrap(activity["object"]) |> Enum.filter(&is_binary/1)
    reason = flag_reason(activity["content"])
    report_attrs = build_flag_report_attrs(objects, remote_actor, reason)

    cond do
      not flag_has_local_target?(report_attrs) ->
        Logger.info("federation.flag_ignored: reason=no_local_target from=#{remote_actor.ap_id}")
        :ok

      RateLimits.check_inbound_flag(remote_actor.domain) != :ok ->
        :ok

      true ->
        case Baudrate.Moderation.create_remote_flag_report(report_attrs) do
          {:ok, :duplicate} ->
            :ok

          {:ok, _report} ->
            Logger.info("federation.activity: type=Flag from=#{remote_actor.ap_id}")
            :ok

          {:error, _} ->
            {:error, :flag_failed}
        end
    end
  end

  # --- Accept(Follow) — mark outbound follow as accepted ---

  defp dispatch(
         %{"type" => "Accept", "object" => %{"type" => "Follow"} = follow_obj},
         remote_actor,
         _target
       ) do
    follow_id = extract_follow_id(follow_obj)

    cond do
      is_nil(follow_id) ->
        Logger.info(
          "federation.activity: type=Accept(Follow) actor=#{remote_actor.ap_id} (no follow id)"
        )

      not follow_object_is_signer?(follow_obj, remote_actor) ->
        Logger.warning(
          "federation.activity: type=Accept(Follow) actor=#{remote_actor.ap_id} rejected (embedded Follow targets another actor)"
        )

      true ->
        accept_follow_with_fallback(follow_id, remote_actor)
    end

    :ok
  end

  # Accept where object is a string URI (some implementations send just the Follow ID)
  defp dispatch(
         %{"type" => "Accept", "object" => object_uri},
         remote_actor,
         _target
       )
       when is_binary(object_uri) do
    accept_follow_with_fallback(object_uri, remote_actor)
    :ok
  end

  # --- Reject(Follow) — mark outbound follow as rejected ---

  defp dispatch(
         %{"type" => "Reject", "object" => %{"type" => "Follow"} = follow_obj},
         remote_actor,
         _target
       ) do
    follow_id = extract_follow_id(follow_obj)

    cond do
      is_nil(follow_id) ->
        Logger.info(
          "federation.activity: type=Reject(Follow) actor=#{remote_actor.ap_id} (no follow id)"
        )

      not follow_object_is_signer?(follow_obj, remote_actor) ->
        Logger.warning(
          "federation.activity: type=Reject(Follow) actor=#{remote_actor.ap_id} rejected (embedded Follow targets another actor)"
        )

      true ->
        reject_follow_with_fallback(follow_id, remote_actor)
    end

    :ok
  end

  # Reject where object is a string URI
  defp dispatch(
         %{"type" => "Reject", "object" => object_uri},
         remote_actor,
         _target
       )
       when is_binary(object_uri) do
    reject_follow_with_fallback(object_uri, remote_actor)
    :ok
  end

  # --- Move — a followed account moved (ADR 0025) ---

  defp dispatch(
         %{"type" => "Move", "actor" => actor_uri, "target" => target_uri} = activity,
         remote_actor,
         _target
       )
       when is_binary(target_uri) do
    object_uri =
      case activity["object"] do
        %{"id" => id} when is_binary(id) -> id
        id when is_binary(id) -> id
        _ -> nil
      end

    cond do
      actor_uri != remote_actor.ap_id ->
        Logger.warning(
          "federation.activity: type=Move rejected actor_mismatch signer=#{remote_actor.ap_id} actor=#{actor_uri}"
        )

        {:error, :actor_mismatch}

      # The moved account is the signer itself; a Move of anyone else is refused.
      not is_nil(object_uri) and object_uri != actor_uri ->
        Logger.warning(
          "federation.activity: type=Move rejected object_mismatch actor=#{actor_uri} object=#{object_uri}"
        )

        {:error, :actor_mismatch}

      true ->
        Logger.info("federation.activity: type=Move from=#{actor_uri} to=#{target_uri}")
        Baudrate.AccountMigration.handle_inbound_move(remote_actor, target_uri)
    end
  end

  # --- Catch-all ---

  defp dispatch(%{"type" => type} = _activity, _remote_actor, _target) do
    Logger.info("federation.activity_unhandled: type=#{type}")
    :ok
  end

  defp create_article_object(object, remote_actor, type) do
    with :ok <- validate_attribution_match(object, remote_actor),
         {:ok, body, _body_html} <- sanitize_content(object),
         {:ok, board} <- resolve_target_board(object),
         :ok <- check_board_accept_policy(board, remote_actor) do
      create_article_in_board(object, body, remote_actor, board, type)
    else
      {:error, :board_not_found} ->
        # Auto-route: if the actor is followed by boards, create article there
        maybe_auto_route_to_boards(object, remote_actor, type)

      {:error, :not_authorized} ->
        Logger.info(
          "federation.activity: type=Create(#{type}) rejected by accept policy actor=#{remote_actor.ap_id}"
        )

        :ok

      other ->
        other
    end
  end

  # --- Content filters (ADR 0065) ---

  # Remote content can only be dropped or flagged: nothing arriving over
  # federation can be held, because holding it would mean deciding later
  # whether something another server already published exists here. A drop
  # answers `:ok`, like every other refusal in this module, so the sender
  # does not retry. A flag stores the content as usual and then opens a
  # report on whatever was stored under the object's id.
  defp screened(object, remote_actor, fun) do
    verdict = ContentFilters.screen_remote(object, remote_actor)

    case verdict.outcome do
      :pass ->
        fun.()

      :drop ->
        ContentFilters.record(verdict)

        Logger.info(
          "federation.content_filtered: actor=#{remote_actor.ap_id} object=#{inspect(object["id"])}"
        )

        :ok

      :flag ->
        ContentFilters.record(verdict)
        result = fun.()
        flag_stored(verdict, object, remote_actor)
        result
    end
  end

  defp flag_stored(verdict, %{"id" => id}, remote_actor) when is_binary(id) do
    target =
      cond do
        article = Content.get_article_by_ap_id(id) ->
          %{article_id: article.id, remote_actor_id: article.remote_actor_id}

        comment = Content.get_comment_by_ap_id(id) ->
          %{comment_id: comment.id, remote_actor_id: comment.remote_actor_id}

        item = Federation.get_timeline_item_by_ap_id(id) ->
          %{timeline_item_id: item.id, remote_actor_id: item.remote_actor_id}

        true ->
          nil
      end

    # Nothing stored means nothing here to read; the match is still recorded.
    if target do
      ContentFilters.flag(verdict, %{
        target
        | remote_actor_id: target.remote_actor_id || remote_actor.id
      })
    end

    :ok
  end

  defp flag_stored(_verdict, _object, _remote_actor), do: :ok

  # --- Update helpers ---

  defp handle_update_note(object, remote_actor) do
    with {:ok, ap_id} <- Validator.validate_object_id(object),
         :ok <- Validator.validate_object_origin(object, remote_actor) do
      case Content.get_comment_by_ap_id(ap_id) do
        %{remote_actor_id: actor_id} = comment when actor_id == remote_actor.id ->
          {:ok, body, body_html} = sanitize_content(object)

          body_html =
            body_html |> append_attachment_images(object) |> append_attachment_media(object)

          attrs = Map.merge(%{body: body, body_html: body_html}, content_warning(object))

          case Content.update_remote_comment(comment, attrs) do
            {:ok, _} ->
              Logger.info("federation.activity: type=Update(Note) ap_id=#{ap_id}")
              :ok

            {:error, _} ->
              {:error, :update_failed}
          end

        %{} ->
          {:error, :unauthorized}

        nil ->
          :ok
      end
    end
  end

  defp handle_update_article(object, remote_actor) do
    with {:ok, ap_id} <- Validator.validate_object_id(object),
         :ok <- Validator.validate_object_origin(object, remote_actor) do
      case Content.get_article_by_ap_id(ap_id) do
        %{remote_actor_id: actor_id} = article when actor_id == remote_actor.id ->
          {:ok, body, _body_html} = sanitize_content(object)
          title = object["name"] || article.title

          attrs = Map.merge(%{title: title, body: body}, content_warning(object))

          case Content.update_remote_article(article, attrs) do
            {:ok, _} ->
              Logger.info("federation.activity: type=Update(Article) ap_id=#{ap_id}")
              :ok

            {:error, _} ->
              {:error, :update_failed}
          end

        %{} ->
          {:error, :unauthorized}

        nil ->
          :ok
      end
    end
  end

  # --- Delete helpers ---

  defp handle_delete_content(object_uri, remote_actor) do
    # Try article first, then comment, then direct message
    cond do
      article = Content.get_article_by_ap_id(object_uri) ->
        if article.remote_actor_id == remote_actor.id do
          Content.soft_delete_article(article, remote: true)
          Logger.info("federation.activity: type=Delete(Article) ap_id=#{object_uri}")
          :ok
        else
          {:error, :unauthorized}
        end

      comment = Content.get_comment_by_ap_id(object_uri) ->
        if comment.remote_actor_id == remote_actor.id do
          Content.soft_delete_comment(comment, remote: true)
          Logger.info("federation.activity: type=Delete(Note) ap_id=#{object_uri}")
          :ok
        else
          {:error, :unauthorized}
        end

      dm = Messaging.get_message_by_ap_id(object_uri) ->
        if dm.sender_remote_actor_id == remote_actor.id do
          dm
          |> Baudrate.Messaging.DirectMessage.soft_delete_changeset()
          |> Baudrate.Repo.update()

          Logger.info("federation.activity: type=Delete(DM) ap_id=#{object_uri}")
          :ok
        else
          {:error, :unauthorized}
        end

      timeline_item = Federation.get_timeline_item_by_ap_id(object_uri) ->
        if timeline_item.remote_actor_id == remote_actor.id do
          Federation.soft_delete_timeline_item_by_ap_id(object_uri, remote_actor.id)
          Logger.info("federation.activity: type=Delete(TimelineItem) ap_id=#{object_uri}")
          :ok
        else
          {:error, :unauthorized}
        end

      true ->
        # Content not found — might have been deleted already
        :ok
    end
  end

  # --- Create(Note) comment helper ---

  defp handle_create_note_comment(object, remote_actor) do
    with :ok <- validate_attribution_match(object, remote_actor),
         :ok <- Validator.validate_object_origin(object, remote_actor),
         {:ok, ap_id} <- Validator.validate_object_id(object),
         {:ok, body, body_html} <- sanitize_content(object),
         {:ok, article, parent_id} <- resolve_reply_target(object, remote_actor) do
      cond do
        # Same gate as Like / Announce: an article that does not participate in
        # federation must not accept inbound replies either. Without this a
        # remote actor could guess a slug and inject content (and a
        # notification) into an article that lives only in a private or
        # non-AP-enabled board.
        not article_federated?(article) ->
          Logger.info(
            "federation.activity: type=Create(Note) rejected non_federated_article ap_id=#{ap_id}"
          )

          :ok

        # A lock is a moderation decision, and it has to hold on the side the
        # traffic comes from. `Permissions.can_comment_on_article?/2` refuses
        # local members on a locked thread, and the lock is even published as
        # `baudrate:locked` — but nothing checked it here, so a moderator who
        # locked a heated thread in a federated board kept receiving remote
        # replies, each of which rendered and notified the author.
        article.locked ->
          Logger.info(
            "federation.activity: type=Create(Note) rejected locked_article ap_id=#{ap_id}"
          )

          :ok

        # A withdrawn article accepts nothing either: the comment would be
        # invisible, but the author would still be notified about a post they
        # deleted. The resolvers use a bare `Repo.get`, which does not filter
        # `deleted_at`, so this is the check.
        not is_nil(article.deleted_at) ->
          Logger.info(
            "federation.activity: type=Create(Note) rejected deleted_article ap_id=#{ap_id}"
          )

          :ok

        # A reply to the content of a user who has blocked the sender is
        # refused, exactly like a local comment across a block.
        reply_blocked?(article, parent_id, remote_actor) ->
          Logger.info("federation.activity: type=Create(Note) rejected blocked ap_id=#{ap_id}")
          :ok

        # Idempotency: if comment with this ap_id already exists, return :ok
        Content.get_comment_by_ap_id(ap_id) ->
          :ok

        true ->
          url = extract_url(object)
          visibility = Visibility.from_addressing(object)

          body_html =
            body_html |> append_attachment_images(object) |> append_attachment_media(object)

          attrs =
            Map.merge(
              %{
                body: body,
                body_html: body_html,
                ap_id: ap_id,
                url: url,
                article_id: article.id,
                parent_id: parent_id,
                remote_actor_id: remote_actor.id,
                visibility: visibility
              },
              content_warning(object)
            )

          case Content.create_remote_comment(attrs) do
            {:ok, _comment} ->
              Logger.info("federation.activity: type=Create(Note) ap_id=#{ap_id}")

              Baudrate.Notification.Hooks.notify_remote_comment_created(
                article.id,
                parent_id,
                remote_actor.id
              )

              :ok

            {:error, %Ecto.Changeset{} = changeset} ->
              if has_unique_error?(changeset), do: :ok, else: {:error, :create_comment_failed}
          end
      end
    end
  end

  # --- Direct Message helpers ---

  # A Note is considered a DM when it has no public or followers-collection
  # addresses and is directed to at least one local user actor URI.
  defp direct_message?(object) do
    to = List.wrap(object["to"])
    cc = List.wrap(object["cc"])
    all_addrs = to ++ cc

    no_public = "https://www.w3.org/ns/activitystreams#Public" not in all_addrs
    no_followers = Enum.all?(all_addrs, fn uri -> !String.ends_with?(uri, "/followers") end)
    has_local_recipient = Enum.any?(to, &local_user_uri?/1)

    no_public && no_followers && has_local_recipient
  end

  defp local_user_uri?(uri) when is_binary(uri) do
    base = Federation.base_url()
    String.starts_with?(uri, "#{base}/ap/users/")
  end

  defp local_user_uri?(_), do: false

  defp handle_incoming_dm(object, remote_actor) do
    with :ok <- validate_attribution_match(object, remote_actor),
         :ok <- Validator.validate_object_origin(object, remote_actor),
         {:ok, ap_id} <- Validator.validate_object_id(object),
         {:ok, body, body_html} <- sanitize_content(object),
         {:ok, local_user} <- resolve_dm_recipient(object),
         :ok <- check_dm_permission(local_user, remote_actor) do
      # Idempotency check
      if Messaging.get_message_by_ap_id(ap_id) do
        :ok
      else
        body_html = append_attachment_images(body_html, object)

        case Messaging.receive_remote_dm(local_user, remote_actor, %{
               body: body,
               body_html: body_html,
               ap_id: ap_id,
               ap_in_reply_to: object["inReplyTo"]
             }) do
          {:ok, _message} ->
            Logger.info("federation.activity: type=Create(Note/DM) ap_id=#{ap_id}")
            :ok

          {:error, %Ecto.Changeset{} = changeset} ->
            if has_unique_error?(changeset), do: :ok, else: {:error, :create_dm_failed}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp resolve_dm_recipient(object) do
    base = Federation.base_url()
    prefix = "#{base}/ap/users/"

    to_list = List.wrap(object["to"])

    local_uri =
      Enum.find(to_list, fn uri -> is_binary(uri) && String.starts_with?(uri, prefix) end)

    if local_uri do
      username = String.replace_prefix(local_uri, prefix, "")

      case Baudrate.Auth.get_user_by_username(username) do
        %{status: "active"} = user -> {:ok, user}
        _ -> {:error, :recipient_not_found}
      end
    else
      {:error, :recipient_not_found}
    end
  end

  defp check_dm_permission(local_user, remote_actor) do
    if Messaging.can_receive_remote_dm?(local_user, remote_actor) do
      :ok
    else
      {:error, :dm_rejected}
    end
  end

  # --- Timeline item fallback ---

  defp maybe_create_timeline_item(object, remote_actor, object_type) do
    # Only create timeline items if at least one local user follows this actor
    case Federation.local_followers_of_remote_actor(remote_actor.id) do
      [] ->
        :ok

      _followers ->
        with {:ok, ap_id} <- Validator.validate_object_id(object),
             :ok <- Validator.validate_object_origin(object, remote_actor) do
          # Idempotency check
          if Federation.get_timeline_item_by_ap_id(ap_id) do
            :ok
          else
            with :ok <- validate_attribution_match(object, remote_actor),
                 {:ok, body, body_html} <- sanitize_content(object) do
              published_at = parse_published(object["published"])
              title = timeline_item_title(object_type, object)
              source_url = extract_url(object) || object["id"]
              visibility = Visibility.from_addressing(object)

              case Federation.create_timeline_item(
                     %{
                       remote_actor_id: remote_actor.id,
                       activity_type: "Create",
                       object_type: object_type,
                       ap_id: ap_id,
                       title: title,
                       body: body,
                       body_html: body_html,
                       source_url: source_url,
                       attachments: extract_attachments(object),
                       visibility: visibility,
                       published_at: published_at
                     }
                     |> Map.merge(content_warning(object))
                   ) do
                {:ok, _timeline_item} ->
                  Logger.info(
                    "federation.activity: type=Create(#{object_type}/TimelineItem) ap_id=#{ap_id}"
                  )

                  :ok

                {:error, %Ecto.Changeset{} = changeset} ->
                  if has_unique_error?(changeset),
                    do: :ok,
                    else: {:error, :create_timeline_item_failed}
              end
            end
          end
        end
    end
  end

  # --- Group Announce (FEP-1b12) ---

  # A Lemmy community is a hub, not a booster: members send activities *to*
  # the community, and the community announces them to every subscriber. So
  # its `Announce` wraps an **activity** — `Create`, `Update`, `Delete`,
  # `Like`, `Undo` — where a Mastodon boost wraps an object. These were
  # dropped: `handle_announce_object/3` accepts only `Note`/`Article`/`Page`,
  # so every post in every followed Lemmy community was silently discarded.
  #
  # The whole security question is **who may speak for the inner actor**. The
  # HTTP signature on the outer Announce is the *group's*; the inner activity
  # carries no signature we can check. So there are exactly two safe readings,
  # and this takes both:
  #
  #   * a **`Create`** names an object, and an object has an origin that can
  #     be checked. It goes to the announced-content path, which binds the
  #     object's `attributedTo` to its own host and routes it to the boards
  #     following the group. No host comparison, and no new trust: the object
  #     is verified by the host that can prove it.
  #
  #   * **everything else** — `Update`, `Delete`, `Like`, `Undo` — is an
  #     activity whose entire meaning is "this actor did this". There is
  #     nothing to fetch and verify, because the claim *is* the actor's. So it
  #     is honoured only when the actor is on the **group's own host**: the
  #     group's signature proves that host, so the same instance vouches for
  #     both. That is the whole basis for trusting a relayed activity, and it
  #     is why the comparison is `Validator.same_host?/2` — the strict one —
  #     rather than a prefix or suffix test. A community relaying another
  #     instance's `Delete` is asking to be taken at its word about somebody
  #     else's actor; taking it would let any community delete any post
  #     anywhere.
  #
  # An honoured activity runs through `admit/2`'s checks one by one —
  # id-to-actor binding, not-local, domain block, suspension — and then
  # through `dispatch/3` with **its own** actor rather than the group's. The
  # single check that cannot apply is `validate_actor_match/2`, because the
  # inner activity carries no signature of its own; the host comparison above
  # is what stands in for it.
  #
  # Processing is at-least-once and the same activity may also arrive
  # directly, so the handlers' existing idempotency (unique `ap_id`) is what
  # makes the double delivery harmless.
  defp handle_group_announce(announce, inner, group_actor, target) do
    with {:ok, inner} <- Validator.validate_activity(inner),
         :ok <- validate_not_local(inner),
         {:ok, inner_actor} <- resolve_carried_actor(inner["actor"]),
         :ok <- validate_domain(inner_actor),
         :ok <- validate_not_suspended(inner_actor) do
      carry(announce, inner, inner_actor, group_actor, target)
    else
      {:error, reason} ->
        Logger.info(
          "federation.group_announce_refused: group=#{group_actor.ap_id} reason=#{inspect(reason)}"
        )

        # `:ok`, not an error: a refused relay must not make the sender retry
        # forever, exactly like a refused Like or reply.
        :ok
    end
  end

  # A `Create` is content arriving in the community, and the announced-content
  # path already knows exactly what to do with it — including the part that is
  # easy to get wrong. The post belongs in the boards that follow the
  # **group**, not the boards that follow its author, whom nobody here need
  # follow at all; `maybe_route_announce_to_boards/3` routes on the announcer
  # while attributing the article to `attributedTo`, bound to the object's own
  # origin. So this needs no host comparison and grants no new trust: the
  # object is verified by the host that can prove it, exactly as a Mastodon
  # boost of the same post would be.
  defp carry(announce, %{"type" => "Create", "object" => object}, _inner, group_actor, _target)
       when is_map(object) do
    case object["id"] do
      id when is_binary(id) ->
        handle_announce_content(announce["id"], id, group_actor, object)

      _ ->
        :ok
    end
  end

  # Everything else — `Update`, `Delete`, `Like`, `Undo` — is an activity
  # whose whole meaning is "this actor did this". There is no object to fetch
  # and verify: the claim *is* the actor's. So it is honoured only when the
  # group can speak for that actor, which means only when the actor is on the
  # group's own host.
  defp carry(_announce, inner, inner_actor, group_actor, target) do
    if Validator.same_host?(inner["actor"], group_actor.ap_id) do
      Logger.info(
        "federation.activity: type=Announce(#{inner["type"]}) relayed_by=#{group_actor.ap_id}"
      )

      dispatch(inner, inner_actor, target)
    else
      # A community relaying somebody else's Delete or Like is asking to be
      # taken at its word about another instance's actor. Taking it would let
      # any community delete any post or fake any like, anywhere.
      Logger.info(
        "federation.group_announce_cross_origin_dropped: group=#{group_actor.ap_id} " <>
          "type=#{inner["type"]} actor=#{inner["actor"]}"
      )

      :ok
    end
  end

  # Resolving the inner actor is what refuses a blocked domain before anything
  # else happens (`ActorResolver` passes `refuse_blocked: true`), and what
  # binds the fetched document's `id` to the host it came from (ADR 0046).
  defp resolve_carried_actor(actor_uri) when is_binary(actor_uri) do
    case ActorResolver.resolve(actor_uri) do
      {:ok, actor} -> {:ok, actor}
      {:error, reason} -> {:error, {:carried_actor_unresolved, reason}}
    end
  end

  defp resolve_carried_actor(_), do: {:error, :carried_actor_missing}

  # --- Announce content routing ---

  # Routes boosted content to boards (if the booster is followed by a board)
  # and/or to personal timelines (if the booster is followed by local users).
  # Fetches the boosted object via signed GET to extract content metadata.
  #
  # Loop prevention: `create_remote_article` does NOT trigger outbound
  # federation (no `publish_article_created` call), so no re-announce
  # storm can occur.
  defp handle_announce_content(announce_ap_id, object_uri, booster_actor) do
    has_board_followers = Federation.boards_following_actor(booster_actor.id) != []
    has_user_followers = Federation.local_followers_of_remote_actor(booster_actor.id) != []

    if has_board_followers or has_user_followers do
      fetch_and_handle_announce_object(announce_ap_id, object_uri, booster_actor)
    else
      :ok
    end
  end

  # Variant with embedded object (Lemmy interop) — skips remote fetch
  defp handle_announce_content(announce_ap_id, _object_uri, booster_actor, embedded_object) do
    handle_announce_object(announce_ap_id, embedded_object, booster_actor)
  end

  # Mirrors the reply-chain walk's check, which is the same class of hazard:
  # a URI supplied by a verified sender that names somebody else's host.
  defp object_host_blocked?(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) ->
        if Baudrate.Federation.Validator.domain_blocked?(host) do
          Logger.info("federation.announce_object_domain_blocked: host=#{host}")
          true
        else
          false
        end

      _ ->
        true
    end
  end

  defp fetch_and_handle_announce_object(announce_ap_id, object_uri, booster_actor) do
    alias Baudrate.Federation.{HTTPClient, KeyStore, Validator}

    # The domain check belongs here as well as in the transport: a followed
    # actor on an allowed domain can Announce any URI it likes, so without it
    # an attacker chose which host we signed a request to. This was the only
    # remaining outbound fetch with neither the pre-check nor
    # `refuse_blocked:` (ADR 0030 decision 9).
    if not Validator.valid_https_url?(object_uri) or Validator.local_actor?(object_uri) or
         object_host_blocked?(object_uri) do
      :ok
    else
      with {:ok, _} <- KeyStore.ensure_site_keypair(),
           {:ok, private_key} <- KeyStore.decrypt_site_private_key() do
        site_uri = Federation.actor_uri(:site, nil)
        key_id = "#{site_uri}#main-key"

        case HTTPClient.signed_get(object_uri, private_key, key_id, refuse_blocked: true) do
          {:ok, %{body: body}} ->
            case Jason.decode(body) do
              {:ok, object} ->
                # Origin-binding: the fetched document must be served by its own
                # authoritative host — its `id` host must match the URL we
                # fetched it from. Without this, a booster could point
                # `object_uri` at a host that serves a document `id` claiming a
                # different origin (id/URL confusion).
                if same_host?(object["id"], object_uri) do
                  handle_announce_object(announce_ap_id, object, booster_actor)
                else
                  Logger.warning(
                    "federation.announce: object id origin mismatch for #{object_uri}"
                  )

                  :ok
                end

              {:error, _} ->
                Logger.warning("federation.announce: invalid JSON from #{object_uri}")

                :ok
            end

          {:error, reason} ->
            Logger.warning(
              "federation.announce: fetch failed for #{object_uri}: #{inspect(reason)}"
            )

            :ok
        end
      else
        _ -> :ok
      end
    end
  end

  defp handle_announce_object(announce_ap_id, object, booster_actor) do
    object_type = object["type"]

    cond do
      object_type not in ["Note", "Article", "Page"] ->
        :ok

      # Authorship origin-binding: an object may only be authored by an actor on
      # its own domain. If `attributedTo` names an actor on a different host than
      # the object `id`, the booster (or a hostile object host) is trying to
      # attribute attacker-chosen content to a victim on another instance —
      # impersonation + `ap_id` cache poisoning. Drop it rather than fall back to
      # crediting the booster with foreign content.
      not announce_attribution_bound?(object) ->
        Logger.warning(
          "federation.announce: attributedTo/object origin mismatch ap_id=#{announce_ap_id}"
        )

        :ok

      true ->
        # A boosted object is content arriving here like any other, whether it
        # came embedded, fetched, or carried by a group (ADR 0065).
        screened(object, booster_actor, fn ->
          # Route to boards that follow the booster
          maybe_route_announce_to_boards(object, booster_actor, object_type)

          # Create timeline item for users that follow the booster
          maybe_create_announce_timeline_item(announce_ap_id, object, booster_actor, object_type)
        end)
    end
  end

  # An announced object's author must live on the same host as the object `id`.
  # A missing `attributedTo` is permitted (authorship falls back to the booster,
  # who is the verified signer of the Announce); a present one must be same-host.
  defp announce_attribution_bound?(object) do
    case resolve_attributed_to(object) do
      nil -> true
      author_uri -> same_host?(author_uri, object["id"])
    end
  end

  # Case-insensitive host equality for two absolute HTTPS URIs. Returns false if
  # either is missing or unparseable (fail-closed).
  # `Validator.same_host?/2`, not a copy. There were two, and they disagreed:
  # this one accepted a pair of hostless URIs (`https:///x`, which `URI.parse`
  # gives `host: ""`) as same-origin, where the Validator's rejects them. A
  # security primitive with two definitions is one definition and one
  # liability (ADR 0046).
  defp same_host?(a, b), do: Validator.same_host?(a, b)

  # Routes boosted Article/Page content to boards that follow the booster.
  # Notes are not routed to boards (they become timeline items only).
  defp maybe_route_announce_to_boards(object, booster_actor, object_type)
       when object_type in ["Article", "Page"] do
    case Federation.boards_following_actor(booster_actor.id) do
      [] ->
        :ok

      boards ->
        with {:ok, ap_id} <- Validator.validate_object_id(object),
             {:ok, body, _body_html} <- sanitize_content(object) do
          existing = Content.get_article_by_ap_id(ap_id)

          # Resolve the original author first: an existing article is only
          # linked into the following boards when it belongs to that author
          # (`remote_actor_id` match). Any other match — a local article, or a
          # remote one by someone else — is a booster trying to re-home
          # content it does not own.
          author_uri = resolve_attributed_to(object)

          author_actor_id =
            case if(author_uri, do: ActorResolver.resolve(author_uri)) do
              {:ok, actor} -> actor.id
              _ -> booster_actor.id
            end

          cond do
            existing && existing.remote_actor_id == author_actor_id ->
              Enum.each(boards, fn board ->
                Content.add_article_to_board(existing, board.id)
              end)

              :ok

            existing ->
              Logger.warning(
                "federation.announce: refused to link existing article ap_id=#{ap_id} to boards (not owned by announced author)"
              )

              :ok

            true ->
              title = derive_title(object, body)
              slug = Content.generate_slug(title)
              board_ids = Enum.map(boards, & &1.id)
              poll_opts = extract_poll_from_object(object, ap_id)
              image_attachments = AttachmentExtractor.extract_image_attachments(object)
              url = extract_url(object)
              visibility = Visibility.from_addressing(object)

              case Content.create_remote_article(
                     %{
                       title: title,
                       body: body,
                       slug: slug,
                       ap_id: ap_id,
                       url: url,
                       remote_actor_id: author_actor_id,
                       visibility: visibility
                     }
                     |> Map.merge(content_warning(object)),
                     board_ids,
                     poll_opts ++ [image_attachments: image_attachments]
                   ) do
                {:ok, _multi} ->
                  Logger.info(
                    "federation.activity: type=Announce(#{object_type}) ap_id=#{ap_id} routed_to=#{length(boards)}"
                  )

                  :ok

                {:error, :article, %Ecto.Changeset{} = changeset, _} ->
                  if has_unique_error?(changeset), do: :ok, else: {:error, :create_article_failed}

                {:error, _step, _reason, _changes} ->
                  {:error, :create_article_failed}
              end
          end
        end
    end
  end

  defp maybe_route_announce_to_boards(_object, _booster_actor, _object_type), do: :ok

  defp maybe_create_announce_timeline_item(announce_ap_id, object, booster_actor, object_type) do
    case Federation.local_followers_of_remote_actor(booster_actor.id) do
      [] ->
        :ok

      _followers ->
        if Federation.get_timeline_item_by_ap_id(announce_ap_id) do
          :ok
        else
          with {:ok, body, body_html} <- sanitize_content(object) do
            # Resolve the original author
            author_uri = resolve_attributed_to(object)

            content_actor_id =
              case if(author_uri, do: ActorResolver.resolve(author_uri)) do
                {:ok, actor} -> actor.id
                _ -> booster_actor.id
              end

            published_at = parse_published(object["published"])
            title = timeline_item_title(object_type, object)
            source_url = extract_url(object) || object["id"]
            visibility = Visibility.from_addressing(object)

            case Federation.create_timeline_item(%{
                   remote_actor_id: content_actor_id,
                   boosted_by_actor_id: booster_actor.id,
                   activity_type: "Announce",
                   object_type: object_type,
                   ap_id: announce_ap_id,
                   title: title,
                   body: body,
                   body_html: body_html,
                   source_url: source_url,
                   attachments: extract_attachments(object),
                   visibility: visibility,
                   published_at: published_at
                 }) do
              {:ok, _timeline_item} ->
                Logger.info(
                  "federation.activity: type=Announce(#{object_type}/TimelineItem) ap_id=#{announce_ap_id}"
                )

                :ok

              {:error, %Ecto.Changeset{} = changeset} ->
                if has_unique_error?(changeset),
                  do: :ok,
                  else: {:error, :create_timeline_item_failed}
            end
          else
            _ -> :ok
          end
        end
    end
  end

  defp resolve_attributed_to(%{"attributedTo" => attributed_to}) when is_binary(attributed_to) do
    attributed_to
  end

  defp resolve_attributed_to(%{"attributedTo" => [first | _]}) when is_binary(first) do
    first
  end

  defp resolve_attributed_to(%{"attributedTo" => [%{"id" => id} | _]}) when is_binary(id) do
    id
  end

  defp resolve_attributed_to(_), do: nil

  defp parse_published(nil), do: now_truncated()

  # Clamped to now, like `Bots.SyndicationFeedParser.clamp_published_at/1` does for the
  # other ingest path. `published_at` is peer-supplied and the timeline orders
  # on it, so `"published": "2099-01-01T00:00:00Z"` pinned an item to slot one
  # of every follower's timeline — outranking local articles and comments too,
  # since they sort by `inserted_at` in the same merge — and stayed there
  # until retention removed it, which ages by `inserted_at` and so never came
  # sooner. A date in the future is not a date we can honour.
  defp parse_published(str) when is_binary(str) do
    now = now_truncated()

    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt = DateTime.truncate(dt, :second)
        if DateTime.compare(dt, now) == :gt, do: now, else: dt

      _ ->
        now
    end
  end

  defp now_truncated, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # --- Content processing helpers ---

  defp validate_attribution_match(%{"attributedTo" => attributed}, remote_actor)
       when is_binary(attributed) do
    if attributed == remote_actor.ap_id do
      :ok
    else
      {:error, :attribution_mismatch}
    end
  end

  # Mastodon sometimes sends attributedTo as an array
  # (e.g., ["https://example.com/users/alice", %{"type" => "Organization", ...}]).
  # Extract the first binary URI and compare.
  defp validate_attribution_match(%{"attributedTo" => attributed_list}, remote_actor)
       when is_list(attributed_list) do
    case Enum.find(attributed_list, &is_binary/1) do
      nil -> :ok
      uri -> validate_attribution_match(%{"attributedTo" => uri}, remote_actor)
    end
  end

  defp validate_attribution_match(_object, _remote_actor), do: :ok

  defp sanitize_content(object) do
    raw_content = extract_body(object)

    case Validator.validate_content_size(raw_content) do
      :ok ->
        body_html = Sanitizer.sanitize(raw_content)
        body = strip_html(raw_content)
        {:ok, body, body_html}

      error ->
        error
    end
  end

  defp extract_body(object) do
    raw =
      case object do
        %{"content" => content} when is_binary(content) and content != "" ->
          content

        %{"source" => %{"content" => source}} when is_binary(source) and source != "" ->
          source

        _ ->
          ""
      end

    raw
  end

  # A content warning is stored in its own fields, never glued onto the front
  # of the body (ADR 0052). It used to be prefixed as `[CW: …]` onto the body,
  # which made the warning indistinguishable from the thing it was warning
  # about: nothing could render it collapsed, nothing could publish it back
  # out as a warning, and the reader was shown the content with a label above
  # it. Merge this into the attrs of anything built from a remote object.
  #
  # `summary` is truncated and `sensitive` derived by
  # `Content.ContentWarning.validate/1` in the changeset; this only reads what
  # the peer sent.
  defp content_warning(object) do
    %{summary: object["summary"], sensitive: object["sensitive"] == true}
  end

  defp derive_title(object, body),
    do: Baudrate.Content.TitleDeriver.derive_title(object, body)

  # A timeline item's title is the remote object's `name` verbatim. Unlike
  # `content` it never passes through `Validator.validate_content_size/1`, so
  # without this an `Article`/`Page` could park a payload-sized string in the
  # column and render it on every viewer's `/timeline`. Truncating (rather than
  # rejecting in the changeset) keeps a merely over-long legitimate title.
  defp timeline_item_title(object_type, object) when object_type in ["Article", "Page"] do
    case object["name"] do
      name when is_binary(name) and name != "" ->
        Baudrate.Content.TitleDeriver.truncate_title(name, 255)

      _ ->
        nil
    end
  end

  defp timeline_item_title(_object_type, _object), do: nil

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>\s*<p[^>]*>/, "\n\n")
    |> Baudrate.Sanitizer.Native.strip_tags()
    |> decode_html_entities()
    |> String.trim()
  end

  defp strip_html(_), do: ""

  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&#160;", " ")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&apos;", "'")
  end

  # --- Reply/target resolution helpers ---

  defp resolve_reply_target(%{"inReplyTo" => in_reply_to}, remote_actor)
       when is_binary(in_reply_to) do
    case resolve_in_reply_to_locally(in_reply_to) do
      {:ok, _article, _parent_id} = ok ->
        ok

      {:error, _} ->
        # The inReplyTo points to a remote object we don't have locally.
        # Walk up the reply chain by fetching remote objects to find a
        # known ancestor (e.g. a stored article or comment).
        walk_remote_reply_chain(in_reply_to, remote_actor.domain)
    end
  end

  defp resolve_reply_target(_, _), do: {:error, :missing_in_reply_to}

  # Tries to resolve an inReplyTo URI against local data only.
  defp resolve_in_reply_to_locally(uri) do
    # Check if it's a reply to an existing comment (threading)
    case Content.get_comment_by_ap_id(uri) do
      %{article_id: article_id, id: parent_id} ->
        article = Baudrate.Repo.get(Baudrate.Content.Article, article_id)
        if article, do: {:ok, article, parent_id}, else: {:error, :article_not_found}

      nil ->
        # Check if it's a direct reply to a local article
        case resolve_local_article_by_ap_or_uri(uri) do
          %{} = article ->
            {:ok, article, nil}

          nil ->
            # Fallback: parse #note-{id} fragment for local comments that may
            # lack a stored ap_id (created before ap_id stamping was added)
            resolve_local_comment_by_fragment(uri)
        end
    end
  end

  @reply_chain_max_depth 5
  @reply_chain_max_hosts 3

  # Fetches remote objects following inReplyTo links up the chain until we find
  # an ancestor that maps to a known local article or comment.
  #
  # Every hop is an outbound request driven entirely by attacker-supplied data
  # (a fabricated `inReplyTo`), so the walk is bounded four ways: depth, the
  # number of distinct hosts it may touch, a visited-URI set (a self-referential
  # chain would otherwise burn the full depth), and two rate limits — one keyed
  # on the *target* host, so a swarm of hostile domains cannot combine to
  # amplify against one victim, and one on the sending domain.
  #
  # Deliberately no negative cache: it would need a fifth cache process and buys
  # little once the rate limiter bounds the flow.
  defp walk_remote_reply_chain(uri, sender_domain) do
    case RateLimits.check_reply_chain_domain(sender_domain) do
      :ok ->
        do_walk_reply_chain(uri, sender_domain, %{
          depth: 0,
          hosts: MapSet.new(),
          seen: MapSet.new()
        })

      {:error, :rate_limited} ->
        {:error, :article_not_found}
    end
  end

  defp do_walk_reply_chain(_uri, _sender_domain, %{depth: depth})
       when depth >= @reply_chain_max_depth do
    {:error, :article_not_found}
  end

  defp do_walk_reply_chain(uri, sender_domain, state) do
    alias Baudrate.Federation.{HTTPClient, Validator}

    host = URI.parse(uri).host
    hosts = MapSet.put(state.hosts, host)

    cond do
      Validator.local_actor?(uri) ->
        # Already checked locally — give up to avoid infinite loops
        {:error, :article_not_found}

      MapSet.member?(state.seen, uri) ->
        {:error, :article_not_found}

      is_nil(host) ->
        {:error, :article_not_found}

      # The walk follows attacker-supplied `inReplyTo` URIs, so it is exactly
      # the path that would carry us into an instance we have blocked
      # (ADR 0030).
      Validator.domain_blocked?(host) ->
        Logger.info("federation.reply_chain_domain_blocked: host=#{host}")
        {:error, :article_not_found}

      MapSet.size(hosts) > @reply_chain_max_hosts ->
        Logger.info("federation.reply_chain_host_limit: sender=#{sender_domain}")
        {:error, :article_not_found}

      RateLimits.check_reply_chain_fetch(host) != :ok ->
        Logger.info("federation.reply_chain_rate_limited: host=#{host} sender=#{sender_domain}")

        {:error, :article_not_found}

      true ->
        state = %{
          state
          | depth: state.depth + 1,
            hosts: hosts,
            seen: MapSet.put(state.seen, uri)
        }

        with {:ok, %{body: body}} when is_binary(body) <-
               HTTPClient.get(uri,
                 headers: [{"accept", "application/activity+json"}],
                 refuse_blocked: true
               ),
             {:ok, %{"inReplyTo" => parent_uri}} when is_binary(parent_uri) <-
               Jason.decode(body) do
          case resolve_in_reply_to_locally(parent_uri) do
            {:ok, article, _parent_id} ->
              # Found a known ancestor — the reply is to this article (no
              # parent_id since the intermediate comments aren't stored)
              {:ok, article, nil}

            {:error, _} ->
              do_walk_reply_chain(parent_uri, sender_domain, state)
          end
        else
          _ -> {:error, :article_not_found}
        end
    end
  end

  # Parses a local comment URI like "https://host/ap/users/alice#note-42"
  # to resolve old comments that were created before ap_id stamping.
  defp resolve_local_comment_by_fragment(uri) do
    base = Baudrate.Federation.base_url()

    with true <- String.starts_with?(uri, base),
         %URI{fragment: "note-" <> id_str} <- URI.parse(uri),
         {comment_id, ""} <- Integer.parse(id_str),
         %{article_id: article_id, deleted_at: nil} = comment <- Content.get_comment(comment_id),
         %{} = article <- Baudrate.Repo.get(Baudrate.Content.Article, article_id) do
      # Backfill the ap_id for future lookups
      if is_nil(comment.ap_id) do
        comment |> Ecto.Changeset.change(ap_id: uri) |> Baudrate.Repo.update()
      end

      {:ok, article, comment.id}
    else
      _ -> {:error, :article_not_found}
    end
  end

  defp resolve_local_article_by_ap_or_uri(uri) when is_binary(uri) do
    # Try by ap_id first
    case Content.get_article_by_ap_id(uri) do
      %{} = article ->
        article

      nil ->
        # Try matching either the canonical AP URI (`/ap/articles/:slug`) or
        # the public human URL (`/articles/:slug`). Remote implementations
        # that discovered the article via its human URL may address Like /
        # Announce / Create activities at that URL, so we resolve both.
        base = Federation.base_url()
        ap_prefix = "#{base}/ap/articles/"
        web_prefix = "#{base}/articles/"

        slug =
          cond do
            String.starts_with?(uri, ap_prefix) ->
              String.replace_prefix(uri, ap_prefix, "")

            String.starts_with?(uri, web_prefix) ->
              String.replace_prefix(uri, web_prefix, "")

            true ->
              nil
          end

        if is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug) do
          Baudrate.Repo.get_by(Baudrate.Content.Article, slug: slug)
        end
    end
  end

  defp resolve_local_article_by_ap_or_uri(_), do: nil

  # --- Accept policy and auto-routing helpers ---

  defp check_board_accept_policy(%{ap_accept_policy: "open"}, _remote_actor), do: :ok

  defp check_board_accept_policy(%{ap_accept_policy: "followers_only"} = board, remote_actor) do
    if Federation.board_follows_actor?(board.id, remote_actor.id) do
      :ok
    else
      {:error, :not_authorized}
    end
  end

  defp create_article_in_board(object, body, remote_actor, board, type) do
    with {:ok, ap_id} <- Validator.validate_object_id(object),
         :ok <- Validator.validate_object_origin(object, remote_actor) do
      existing = Content.get_article_by_ap_id(ap_id)

      if existing do
        # Cross-post: link to additional board if not already linked.
        # Only the article's original author (matched by remote_actor_id)
        # may add it to additional boards — otherwise any verified actor
        # could spuriously link another author's article elsewhere.
        if existing.remote_actor_id == remote_actor.id do
          Content.add_article_to_board(existing, board.id)
        end

        :ok
      else
        title = derive_title(object, body)
        slug = Content.generate_slug(title)
        poll_opts = extract_poll_from_object(object, ap_id)
        image_attachments = AttachmentExtractor.extract_image_attachments(object)

        url = extract_url(object)
        visibility = Visibility.from_addressing(object)

        case Content.create_remote_article(
               %{
                 title: title,
                 body: body,
                 slug: slug,
                 ap_id: ap_id,
                 url: url,
                 remote_actor_id: remote_actor.id,
                 visibility: visibility
               }
               |> Map.merge(content_warning(object)),
               [board.id],
               poll_opts ++ [image_attachments: image_attachments]
             ) do
          {:ok, _multi} ->
            Logger.info("federation.activity: type=Create(#{type}) ap_id=#{ap_id}")
            :ok

          {:error, :article, %Ecto.Changeset{} = changeset, _} ->
            if has_unique_error?(changeset), do: :ok, else: {:error, :create_article_failed}

          {:error, _step, _reason, _changes} ->
            {:error, :create_article_failed}
        end
      end
    end
  end

  defp maybe_auto_route_to_boards(object, remote_actor, type) do
    case Federation.boards_following_actor(remote_actor.id) do
      [] ->
        maybe_create_timeline_item(object, remote_actor, type)

      boards ->
        with :ok <- validate_attribution_match(object, remote_actor),
             :ok <- Validator.validate_object_origin(object, remote_actor),
             {:ok, ap_id} <- Validator.validate_object_id(object),
             {:ok, body, _body_html} <- sanitize_content(object) do
          existing = Content.get_article_by_ap_id(ap_id)

          if existing do
            # Link to all following boards — only when the verified signer
            # owns the existing article. Otherwise any verified actor could
            # cross-post another author's article to boards following them.
            if existing.remote_actor_id == remote_actor.id do
              Enum.each(boards, fn board ->
                Content.add_article_to_board(existing, board.id)
              end)
            end

            :ok
          else
            title = derive_title(object, body)
            slug = Content.generate_slug(title)
            board_ids = Enum.map(boards, & &1.id)
            poll_opts = extract_poll_from_object(object, ap_id)
            image_attachments = AttachmentExtractor.extract_image_attachments(object)
            url = extract_url(object)
            visibility = Visibility.from_addressing(object)

            case Content.create_remote_article(
                   %{
                     title: title,
                     body: body,
                     slug: slug,
                     ap_id: ap_id,
                     url: url,
                     remote_actor_id: remote_actor.id,
                     visibility: visibility
                   }
                   |> Map.merge(content_warning(object)),
                   board_ids,
                   poll_opts ++ [image_attachments: image_attachments]
                 ) do
              {:ok, _multi} ->
                Logger.info(
                  "federation.activity: type=Create(#{type}) ap_id=#{ap_id} auto_routed=#{length(boards)}"
                )

                :ok

              {:error, :article, %Ecto.Changeset{} = changeset, _} ->
                if has_unique_error?(changeset), do: :ok, else: {:error, :create_article_failed}

              {:error, _step, _reason, _changes} ->
                {:error, :create_article_failed}
            end
          end
        end
    end
  end

  defp resolve_target_board(object) do
    audience_uris =
      List.wrap(object["audience"]) ++
        List.wrap(object["to"]) ++
        List.wrap(object["cc"])

    case Federation.resolve_board_from_audience(audience_uris) do
      %{} = board -> {:ok, board}
      nil -> {:error, :board_not_found}
    end
  end

  # --- Follow helpers ---

  defp resolve_target_uri(%{"object" => object}, target) when is_binary(object) do
    case target do
      {:user, user} ->
        uri = Federation.actor_uri(:user, user.username)
        if uri == object, do: uri, else: nil

      {:board, board} ->
        uri = Federation.actor_uri(:board, board.slug)
        if uri == object, do: uri, else: nil

      :shared ->
        if Validator.local_actor?(object), do: object, else: nil
    end
  end

  defp resolve_target_uri(_, _), do: nil

  # Returns true when the URI is a local board actor for a non-federated board
  # (ap_enabled: false or min_role_to_view != "guest"). Only used on the shared
  # inbox path where the controller cannot pre-filter by board federation.
  defp non_federated_board_actor?(actor_uri, :shared) do
    board_prefix = "#{Federation.base_url()}/ap/boards/"

    case actor_uri do
      <<^board_prefix::binary, slug::binary>> ->
        case Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug) do
          nil -> false
          board -> not Baudrate.Content.Board.federated?(board)
        end

      _ ->
        false
    end
  end

  defp non_federated_board_actor?(_, _), do: false

  # --- Validation helpers ---

  defp validate_actor_match(%{"actor" => actor_uri}, %{ap_id: signer_ap_id})
       when is_binary(actor_uri) do
    if actor_uri == signer_ap_id do
      :ok
    else
      {:error, :actor_mismatch}
    end
  end

  defp validate_actor_match(_, _), do: {:error, :actor_mismatch}

  defp validate_domain(remote_actor) do
    if Validator.domain_blocked?(remote_actor.domain) do
      {:error, :domain_blocked}
    else
      :ok
    end
  end

  # A suspended actor is refused the same way its whole domain would be, so a
  # report about one account has an answer that does not take out every other
  # account on its instance (ADR 0030, decision 6).
  defp validate_not_suspended(remote_actor) do
    if Baudrate.Federation.RemoteActors.suspended?(remote_actor) do
      {:error, :actor_suspended}
    else
      :ok
    end
  end

  defp validate_not_local(%{"actor" => actor}) do
    if Validator.local_actor?(actor) do
      {:error, :self_referencing}
    else
      :ok
    end
  end

  defp has_unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  # Creates an article_boost or comment_boost if the Announce target is local content.
  # Only accepts boosts on articles in public, AP-enabled boards.
  defp maybe_create_local_boost(object_uri, ap_id, remote_actor) do
    case resolve_local_article_by_ap_or_uri(object_uri) do
      %{id: article_id} = article ->
        if article_federated?(article) and not blocked_by_author?(article, remote_actor) do
          Content.create_remote_article_boost(%{
            ap_id: ap_id,
            article_id: article_id,
            remote_actor_id: remote_actor.id
          })
        else
          :ok
        end

      nil ->
        case Content.get_comment_by_ap_id(object_uri) do
          %{article_id: article_id} = comment ->
            article = Baudrate.Repo.get(Baudrate.Content.Article, article_id)

            if article && article_federated?(article) &&
                 not blocked_by_author?(comment, remote_actor) do
              Content.create_remote_comment_boost(%{
                ap_id: ap_id,
                comment_id: comment.id,
                remote_actor_id: remote_actor.id
              })
            else
              :ok
            end

          nil ->
            :ok
        end
    end
  end

  # Returns true if the article can participate in federation.
  # Remote articles (received via federation) always qualify regardless of which
  # boards they reside in — they already exist on the fediverse and remote actors
  # should be able to Like, Boost, or Reply to them even if the board has
  # ap_enabled: false.
  # Local articles qualify if either:
  #   (a) they are in at least one public, AP-enabled board, or
  #   (b) their author has remote followers — user-actor federation may have
  #       already published the article via follower fan-out, so inbound
  #       interactions on it must be honored regardless of board AP status.
  defp article_federated?(%{remote_actor_id: remote_actor_id}) when not is_nil(remote_actor_id),
    do: true

  defp article_federated?(article) do
    article_in_federated_board?(article) or author_has_remote_followers?(article)
  end

  defp article_in_federated_board?(article) do
    import Ecto.Query

    Baudrate.Repo.exists?(
      from(ba in Baudrate.Content.BoardArticle,
        join: b in Baudrate.Content.Board,
        on: b.id == ba.board_id,
        where:
          ba.article_id == ^article.id and
            b.min_role_to_view == "guest" and
            b.ap_enabled == true
      )
    )
  end

  defp author_has_remote_followers?(%{user_id: user_id}) when is_integer(user_id) do
    import Ecto.Query

    case Baudrate.Repo.get(Baudrate.Setup.User, user_id) do
      %{username: username} when is_binary(username) ->
        actor_uri = Federation.actor_uri(:user, username)

        Baudrate.Repo.exists?(
          from(f in Baudrate.Federation.Follower, where: f.actor_uri == ^actor_uri)
        )

      _ ->
        false
    end
  end

  defp author_has_remote_followers?(_), do: false

  # --- Follow helpers (Accept/Reject) ---

  defp extract_follow_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp extract_follow_id(_), do: nil

  # When the embedded Follow names its target, it must be the signer: only the
  # followed actor may accept or reject a follow addressed to it.
  defp follow_object_is_signer?(%{"object" => target}, remote_actor) when is_binary(target),
    do: target == remote_actor.ap_id

  defp follow_object_is_signer?(%{"object" => %{"id" => target}}, remote_actor)
       when is_binary(target),
       do: target == remote_actor.ap_id

  defp follow_object_is_signer?(_, _), do: true

  # Try user follow first, then board follow as fallback. Both lookups are
  # scoped to the signing actor: follow ap_ids are minted locally and are not
  # secret, so without the scope any verified actor could flip someone
  # else's pending follow of a third party to accepted/rejected.
  defp accept_follow_with_fallback(follow_id, remote_actor) do
    case Federation.accept_user_follow(follow_id, remote_actor) do
      {:ok, _follow} ->
        Logger.info(
          "federation.activity: type=Accept(Follow) actor=#{remote_actor.ap_id} follow=#{follow_id}"
        )

      {:error, :not_found} ->
        case Federation.accept_board_follow(follow_id, remote_actor) do
          {:ok, _follow} ->
            Logger.info(
              "federation.activity: type=Accept(BoardFollow) actor=#{remote_actor.ap_id} follow=#{follow_id}"
            )

          {:error, :not_found} ->
            Logger.info(
              "federation.activity: type=Accept(Follow) actor=#{remote_actor.ap_id} follow=#{follow_id} (not found)"
            )
        end
    end
  end

  defp reject_follow_with_fallback(follow_id, remote_actor) do
    case Federation.reject_user_follow(follow_id, remote_actor) do
      {:ok, _follow} ->
        Logger.info(
          "federation.activity: type=Reject(Follow) actor=#{remote_actor.ap_id} follow=#{follow_id}"
        )

      {:error, :not_found} ->
        case Federation.reject_board_follow(follow_id, remote_actor) do
          {:ok, _follow} ->
            Logger.info(
              "federation.activity: type=Reject(BoardFollow) actor=#{remote_actor.ap_id} follow=#{follow_id}"
            )

          {:error, :not_found} ->
            Logger.info(
              "federation.activity: type=Reject(Follow) actor=#{remote_actor.ap_id} follow=#{follow_id} (not found)"
            )
        end
    end
  end

  # --- Block helpers ---

  # A local user's block of a remote actor refuses that actor's follows,
  # likes, boosts and replies on the user's content (see `Auth.Moderation`).
  defp blocked_by_author?(%{user_id: user_id}, remote_actor) when is_integer(user_id),
    do: Baudrate.Auth.remote_actor_blocked_by?(remote_actor.id, user_id)

  defp blocked_by_author?(_content, _remote_actor), do: false

  defp reply_blocked?(article, parent_id, remote_actor) do
    parent = if is_integer(parent_id), do: Content.get_comment(parent_id)
    blocked_by_author?(article, remote_actor) or blocked_by_author?(parent, remote_actor)
  end

  defp follow_blocked_by_target?(actor_uri, remote_actor) do
    case local_user_from_actor_uri(actor_uri) do
      %{id: user_id} -> Baudrate.Auth.remote_actor_blocked_by?(remote_actor.id, user_id)
      nil -> false
    end
  end

  # The local user a `/ap/users/:username` actor URI names, or nil. The Follow
  # names its target in the activity, so this works whichever inbox the
  # activity arrived at — which is the point: see `notify_follow_target/2`.
  defp local_user_from_actor_uri(actor_uri) do
    user_prefix = "#{Federation.base_url()}/ap/users/"

    with <<^user_prefix::binary, username::binary>> <- actor_uri,
         %{} = user <- Baudrate.Auth.get_user_by_username(username) do
      user
    else
      _ -> nil
    end
  end

  # --- Notification helpers ---

  # Resolved from the Follow's own target URI, not from which inbox it arrived
  # at. This used to match only `{:user, user}`, the per-user inbox path — but
  # an instance that advertises a `sharedInbox` gets its follows delivered
  # there, which is what Mastodon does, so the person being followed was
  # usually never told. The block check above has always resolved the target
  # this way; only the notification did not (3F).
  defp notify_follow_target(actor_uri, remote_actor) do
    case local_user_from_actor_uri(actor_uri) do
      %{id: user_id} -> Baudrate.Notification.Hooks.notify_remote_follow(user_id, remote_actor.id)
      nil -> :ok
    end
  end

  # --- Flag helpers ---

  defp build_flag_report_attrs(object_uris, remote_actor, reason) do
    # Filter out the actor's own URI (Flag objects include both actor and content)
    content_uris = Enum.reject(object_uris, &(&1 == remote_actor.ap_id))

    article_id = find_flagged_article(content_uris)
    comment_id = if article_id == nil, do: find_flagged_comment(content_uris)

    %{
      reason: reason,
      reporter_remote_actor_id: remote_actor.id,
      article_id: article_id,
      comment_id: comment_id,
      reported_user_id: find_flagged_user(content_uris)
    }
  end

  defp flag_has_local_target?(attrs) do
    Enum.any?([attrs.article_id, attrs.comment_id, attrs.reported_user_id])
  end

  # Mastodon sends the reporter's comment as plain text, and may send none.
  defp flag_reason(content) when is_binary(content) do
    content |> Baudrate.Sanitizer.Native.strip_tags() |> String.trim() |> String.slice(0, 2000)
  end

  defp flag_reason(_content), do: ""

  # A reported local account appears as its actor URI.
  defp find_flagged_user(uris) do
    user_prefix = "#{Federation.base_url()}/ap/users/"

    Enum.find_value(uris, fn uri ->
      with true <- String.starts_with?(uri, user_prefix),
           username = String.replace_prefix(uri, user_prefix, ""),
           true <- username =~ ~r/\A[A-Za-z0-9_]+\z/,
           %{id: id} <- Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
        id
      else
        _ -> nil
      end
    end)
  end

  defp find_flagged_article(uris) do
    article_prefix = "#{Federation.base_url()}/ap/articles/"

    Enum.find_value(uris, fn uri ->
      cond do
        String.starts_with?(uri, article_prefix) ->
          slug = String.replace_prefix(uri, article_prefix, "")

          case Baudrate.Repo.get_by(Content.Article, slug: slug) do
            %{id: id} -> id
            nil -> nil
          end

        true ->
          case Content.get_article_by_ap_id(uri) do
            %{id: id} -> id
            nil -> nil
          end
      end
    end)
  end

  defp find_flagged_comment(uris) do
    Enum.find_value(uris, fn uri ->
      case Content.get_comment_by_ap_id(uri) do
        %{id: id} -> id
        nil -> nil
      end
    end)
  end

  # --- Poll helpers ---

  # Detects if a Create(Note) is a Mastodon-style poll vote.
  # A vote Note has `name` (the option text) and `inReplyTo` naming the object
  # being voted on.
  defp maybe_handle_poll_vote(%{"name" => name, "inReplyTo" => in_reply_to}, remote_actor)
       when is_binary(name) and is_binary(in_reply_to) do
    case resolve_poll_vote_target(in_reply_to) do
      %{} = article -> handle_poll_vote_for_article(article, name, remote_actor)
      nil -> :not_a_vote
    end
  end

  defp maybe_handle_poll_vote(_object, _remote_actor), do: :not_a_vote

  # A vote may address either URI, and both have to work.
  #
  # The **article** is what `Publisher.build_create_vote/3` has always sent and
  # what the `Question` embedded in the Article object is reached through, so
  # every peer that learned one of our polls before Phase 3B knows only that.
  # The **poll** is what a peer votes against once it has fetched the
  # standalone `Question` at `/ap/polls/:id` (ADR 0050) — which is the whole
  # point of giving it an id. Accepting only the article would make the new
  # object unvotable; accepting only the poll would silently drop every vote
  # already in flight.
  defp resolve_poll_vote_target(uri) do
    case resolve_local_article_by_ap_or_uri(uri) do
      %{} = article ->
        article

      nil ->
        with %{article_id: article_id} <- Content.get_poll_by_ap_id(uri) do
          Baudrate.Repo.get(Baudrate.Content.Article, article_id)
        else
          _ -> nil
        end
    end
  end

  # Returns `:not_a_vote` only when the Note genuinely is not a poll vote (no
  # poll on the target, or no option matching `name`), so such Notes can still
  # be handled as comments or DMs. A Note that *is* a vote but must be refused
  # returns `:ok` — dropping it silently rather than letting it fall through to
  # the DM/comment path.
  defp handle_poll_vote_for_article(article, name, remote_actor) do
    case Content.get_poll_for_article(article.id) do
      nil ->
        :not_a_vote

      poll ->
        option = Enum.find(poll.options, &(&1.text == name))

        cond do
          is_nil(option) ->
            :not_a_vote

          # Same federation gate as Like / Announce / reply: a poll on an
          # article that does not participate in federation must not accept
          # remote votes.
          not article_federated?(article) ->
            Logger.info(
              "federation.activity: type=Create(Note/PollVote) rejected non_federated_article"
            )

            :ok

          # A closed poll's result must not be mutable after the fact. The local
          # vote path already refuses (`Content.cast_vote/3`); the federated
          # path must match, otherwise any remote actor can move the numbers on
          # a finished poll.
          Baudrate.Content.Poll.closed?(poll) ->
            Logger.info("federation.activity: type=Create(Note/PollVote) rejected poll_closed")

            :ok

          true ->
            case Content.create_remote_poll_vote(%{
                   poll_id: poll.id,
                   poll_option_id: option.id,
                   remote_actor_id: remote_actor.id
                 }) do
              {:ok, _vote} ->
                # Recalc counts
                Content.recalc_poll_counts(poll.id)

                Logger.info(
                  "federation.activity: type=Create(Note/PollVote) actor=#{remote_actor.ap_id}"
                )

                :ok

              {:error, %Ecto.Changeset{} = changeset} ->
                if has_unique_error?(changeset), do: :ok, else: :not_a_vote
            end
        end
    end
  end

  # Extracts the human-readable URL from an AP object.
  # The `url` field can be a string or a list of link objects; we pick the
  # first `text/html` link or the first string entry. Whatever is picked is
  # only kept when it is an `https://` URL: the value is rendered verbatim as
  # an `href` ("View original"), and HEEx does not scheme-check attributes, so
  # a `javascript:`/`data:` value would be a stored link-injection held back
  # only by CSP. Mirrors `ActorResolver.extract_url/1`.
  defp extract_url(object) do
    case raw_extract_url(object) do
      url when is_binary(url) -> if Validator.valid_https_url?(url), do: url, else: nil
      _ -> nil
    end
  end

  defp raw_extract_url(%{"url" => url}) when is_binary(url), do: url

  defp raw_extract_url(%{"url" => [first | _] = urls}) when is_list(urls) do
    html_link =
      Enum.find(urls, fn
        %{"mediaType" => mt, "href" => _} -> mt == "text/html"
        _ -> false
      end)

    case html_link do
      %{"href" => href} -> href
      nil when is_binary(first) -> first
      nil -> Map.get(List.first(urls) || %{}, "href")
    end
  end

  defp raw_extract_url(_), do: nil

  defp extract_image_attachments(object),
    do: AttachmentExtractor.extract_image_attachments(object)

  # Images and playable media in one list, told apart by `media_type`. The
  # renderer branches: an image is proxied, a video is a link.
  defp extract_attachments(object) do
    AttachmentExtractor.extract_image_attachments(object) ++
      AttachmentExtractor.extract_media_attachments(object)
  end

  # Appends image attachment tags to body_html for AP objects with image attachments.
  # This ensures remote comment images (sent as AP attachments, not inline HTML) are displayed.
  defp append_attachment_images(body_html, object) do
    case extract_image_attachments(object) do
      [] ->
        body_html

      attachments ->
        urls =
          attachments
          |> Enum.filter(fn att -> https_url?(att["url"]) end)
          |> Enum.map(& &1["url"])

        # Cache them now so the first viewer does not pay the fetch latency.
        Baudrate.Media.Warmer.warm_urls(urls)

        img_tags =
          attachments
          |> Enum.filter(fn att -> https_url?(att["url"]) end)
          |> Enum.map_join("", fn att ->
            # Emit the proxied path, never the remote URL: rendering an
            # attachment must not disclose the viewer's IP to the origin host.
            url = Baudrate.Media.Proxy.url(att["url"])

            # Strips tags *and* bounds the length, which a bare `strip_tags`
            # did not: a peer's attachment `name` is a remote-controlled string
            # reaching a column, and `body_html` has no length validation of
            # its own. An absent description stays absent here and is filled in
            # at render by `BaudrateWeb.ImageAltFallback`, because the fallback
            # is translated and a string chosen now would freeze this process's
            # locale into the stored row (ADR 0061).
            alt = Baudrate.Content.ImageAlt.from_remote(att["name"]) || ""

            ~s(<p><img src="#{escape_attr(url)}" alt="#{escape_attr(alt)}" loading="lazy" /></p>)
          end)

        if img_tags == "", do: body_html, else: (body_html || "") <> img_tags
    end
  end

  # Video and audio become a **link** to the original, never an embed and
  # never a proxied subresource (ADR 0052). Proxying would mean this instance
  # downloading and re-serving arbitrarily large files; embedding would be the
  # hotlink `Media.Proxy` exists to prevent. A link contacts nobody until the
  # reader follows it — the same bargain as the click-to-load video player
  # (ADR 0045). They used to be dropped, so a post whose point was a video
  # looked empty.
  defp append_attachment_media(body_html, object) do
    links =
      object
      |> AttachmentExtractor.extract_media_attachments()
      |> Enum.filter(&https_url?(&1["url"]))
      |> Enum.map_join("", fn att ->
        label = Baudrate.Sanitizer.Native.strip_tags(att["name"] || "") |> String.trim()
        label = if label == "", do: media_label(att["media_type"]), else: label

        ~s(<p><a href="#{escape_attr(att["url"])}" rel="nofollow noopener noreferrer" ) <>
          ~s(target="_blank" class="attachment-media-link">#{escape_attr(label)}</a></p>)
      end)

    if links == "", do: body_html, else: (body_html || "") <> links
  end

  # Not translated: this text is baked into stored HTML at ingest time, so it
  # cannot follow the reader's locale the way a template can. A generic noun
  # is the honest fallback when the peer sent no name.
  defp media_label("video/" <> _), do: "Video attachment"
  defp media_label("audio/" <> _), do: "Audio attachment"
  defp media_label(_), do: "Media attachment"

  defp https_url?(url) when is_binary(url), do: String.starts_with?(url, "https://")
  defp https_url?(_), do: false

  defp escape_attr(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attr(_), do: ""

  # Extracts poll data from a Question object or an Article with a Question attachment.
  defp extract_poll_from_object(object, ap_id) do
    poll_data = find_poll_in_object(object)

    if poll_data do
      {mode, options} = extract_poll_options(poll_data)
      closes_at = parse_end_time(poll_data["endTime"])
      voters_count = poll_data["votersCount"] || 0

      option_attrs =
        options
        |> Enum.with_index()
        |> Enum.map(fn {opt, idx} ->
          %{
            text: opt["name"] || "Option #{idx + 1}",
            position: idx,
            votes_count: get_in(opt, ["replies", "totalItems"]) || 0
          }
        end)

      [
        poll: %{
          mode: mode,
          closes_at: closes_at,
          voters_count: voters_count,
          ap_id: ap_id,
          options: option_attrs
        }
      ]
    else
      []
    end
  end

  defp find_poll_in_object(%{"type" => "Question"} = object), do: object

  defp find_poll_in_object(%{"attachment" => attachments}) when is_list(attachments) do
    Enum.find(attachments, &(is_map(&1) && &1["type"] == "Question"))
  end

  defp find_poll_in_object(_), do: nil

  defp extract_poll_options(poll_data) do
    cond do
      is_list(poll_data["oneOf"]) -> {"single", poll_data["oneOf"]}
      is_list(poll_data["anyOf"]) -> {"multiple", poll_data["anyOf"]}
      true -> {"single", []}
    end
  end

  defp parse_end_time(nil), do: nil

  defp parse_end_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_end_time(_), do: nil

  # Handle Update(Question) — refresh poll counts
  defp handle_update_question(object, remote_actor) do
    # Find the poll by ap_id, current or previous (ADR 0050).
    case Content.get_poll_by_ap_id(object["id"] || "") do
      nil ->
        # Maybe it's an embedded question — try to find via the article's ap_id
        :ok

      poll ->
        poll = Baudrate.Repo.preload(poll, [:article])

        if poll.article && poll.article.remote_actor_id == remote_actor.id do
          {_mode, options} = extract_poll_options(object)
          voters_count = object["votersCount"] || 0

          option_counts =
            Enum.map(options, fn opt ->
              %{
                text: opt["name"],
                votes_count: get_in(opt, ["replies", "totalItems"]) || 0
              }
            end)

          Content.update_remote_poll_counts(poll, %{
            voters_count: voters_count,
            option_counts: option_counts
          })

          Logger.info("federation.activity: type=Update(Question) ap_id=#{object["id"]}")
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end
end
