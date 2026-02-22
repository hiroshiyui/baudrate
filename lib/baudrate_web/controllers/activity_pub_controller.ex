defmodule BaudrateWeb.ActivityPubController do
  @moduledoc """
  Controller for ActivityPub and discovery endpoints.

  Actor and article endpoints perform content negotiation: requests with
  `Accept: application/activity+json` or `application/ld+json` receive
  JSON-LD; all other requests are redirected to the corresponding HTML page.

  Machine-only endpoints (WebFinger, NodeInfo, outbox) always return JSON
  regardless of Accept header.

  Private boards are hidden from all AP endpoints — board actor, outbox,
  inbox, and WebFinger all return 404 for private boards. Articles
  exclusively in private boards also return 404.

  ## Endpoints

    * `GET /.well-known/webfinger` — WebFinger resource resolution
    * `GET /.well-known/nodeinfo` — NodeInfo discovery links
    * `GET /nodeinfo/2.1` — NodeInfo 2.1 document
    * `GET /ap/users/:username` — Person actor (content-negotiated)
    * `GET /ap/users/:username/outbox` — user outbox (OrderedCollection)
    * `GET /ap/users/:username/followers` — user followers (OrderedCollection)
    * `GET /ap/boards/:slug` — Group actor (content-negotiated, public only)
    * `GET /ap/boards/:slug/outbox` — board outbox (OrderedCollection, public only)
    * `GET /ap/boards/:slug/followers` — board followers (OrderedCollection, public only)
    * `GET /ap/site` — Organization actor (content-negotiated)
    * `GET /ap/articles/:slug` — Article object (content-negotiated, requires public board)
    * `POST /ap/inbox` — shared inbox (HTTP Signature verified)
    * `POST /ap/users/:username/inbox` — user inbox (HTTP Signature verified)
    * `POST /ap/boards/:slug/inbox` — board inbox (HTTP Signature verified, public only)
  """

  use BaudrateWeb, :controller
  require Logger

  alias Baudrate.Federation
  alias Baudrate.Federation.KeyStore

  plug :require_federation when action not in [:webfinger, :nodeinfo_redirect, :nodeinfo]

  @activity_json "application/activity+json"
  @jrd_json "application/jrd+json"

  @username_re ~r/\A[a-zA-Z0-9_]+\z/
  @slug_re ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  # --- WebFinger ---

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

  def nodeinfo_redirect(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Federation.nodeinfo_links())
  end

  def nodeinfo(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Federation.nodeinfo())
  end

  # --- Actors ---

  def user_actor(conn, %{"username" => username}) do
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

  def board_actor(conn, %{"slug" => slug}) do
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

  def site_actor(conn, _params) do
    if wants_json?(conn) do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.site_actor())
    else
      redirect(conn, to: ~p"/")
    end
  end

  # --- Outbox ---

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

  def user_followers(conn, %{"username" => username}) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <-
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
      actor_uri = Federation.actor_uri(:user, user.username)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.followers_collection(actor_uri))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  def board_followers(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         true <- board.min_role_to_view == "guest",
         true <- board.ap_enabled do
      actor_uri = Federation.actor_uri(:board, board.slug)

      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.followers_collection(actor_uri))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  # --- Article ---

  def article(conn, %{"slug" => slug}) do
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

  # --- Inbox ---

  def shared_inbox(conn, _params) do
    handle_inbox(conn, :shared)
  end

  def user_inbox(conn, %{"username" => username}) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <-
           Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
      handle_inbox(conn, {:user, user})
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

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
      String.contains?(accept, "application/ld+json")
  end
end
