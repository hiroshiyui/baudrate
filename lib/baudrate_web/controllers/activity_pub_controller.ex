defmodule BaudrateWeb.ActivityPubController do
  @moduledoc """
  Controller for ActivityPub and discovery endpoints.

  All actions return JSON (either `application/activity+json` or
  `application/jrd+json`). Routes are defined in the `:activity_pub`
  pipeline which enforces rate limiting and JSON-only accepts.

  ## Endpoints

    * `GET /.well-known/webfinger` — WebFinger resource resolution
    * `GET /.well-known/nodeinfo` — NodeInfo discovery links
    * `GET /nodeinfo/2.1` — NodeInfo 2.1 document
    * `GET /ap/users/:username` — Person actor
    * `GET /ap/users/:username/outbox` — user outbox (OrderedCollection)
    * `GET /ap/boards/:slug` — Group actor
    * `GET /ap/boards/:slug/outbox` — board outbox (OrderedCollection)
    * `GET /ap/site` — Organization actor
    * `GET /ap/articles/:slug` — Article object
  """

  use BaudrateWeb, :controller

  alias Baudrate.Federation
  alias Baudrate.Federation.KeyStore

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
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <- Baudrate.Repo.get_by(Baudrate.Setup.User, username: username),
         {:ok, user} <- KeyStore.ensure_user_keypair(user) do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.user_actor(user))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  def board_actor(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug),
         {:ok, board} <- KeyStore.ensure_board_keypair(board) do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.board_actor(board))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  def site_actor(conn, _params) do
    conn
    |> put_resp_content_type(@activity_json)
    |> json(Federation.site_actor())
  end

  # --- Outbox ---

  def user_outbox(conn, %{"username" => username} = params) do
    with true <- Regex.match?(@username_re, username),
         user when not is_nil(user) <- Baudrate.Repo.get_by(Baudrate.Setup.User, username: username) do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.user_outbox(user, params))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  def board_outbox(conn, %{"slug" => slug} = params) do
    with true <- Regex.match?(@slug_re, slug),
         board when not is_nil(board) <- Baudrate.Repo.get_by(Baudrate.Content.Board, slug: slug) do
      conn
      |> put_resp_content_type(@activity_json)
      |> json(Federation.board_outbox(board, params))
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end

  # --- Article ---

  def article(conn, %{"slug" => slug}) do
    with true <- Regex.match?(@slug_re, slug) do
      try do
        article = Baudrate.Content.get_article_by_slug!(slug)

        conn
        |> put_resp_content_type(@activity_json)
        |> json(Federation.article_object(article))
      rescue
        Ecto.NoResultsError ->
          conn |> put_status(404) |> json(%{error: "Not Found"})
      end
    else
      _ -> conn |> put_status(404) |> json(%{error: "Not Found"})
    end
  end
end
