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
    * `GET /nodeinfo/2.1` — NodeInfo 2.1 document

  ### Actors (content-negotiated)
    * `GET /ap/users/:username` — Person actor
    * `GET /ap/boards/:slug` — Group actor (public only)
    * `GET /ap/site` — Organization actor

  ### Collections (paginated with `?page=N`, 20 items/page)
    * `GET /ap/users/:username/outbox` — user outbox (Create activities)
    * `GET /ap/users/:username/followers` — user followers
    * `GET /ap/users/:username/following` — user following (always empty)
    * `GET /ap/boards/:slug/outbox` — board outbox (Announce activities, public only)
    * `GET /ap/boards/:slug/followers` — board followers (public only)
    * `GET /ap/boards/:slug/following` — board following (always empty)
    * `GET /ap/boards` — index of public AP-enabled boards
    * `GET /ap/articles/:slug/replies` — article comments as Note objects
    * `GET /ap/search?q=...` — full-text article search

  ### Objects (content-negotiated)
    * `GET /ap/articles/:slug` — Article object (requires public board)

  ### Inboxes (HTTP Signature verified)
    * `POST /ap/inbox` — shared inbox
    * `POST /ap/users/:username/inbox` — user inbox
    * `POST /ap/boards/:slug/inbox` — board inbox (public only)
  """

  use BaudrateWeb, :controller
  require Logger

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
        conn |> put_status(404) |> json(%{error: "Not Found"})

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

  @doc "Returns the NodeInfo 2.1 document with software and usage statistics."
  def nodeinfo(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Federation.nodeinfo())
  end

  # --- Actors ---

  @doc "Returns the ActivityPub Person actor for a user, or redirects to home for HTML requests."
  def user_actor(conn, %{"username" => username}) do
    conn = put_resp_header(conn, "vary", "Accept")

    if wants_json?(conn) do
      with true <- Regex.match?(@username_re, username),
           user when not is_nil(user) <-
             Baudrate.Repo.get_by(Baudrate.Setup.User, username: username),
           {:ok, user} <- KeyStore.ensure_user_keypair(user) do
        conn
        |> put_resp_content_type(@activity_json)
        |> json(Federation.user_actor(user))
      else
        _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
      end
    else
      redirect(conn, to: ~p"/")
    end
  end

  @doc "Returns the ActivityPub Group actor for a public AP-enabled board."
  def board_actor(conn, %{"slug" => slug}) do
    conn = put_resp_header(conn, "vary", "Accept")

    if wants_json?(conn) do
      with true <- Regex.match?(@slug_re, slug),
           board when not is_nil(board) <-
             Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
           true <- board.min_role_to_view == "guest",
           true <- board.ap_enabled,
           {:ok, board} <- KeyStore.ensure_board_keypair(board) do
        conn
        |> put_resp_content_type(@activity_json)
        |> json(Federation.board_actor(board))
      else
        _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
      end
    else
      redirect(conn, to: ~p"/boards/#{slug}")
    end
  end

  @doc "Returns the ActivityPub Organization actor representing the site."
  def site_actor(conn, _params) do
    conn = put_resp_header(conn, "vary", "Accept")

    if wants_json?(conn) do
      conn
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
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.user_outbox(user, params))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  @doc "Returns the paginated outbox collection (Announce activities) for a public board."
  def board_outbox(conn, %{"slug" => slug} = params) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- board.min_role_to_view == "guest",
         true <- board.ap_enabled do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.board_outbox(board, params))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  # --- Followers Collection ---

  @doc "Returns the paginated followers collection for a user."
  def user_followers(conn, %{"username" => username} = params) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <-
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
      actor_uri = Federation.actor_uri(:user, user.username)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.followers_collection(actor_uri, params))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  @doc "Returns the paginated followers collection for a public board."
  def board_followers(conn, %{"slug" => slug} = params) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- board.min_role_to_view == "guest",
         true <- board.ap_enabled do
      actor_uri = Federation.actor_uri(:board, board.slug)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.followers_collection(actor_uri, params))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  # --- Following Collection ---

  @doc "Returns the paginated following collection for a user."
  def user_following(conn, %{"username" => username} = params) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <-
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
      actor_uri = Federation.actor_uri(:user, user.username)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.following_collection(actor_uri, params))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  @doc "Returns the (always empty) following collection for a public board."
  def board_following(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- board.min_role_to_view == "guest",
         true <- board.ap_enabled do
      actor_uri = Federation.actor_uri(:board, board.slug)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.following_collection(actor_uri))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
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

          if Enum.any?(article.boards, &(&1.min_role_to_view == "guest")) do
            conn
            |> put_resp_content_type(@activity_json)
            |> json(Federation.article_object(article))
          else
            conn |> put_status(404) |> json(%{error: "Not Found"})
          end
        rescue
          Ecto.NoResultsError ->
            conn |> put_status(404) |> json(%{error: "Not Found"})
        end
      else
        _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
      end
    else
      redirect(conn, to: ~p"/articles/#{slug}")
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

        if Enum.any?(article.boards, &(&1.min_role_to_view == "guest")) do
          conn
          |> put_resp_content_type(@activity_json)
          |> json(Federation.article_replies(article))
        else
          conn |> put_status(404) |> json(%{error: "Not Found"})
        end
      rescue
        Ecto.NoResultsError ->
          conn |> put_status(404) |> json(%{error: "Not Found"})
      end
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
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
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
      handle_inbox(conn, {:user, user})
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  @doc "Receives activities at a board's inbox (public AP-enabled boards only)."
  def board_inbox(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- board.min_role_to_view == "guest",
         true <- board.ap_enabled do
      handle_inbox(conn, {:board, board})
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  defp handle_inbox(conn, target) do
    raw_body = conn.assigns[:raw_body] || ""
    remote_actor = conn.assigns[:remote_actor]

    case Jason.decode(raw_body) do
      {:ok, activity} ->
        case Baudrate.Federation.InboxHandler.handle(activity, remote_actor, target) do
          :ok ->
            conn |> put_status(202) |> json(%{status: "accepted"})

          {:error, :not_found} ->
            conn |> put_status(404) |> json(%{error: "Not Found"})

          {:error, reason} ->
            Logger.warning("federation.inbox_error: reason=#{inspect(reason)}")
            conn |> put_status(422) |> json(%{error: "Unprocessable"})
        end

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "Invalid JSON"})
    end
  end

  # --- Helpers ---

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
end
