defmodule Baudrate.Federation.InboxHandler do
  @moduledoc """
  Dispatches incoming ActivityPub activities to appropriate handlers.

  Supported activity types:
    * `Follow` — auto-accept, create follower record, send Accept(Follow)
    * `Undo(Follow)` — remove follower record
    * `Undo(Like)` — remove article like
    * `Undo(Announce)` — remove announce record
    * `Create(Note)` — store as remote comment (if `inReplyTo` matches local article)
    * `Create(Article)` — store as remote article in target board
    * `Create(Page)` — treat as `Create(Article)` (Lemmy interop)
    * `Like` — create article like for target article
    * `Announce` — record boost/share (bare URI or embedded object map)
    * `Update(Article/Note/Page)` — update remote content with authorship check
    * `Update(Person/Group)` — refresh cached RemoteActor
    * `Delete(actor)` — remove all their follower records
    * `Delete(content)` — soft-delete matching remote content with authorship check

  ## Mastodon/Lemmy Compatibility

    * `attributedTo` may be an array — the first binary URI is used
    * `sensitive` + `summary` are handled as content warnings
    * Lemmy `Page` objects are treated identically to `Article`
    * Lemmy `Announce` with embedded object maps extracts the inner `id`
  """

  require Logger

  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Federation.{ActorResolver, Delivery, Sanitizer, Validator}

  @doc """
  Handles an incoming activity from a verified remote actor.
  Returns `:ok` or `{:error, reason}`.
  """
  def handle(activity, remote_actor, target) do
    with {:ok, activity} <- Validator.validate_activity(activity),
         :ok <- validate_domain(remote_actor),
         :ok <- validate_not_local(activity) do
      dispatch(activity, remote_actor, target)
    end
  end

  # --- Follow ---

  defp dispatch(%{"type" => "Follow"} = activity, remote_actor, target) do
    actor_uri = resolve_target_uri(activity, target)

    if actor_uri do
      case Federation.create_follower(actor_uri, remote_actor, activity["id"]) do
        {:ok, _follower} ->
          send_accept_async(activity, actor_uri, remote_actor)
          :ok

        {:error, %Ecto.Changeset{} = changeset} ->
          if has_unique_error?(changeset) do
            send_accept_async(activity, actor_uri, remote_actor)
            :ok
          else
            {:error, :follow_failed}
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
         _remote_actor,
         _target
       )
       when is_binary(like_ap_id) do
    Content.delete_article_like_by_ap_id(like_ap_id)
    :ok
  end

  # --- Undo(Announce) ---

  defp dispatch(
         %{"type" => "Undo", "object" => %{"type" => "Announce", "id" => announce_ap_id}},
         _remote_actor,
         _target
       )
       when is_binary(announce_ap_id) do
    Federation.delete_announce_by_ap_id(announce_ap_id)
    :ok
  end

  # --- Create(Note) — comment on a local article ---

  defp dispatch(
         %{"type" => "Create", "object" => %{"type" => "Note"} = object},
         remote_actor,
         _target
       ) do
    with :ok <- validate_attribution_match(object, remote_actor),
         {:ok, body, body_html} <- sanitize_content(object),
         {:ok, article, parent_id} <- resolve_reply_target(object) do
      ap_id = object["id"]

      # Idempotency: if comment with this ap_id already exists, return :ok
      if is_binary(ap_id) && Content.get_comment_by_ap_id(ap_id) do
        :ok
      else
        case Content.create_remote_comment(%{
               body: body,
               body_html: body_html,
               ap_id: ap_id,
               article_id: article.id,
               parent_id: parent_id,
               remote_actor_id: remote_actor.id
             }) do
          {:ok, _comment} ->
            Logger.info("federation.activity: type=Create(Note) ap_id=#{ap_id}")
            :ok

          {:error, %Ecto.Changeset{} = changeset} ->
            if has_unique_error?(changeset), do: :ok, else: {:error, :create_comment_failed}
        end
      end
    end
  end

  # --- Create(Article/Page) — remote article posted to a local board ---
  # Lemmy sends `Page` instead of `Article`; both are handled identically.

  defp dispatch(
         %{"type" => "Create", "object" => %{"type" => type} = object},
         remote_actor,
         _target
       )
       when type in ["Article", "Page"] do
    with :ok <- validate_attribution_match(object, remote_actor),
         {:ok, body, _body_html} <- sanitize_content(object),
         {:ok, board} <- resolve_target_board(object) do
      ap_id = object["id"]

      # Idempotency
      if is_binary(ap_id) && Content.get_article_by_ap_id(ap_id) do
        :ok
      else
        title = object["name"] || "Untitled"
        slug = Content.generate_slug(title)

        case Content.create_remote_article(
               %{
                 title: title,
                 body: body,
                 slug: slug,
                 ap_id: ap_id,
                 remote_actor_id: remote_actor.id
               },
               [board.id]
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

  # --- Like ---

  defp dispatch(%{"type" => "Like", "object" => object_uri} = activity, remote_actor, _target)
       when is_binary(object_uri) do
    case resolve_local_article_by_ap_or_uri(object_uri) do
      %{id: article_id} ->
        ap_id = activity["id"]

        case Content.create_remote_article_like(%{
               ap_id: ap_id,
               article_id: article_id,
               remote_actor_id: remote_actor.id
             }) do
          {:ok, _like} ->
            Logger.info("federation.activity: type=Like ap_id=#{ap_id}")
            :ok

          {:error, %Ecto.Changeset{} = changeset} ->
            if has_unique_error?(changeset), do: :ok, else: {:error, :like_failed}
        end

      nil ->
        # Target not local — ignore gracefully
        :ok
    end
  end

  # --- Announce ---

  defp dispatch(%{"type" => "Announce", "object" => object_uri} = activity, remote_actor, _target)
       when is_binary(object_uri) do
    ap_id = activity["id"]

    case Federation.create_announce(%{
           ap_id: ap_id,
           target_ap_id: object_uri,
           activity_id: ap_id,
           remote_actor_id: remote_actor.id
         }) do
      {:ok, _announce} ->
        Logger.info("federation.activity: type=Announce ap_id=#{ap_id}")
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        if has_unique_error?(changeset), do: :ok, else: {:error, :announce_failed}
    end
  end

  # --- Announce with embedded object map (Lemmy interop) ---
  # Lemmy sends the full object as a map instead of a bare URI string.

  defp dispatch(
         %{"type" => "Announce", "object" => %{"id" => object_id}} = activity,
         remote_actor,
         _target
       )
       when is_binary(object_id) do
    ap_id = activity["id"]

    case Federation.create_announce(%{
           ap_id: ap_id,
           target_ap_id: object_id,
           activity_id: ap_id,
           remote_actor_id: remote_actor.id
         }) do
      {:ok, _announce} ->
        Logger.info("federation.activity: type=Announce(embedded) ap_id=#{ap_id}")
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        if has_unique_error?(changeset), do: :ok, else: {:error, :announce_failed}
    end
  end

  # --- Update(Note/Article/Page) — content update ---

  defp dispatch(
         %{"type" => "Update", "object" => %{"type" => type} = object},
         remote_actor,
         _target
       )
       when type in ["Note", "Article", "Page"] do
    with :ok <- validate_attribution_match(object, remote_actor) do
      case type do
        "Note" -> handle_update_note(object, remote_actor)
        t when t in ["Article", "Page"] -> handle_update_article(object, remote_actor)
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

  # --- Catch-all ---

  defp dispatch(%{"type" => type} = _activity, _remote_actor, _target) do
    Logger.info("federation.activity_unhandled: type=#{type}")
    :ok
  end

  # --- Update helpers ---

  defp handle_update_note(object, remote_actor) do
    ap_id = object["id"]

    case Content.get_comment_by_ap_id(ap_id) do
      %{remote_actor_id: actor_id} = comment when actor_id == remote_actor.id ->
        {:ok, body, body_html} = sanitize_content(object)

        case Content.update_remote_comment(comment, %{body: body, body_html: body_html}) do
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

  defp handle_update_article(object, remote_actor) do
    ap_id = object["id"]

    case Content.get_article_by_ap_id(ap_id) do
      %{remote_actor_id: actor_id} = article when actor_id == remote_actor.id ->
        {:ok, body, _body_html} = sanitize_content(object)
        title = object["name"] || article.title

        case Content.update_remote_article(article, %{title: title, body: body}) do
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

  # --- Delete helpers ---

  defp handle_delete_content(object_uri, remote_actor) do
    # Try article first, then comment
    cond do
      article = Content.get_article_by_ap_id(object_uri) ->
        if article.remote_actor_id == remote_actor.id do
          Content.soft_delete_article(article)
          Logger.info("federation.activity: type=Delete(Article) ap_id=#{object_uri}")
          :ok
        else
          {:error, :unauthorized}
        end

      comment = Content.get_comment_by_ap_id(object_uri) ->
        if comment.remote_actor_id == remote_actor.id do
          Content.soft_delete_comment(comment)
          Logger.info("federation.activity: type=Delete(Note) ap_id=#{object_uri}")
          :ok
        else
          {:error, :unauthorized}
        end

      true ->
        # Content not found — might have been deleted already
        :ok
    end
  end

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

    prepend_content_warning(raw, object)
  end

  # When Mastodon marks a post as sensitive with a summary (content warning),
  # prepend it so the warning is visible in the stored content.
  defp prepend_content_warning(body, %{"sensitive" => true, "summary" => summary})
       when is_binary(summary) and summary != "" do
    "[CW: #{summary}]\n\n#{body}"
  end

  defp prepend_content_warning(body, _object), do: body

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>\s*<p[^>]*>/, "\n\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp strip_html(_), do: ""

  # --- Reply/target resolution helpers ---

  defp resolve_reply_target(%{"inReplyTo" => in_reply_to}) when is_binary(in_reply_to) do
    # First check if it's a reply to an existing comment (threading)
    case Content.get_comment_by_ap_id(in_reply_to) do
      %{article_id: article_id, id: parent_id} ->
        article = Baudrate.Repo.get(Baudrate.Content.Article, article_id)
        if article, do: {:ok, article, parent_id}, else: {:error, :article_not_found}

      nil ->
        # Check if it's a direct reply to a local article
        case resolve_local_article_by_ap_or_uri(in_reply_to) do
          %{} = article -> {:ok, article, nil}
          nil -> {:error, :article_not_found}
        end
    end
  end

  defp resolve_reply_target(_), do: {:error, :missing_in_reply_to}

  defp resolve_local_article_by_ap_or_uri(uri) when is_binary(uri) do
    # Try by ap_id first
    case Content.get_article_by_ap_id(uri) do
      %{} = article ->
        article

      nil ->
        # Try matching against /ap/articles/:slug pattern
        base = Federation.base_url()
        prefix = "#{base}/ap/articles/"

        case uri do
          <<^prefix::binary, slug::binary>> ->
            if Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug) do
              Baudrate.Repo.get_by(Baudrate.Content.Article, slug: slug)
            end

          _ ->
            nil
        end
    end
  end

  defp resolve_local_article_by_ap_or_uri(_), do: nil

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

  defp send_accept_async(follow_activity, actor_uri, remote_actor) do
    Task.Supervisor.start_child(
      Baudrate.Federation.TaskSupervisor,
      fn ->
        case Delivery.send_accept(follow_activity, actor_uri, remote_actor) do
          {:ok, _} ->
            Logger.info("federation.accept_sent: to=#{remote_actor.inbox}")

          {:error, reason} ->
            Logger.warning(
              "federation.accept_failed: to=#{remote_actor.inbox} reason=#{inspect(reason)}"
            )
        end
      end
    )
  end

  # --- Validation helpers ---

  defp validate_domain(remote_actor) do
    if Validator.domain_blocked?(remote_actor.domain) do
      {:error, :domain_blocked}
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
end
