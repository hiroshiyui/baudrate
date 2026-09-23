defmodule BaudrateWeb.ActivityPubController do
  @moduledoc """
  Controller for ActivityPub and discovery endpoints.

  These endpoints also serve as the **public API** — external clients can
  request any GET endpoint with `Accept: application/json` (in addition to
  `application/activity+json` or `application/ld+json`) to receive JSON-LD
  responses. All GET endpoints include CORS headers (`Access-Control-Allow-Origin: *`)
  and content-negotiated endpoints include `Vary: Accept`.

  Machine-only endpoints (WebFinger, NodeInfo, outbox, boards index, search)
  always return JSON regardless of Accept header.

  Private boards are hidden from all AP endpoints — board actor, outbox,
  inbox, and WebFinger all return 404 for private boards. Articles
  exclusively in private boards also return 404.

  ## Endpoints

  ### Discovery
    * `GET /.well-known/webfinger` — WebFinger resource resolution
    * `GET /.well-known/nodeinfo` — NodeInfo discovery links
    * `GET /nodeinfo/2.0`, `GET /nodeinfo/2.1` — NodeInfo documents

  ### Actors (content-negotiated)
    * `GET /ap/users/:username` — Person actor
    * `GET /ap/boards/:slug` — Group actor (public only)
    * `GET /ap/site` — Organization actor

  ### Collections (paginated with `?page=N`, 20 items/page)
    * `GET /ap/users/:username/outbox` — user outbox (Create activities)
    * `GET /ap/users/:username/followers` — user followers
    * `GET /ap/users/:username/following` — remote actors the user follows
    * `GET /ap/boards/:slug/outbox` — board outbox (Announce activities, public only)
    * `GET /ap/boards/:slug/followers` — board followers (public only)
    * `GET /ap/boards/:slug/following` — remote actors the board follows, which is how remote content reaches it
    * `GET /ap/boards` — index of public AP-enabled boards
    * `GET /ap/articles/:slug/replies` — article comments as Note objects
    * `GET /ap/search?q=...` — full-text search over articles in federated boards

  ### Objects (content-negotiated)
    * `GET /ap/articles/:slug` — Article object (requires public board)
    * `GET /ap/comments/:id` — Note object for a local comment (ADR 0050)
    * `GET /ap/polls/:id` — Question object for a local poll (ADR 0050)

  ### Inboxes (HTTP Signature verified)
    * `POST /ap/inbox` — shared inbox
    * `POST /ap/users/:username/inbox` — user inbox
    * `POST /ap/boards/:slug/inbox` — board inbox (public only)
  """

  use BaudrateWeb, :controller
  require Logger

  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.KeyStore

  plug :require_federation
       when action not in [:webfinger, :nodeinfo_redirect, :nodeinfo, :options_preflight]

  @activity_json "application/activity+json"
  @jrd_json "application/jrd+json"

  @username_re ~r/\A[a-zA-Z0-9_]+\z/
  @slug_re ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  # --- OPTIONS Preflight ---

  @doc "CORS preflight fallback (normally handled by the CORS plug before reaching this action)."
  def options_preflight(conn, _params), do: send_resp(conn, 204, "")

  # --- WebFinger ---

  @doc "Resolves a WebFinger resource query to a JRD response."
  def webfinger(conn, %{"resource" => resource}) do
    case Federation.webfinger(resource) do
      {:ok, jrd} ->
        conn
        |> put_resp_content_type(@jrd_json)
        |> json(jrd)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :gone} ->
        gone(conn)

      {:error, :invalid_resource} ->
        conn |> put_status(400) |> json(%{error: "Invalid resource"})
    end
  end

  def webfinger(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing resource parameter"})
  end

  # --- NodeInfo ---

  @doc "Returns the NodeInfo discovery document with links to supported NodeInfo versions."
  def nodeinfo_redirect(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Federation.nodeinfo_links())
  end

  @doc """
  Returns the NodeInfo document with software and usage statistics.

  The schema version comes from the path, because the two documents differ:
  `software.repository` exists only in 2.1, and a 2.0 document carrying it
  fails validation.
  """
  def nodeinfo(conn, _params) do
    version = if String.ends_with?(conn.request_path, "2.0"), do: "2.0", else: "2.1"

    conn
    |> put_resp_content_type("application/json")
    |> json(Federation.nodeinfo(version))
  end

  # --- Actors ---

  @doc "Returns the ActivityPub Person actor for a user, or redirects to home for HTML requests."
  def user_actor(conn, %{"username" => username}) do
    conn = conn |> put_resp_header("vary", "Accept") |> no_store()

    if wants_json?(conn) do
      with true <- Regex.match?(@username_re, username),
           user when not is_nil(user) <-
             Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
        serve_user_actor(conn, user)
      else
        _ -> not_found(conn)
      end
    else
      redirect(conn, to: ~p"/")
    end
  end

  # A deleted account answers 410 with its Tombstone (ADR 0072), and never
  # reaches `ensure_user_keypair/1`: a new key would only be one every server
  # holding the old one rejects.
  defp serve_user_actor(conn, %{status: "deleted"} = user) do
    conn
    |> put_status(410)
    |> put_resp_content_type(@activity_json)
    |> json(Federation.user_tombstone(user))
  end

  defp serve_user_actor(conn, user) do
    case KeyStore.ensure_user_keypair(user) do
      {:ok, user} ->
        conn
        |> cacheable()
        |> put_resp_content_type(@activity_json)
        |> json(Federation.user_actor(user))

      _ ->
        not_found(conn)
    end
  end

  # The collections of a deleted account are gone with it.
  defp gone(conn), do: conn |> put_status(410) |> json(%{error: "Gone"})

  @doc "Returns the ActivityPub Group actor for a public AP-enabled board."
  def board_actor(conn, %{"slug" => slug}) do
    conn = conn |> put_resp_header("vary", "Accept") |> no_store()

    if wants_json?(conn) do
      with true <- Regex.match?(@slug_re, slug),
           board when not is_nil(board) <-
             Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
           true <- Board.federated?(board),
           {:ok, board} <- KeyStore.ensure_board_keypair(board) do
        conn
        |> cacheable()
        |> put_resp_content_type(@activity_json)
        |> json(Federation.board_actor(board))
      else
        _ -> not_found(conn)
      end
    else
      redirect(conn, to: ~p"/boards/#{slug}")
    end
  end

  @doc "Returns the ActivityPub Organization actor representing the site."
  def site_actor(conn, _params) do
    conn = conn |> put_resp_header("vary", "Accept") |> no_store()

    if wants_json?(conn) do
      conn
      |> cacheable()
      |> put_resp_content_type(@activity_json)
      |> json(Federation.site_actor())
    else
      redirect(conn, to: ~p"/")
    end
  end

  # --- Outbox ---

  @doc "Returns the paginated outbox collection (Create activities) for a user."
  def user_outbox(conn, %{"username" => username} = params) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <-
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username),
         :ok <- not_deleted(user) do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.user_outbox(user, params))
    else
      :deleted -> gone(conn)
      _ -> not_found(conn)
    end
  end

  @doc "Returns the paginated outbox collection (Announce activities) for a public board."
  def board_outbox(conn, %{"slug" => slug} = params) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- Board.federated?(board) do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.board_outbox(board, params))
    else
      _ -> not_found(conn)
    end
  end

  @doc """
  Returns the site actor's outbox. Always empty — the instance actor never
  posts — but served, because the actor document advertises it.
  """
  def site_outbox(conn, params) do
    conn
    |> put_resp_content_type(@activity_json)
    |> json(Federation.site_outbox(params))
  end

  # --- Followers Collection ---

  @doc "Returns the paginated followers collection for the site actor."
  def site_followers(conn, params) do
    conn
    |> put_resp_content_type(@activity_json)
    |> json(Federation.followers_collection(Federation.actor_uri(:site, nil), params))
  end

  @doc "Returns the paginated followers collection for a user."
  def user_followers(conn, %{"username" => username} = params) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <-
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username),
         :ok <- not_deleted(user) do
      actor_uri = Federation.actor_uri(:user, user.username)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.followers_collection(actor_uri, params))
    else
      :deleted -> gone(conn)
      _ -> not_found(conn)
    end
  end

  @doc "Returns the paginated followers collection for a public board."
  def board_followers(conn, %{"slug" => slug} = params) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- Board.federated?(board) do
      actor_uri = Federation.actor_uri(:board, board.slug)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.followers_collection(actor_uri, params))
    else
      _ -> not_found(conn)
    end
  end

  # --- Following Collection ---

  @doc "Returns the paginated following collection for a user."
  def user_following(conn, %{"username" => username} = params) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <-
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username),
         :ok <- not_deleted(user) do
      actor_uri = Federation.actor_uri(:user, user.username)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.following_collection(actor_uri, params))
    else
      :deleted -> gone(conn)
      _ -> not_found(conn)
    end
  end

  @doc """
  Returns the paginated following collection for a public board.

  Not empty: a board follows remote actors, and that is how remote content
  reaches it. `params` must be threaded through like every other collection
  action — without it `?page` was discarded, so the root's `first` link
  (`?page=1`) answered with the root again and a peer could never walk past it.
  """
  def board_following(conn, %{"slug" => slug} = params) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- Board.federated?(board) do
      actor_uri = Federation.actor_uri(:board, board.slug)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.following_collection(actor_uri, params))
    else
      _ -> not_found(conn)
    end
  end

  # --- Article ---

  @doc "Returns the Article object as JSON-LD, or redirects to the HTML view for browser requests."
  def article(conn, %{"slug" => slug}) do
    conn = put_resp_header(conn, "vary", "Accept")

    if wants_json?(conn) do
      with true <- Regex.match?(@slug_re, slug) do
        try do
          article = Baudrate.Content.get_article_by_slug!(slug)

          if publicly_servable?(article) do
            conn
            |> put_resp_content_type(@activity_json)
            |> json(Federation.article_object(article))
          else
            not_found(conn)
          end
        rescue
          Ecto.NoResultsError ->
            not_found(conn)
        end
      else
        _ -> not_found(conn)
      end
    else
      redirect(conn, to: ~p"/articles/#{slug}")
    end
  end

  # --- Comment and Poll Objects ---

  @doc """
  Returns the `Note` object for a local comment.

  The gate is the **owning article's**, not the comment's: a comment inherits
  the reach of the thread it is in, and `publicly_servable?/1` is the same
  predicate `/ap/articles/:slug` applies. On top of that, three refusals that
  belong to the comment itself:

    * a **remote** comment is never served here. Its `ap_id` lives on another
      host, and re-serving it under one of our URIs is the identity claim
      ADR 0046 exists to refuse — a peer could then cite our URI as the origin
      of somebody else's Note.
    * a **soft-deleted** comment is gone, and `Repo.get/2` does not filter
      `deleted_at`.
    * a comment whose `visibility` is not public or unlisted is not published,
      matching the article rule.
  """
  def comment(conn, %{"id" => id}) do
    conn = put_resp_header(conn, "vary", "Accept")

    with {comment_id, ""} <- Integer.parse(id),
         %{} = comment <- Baudrate.Content.get_comment(comment_id),
         %{} = article <- Baudrate.Content.get_article(comment.article_id),
         true <- comment_servable?(comment, article) do
      if wants_json?(conn) do
        conn
        |> put_resp_content_type(@activity_json)
        |> json(Federation.comment_object(comment))
      else
        # The comment is paged, so the redirect names its page as well as
        # its anchor. Counted for a guest: this endpoint is unauthenticated.
        redirect(conn, to: BaudrateWeb.Helpers.comment_link(article, comment, nil))
      end
    else
      _ -> not_found(conn)
    end
  end

  @doc """
  Returns the standalone `Question` object for a local poll.

  Same gate as its article, for the same reason: a poll is part of the article
  it hangs off, so it reaches exactly as far.
  """
  def poll(conn, %{"id" => id}) do
    conn = put_resp_header(conn, "vary", "Accept")

    with {poll_id, ""} <- Integer.parse(id),
         %{} = poll <- Baudrate.Repo.get(Baudrate.Content.Poll, poll_id),
         %{} = article <- Baudrate.Content.get_article(poll.article_id),
         true <- is_nil(article.remote_actor_id),
         true <- publicly_servable?(Baudrate.Repo.preload(article, :boards)) do
      if wants_json?(conn) do
        conn
        |> put_resp_content_type(@activity_json)
        |> json(Federation.poll_object(poll))
      else
        redirect(conn, to: ~p"/articles/#{article.slug}")
      end
    else
      _ -> not_found(conn)
    end
  end

  # --- Boards Index ---

  @doc "Returns a collection of all public AP-enabled boards."
  def boards_index(conn, _params) do
    conn
    |> put_resp_content_type(@activity_json)
    |> json(Federation.boards_collection())
  end

  # --- Article Replies ---

  @doc "Returns the replies collection (comments as Note objects) for a public article."
  def article_replies(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug) do
      try do
        article = Baudrate.Content.get_article_by_slug!(slug)

        if publicly_servable?(article) do
          conn
          |> put_resp_content_type(@activity_json)
          |> json(Federation.article_replies(article))
        else
          not_found(conn)
        end
      rescue
        Ecto.NoResultsError ->
          not_found(conn)
      end
    else
      _ -> not_found(conn)
    end
  end

  # --- Search ---

  @doc "Returns full-text search results as an OrderedCollection."
  def search(conn, %{"q" => q} = params) when byte_size(q) > 0 do
    conn
    |> put_resp_content_type(@activity_json)
    |> json(Federation.search_collection(q, params))
  end

  def search(conn, _params) do
    conn |> put_status(400) |> json(%{error: "Missing q parameter"})
  end

  # --- Inbox ---

  @doc "Receives activities at the shared inbox (HTTP Signature verified by plug)."
  def shared_inbox(conn, _params) do
    handle_inbox(conn, :shared)
  end

  @doc "Receives activities at a user's inbox."
  def user_inbox(conn, %{"username" => username}) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <-
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username),
         :ok <- not_deleted(user) do
      handle_inbox(conn, {:user, user})
    else
      # Accepted and dropped, so the sender stops retrying (ADR 0072).
      :deleted -> send_resp(conn, 202, "")
      _ -> not_found(conn)
    end
  end

  @doc "Receives activities at a board's inbox (public AP-enabled boards only)."
  def board_inbox(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- Board.federated?(board) do
      handle_inbox(conn, {:board, board})
    else
      _ -> not_found(conn)
    end
  end

  # The activity is admitted and stored here, and processed afterwards by
  # `Federation.InboundWorker` (Phase 2C, ADR 0034), so the sender's request
  # never waits for reply-chain walks or object fetches. What the handler makes
  # of the activity is logged rather than returned: senders do not act on it.
  defp handle_inbox(conn, target) do
    raw_body = conn.assigns[:raw_body] || ""
    remote_actor = conn.assigns[:remote_actor]

    case Jason.decode(raw_body) do
      {:ok, activity} ->
        case Baudrate.Federation.Inbound.accept(activity, raw_body, remote_actor, target) do
          :ok ->
            conn |> put_status(202) |> json(%{status: "accepted"})

          {:error, reason} ->
            Logger.warning("federation.inbox_error: reason=#{inspect(reason)}")
            conn |> put_status(422) |> json(%{error: "Unprocessable"})
        end

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Invalid JSON"})
    end
  end

  # --- Helpers ---

  # An article may be served as a public AP object when it sits in a public
  # board (or none), and — for remote articles — was not ingested as
  # followers-only/direct. `ObjectBuilder` stamps `to: as:Public`, so leaking a
  # followers-only Note here would re-publish it to the whole fediverse.
  defp publicly_servable?(article) do
    # `federated?/1`, not `public?/1`: the documented gate is
    # `min_role_to_view == "guest"` *and* `ap_enabled`. With `public?/1` an
    # article in a guest-readable board whose federation the admin had turned
    # off was still served as an AP object and listed in the user outbox — and
    # since no publisher ever announces such an article, the only way to reach
    # it was to guess the slug. Nothing is hidden from the web by this; it is
    # the `ap_enabled` switch meaning what it says.
    board_ok = article.boards == [] or Enum.any?(article.boards, &Board.federated?/1)

    visibility_ok =
      is_nil(article.remote_actor_id) or article.visibility in ["public", "unlisted"]

    # We do not re-publish an instance we have blocked (ADR 0030). Serving its
    # content back out over AP would keep it circulating under our name.
    not_hidden = not Baudrate.Federation.DomainBlocks.actor_hidden?(article.remote_actor_id)

    board_ok and visibility_ok and not_hidden
  end

  defp comment_servable?(comment, article) do
    is_nil(comment.remote_actor_id) and is_nil(comment.deleted_at) and
      comment.visibility in ["public", "unlisted"] and
      publicly_servable?(Baudrate.Repo.preload(article, :boards))
  end

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "Not Found"})

  defp not_deleted(%{status: "deleted"}), do: :deleted
  defp not_deleted(_user), do: :ok

  defp require_federation(conn, _opts) do
    if Baudrate.Setup.federation_enabled?() do
      conn
    else
      conn |> send_resp(404, "") |> halt()
    end
  end

  defp wants_json?(conn) do
    accept = get_req_header(conn, "accept") |> List.first("")

    String.contains?(accept, "application/activity+json") or
      String.contains?(accept, "application/ld+json") or
      String.contains?(accept, "application/json")
  end

  # `no-store` is the default for every actor response, and stays that way for
  # the ones that are not a document: a cached 404 or HTML redirect breaks
  # remote signature verification, because the verifier fetches the actor by
  # the request's `keyId` and gets the cached wrong answer.
  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  # A *successful* actor document may be cached briefly. It is the same bytes
  # for every requester and is fetched on every signature verification, so a
  # short window takes real load off both sides.
  #
  # Three minutes, matching what Mastodon serves, because the window is also
  # how long a rotated public key can keep failing verification at a cache
  # that has not expired it. Rotation publishes an `Update` as well, so this
  # only bounds the caches nobody told.
  #
  # **`public` only when authorized fetch is off.** With it on, the same URL
  # answers 401 to an unsigned request and the document to a signed one — a
  # shared cache holding that document would hand it to unsigned requesters
  # and defeat the setting entirely. `Vary: Accept` is already set, which is
  # what keeps a cache from confusing the JSON and HTML forms.
  defp cacheable(conn) do
    if Baudrate.Setup.get_setting("ap_authorized_fetch") == "true" do
      no_store(conn)
    else
      put_resp_header(conn, "cache-control", "public, max-age=180")
    end
  end
end
