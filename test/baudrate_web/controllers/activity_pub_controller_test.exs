defmodule BaudrateWeb.ActivityPubControllerTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Forum"})
    BaudrateWeb.RateLimit.reset_all()

    {:ok, conn: conn}
  end

  defp ap_conn(conn) do
    put_req_header(conn, "accept", "application/activity+json")
  end

  defp json_conn(conn) do
    put_req_header(conn, "accept", "application/json")
  end

  # --- WebFinger ---

  describe "GET /.well-known/webfinger" do
    test "resolves user acct resource", %{conn: conn} do
      user = setup_user("user")
      host = URI.parse(BaudrateWeb.Endpoint.url()).host

      conn =
        conn
        |> json_conn()
        |> get("/.well-known/webfinger?resource=acct:#{user.username}@#{host}")

      body = json_response(conn, 200)

      assert body["subject"] =~ user.username
      assert [%{"rel" => "self", "type" => "application/activity+json"}] = body["links"]
    end

    test "resolves board acct resource with ! prefix", %{conn: conn} do
      board = setup_board()
      host = URI.parse(BaudrateWeb.Endpoint.url()).host

      conn =
        conn |> json_conn() |> get("/.well-known/webfinger?resource=acct:!#{board.slug}@#{host}")

      body = json_response(conn, 200)

      assert body["subject"] == "acct:#{board.slug}@#{host}"
      assert body["properties"]["https://www.w3.org/ns/activitystreams#type"] == "Group"
    end

    test "resolves board acct resource without ! prefix (Mastodon compat)", %{conn: conn} do
      _board = setup_board(%{slug: "my-board"})
      host = URI.parse(BaudrateWeb.Endpoint.url()).host

      conn =
        conn |> json_conn() |> get("/.well-known/webfinger?resource=acct:my-board@#{host}")

      body = json_response(conn, 200)

      assert body["subject"] == "acct:my-board@#{host}"
      assert [%{"rel" => "self", "href" => href}] = body["links"]
      assert href =~ "/ap/boards/my-board"
      assert body["properties"]["https://www.w3.org/ns/activitystreams#type"] == "Group"
    end

    test "bare name resolves user (no same-name board allowed)", %{conn: conn} do
      # Conflicts between usernames and board slugs are now prevented by changeset
      # validation. This test verifies that a user-only handle resolves correctly
      # as a Person actor via the WebFinger HTTP endpoint.
      username = "onlyuser#{System.unique_integer([:positive])}"
      host = URI.parse(BaudrateWeb.Endpoint.url()).host

      alias Baudrate.Setup
      alias Baudrate.Setup.{Role, User}

      unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
        Setup.seed_roles_and_permissions()
      end

      role = Repo.one!(from(r in Role, where: r.name == "user"))

      {:ok, _user} =
        %User{}
        |> User.registration_changeset(%{
          "username" => username,
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => role.id
        })
        |> Repo.insert()

      conn =
        conn
        |> json_conn()
        |> get("/.well-known/webfinger?resource=acct:#{username}@#{host}")

      body = json_response(conn, 200)

      assert [%{"href" => href}] = body["links"]
      assert href =~ "/ap/users/#{username}"
    end

    test "resolves site (instance actor) acct resource", %{conn: conn} do
      host = URI.parse(BaudrateWeb.Endpoint.url()).host

      conn =
        conn |> json_conn() |> get("/.well-known/webfinger?resource=acct:site@#{host}")

      body = json_response(conn, 200)
      assert body["subject"] == "acct:site@#{host}"
      assert [%{"rel" => "self", "href" => href}] = body["links"]
      assert href =~ "/ap/site"
      assert body["properties"]["https://www.w3.org/ns/activitystreams#type"] == "Organization"
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      host = URI.parse(BaudrateWeb.Endpoint.url()).host

      conn =
        conn |> json_conn() |> get("/.well-known/webfinger?resource=acct:nonexistent@#{host}")

      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 400 for invalid resource", %{conn: conn} do
      conn = conn |> json_conn() |> get("/.well-known/webfinger?resource=invalid")
      assert json_response(conn, 400)["error"] == "Invalid resource"
    end

    test "returns 400 for missing resource param", %{conn: conn} do
      conn = conn |> json_conn() |> get("/.well-known/webfinger")
      assert json_response(conn, 400)["error"] == "Missing resource parameter"
    end
  end

  # --- NodeInfo ---

  describe "GET /.well-known/nodeinfo" do
    test "returns links to nodeinfo 2.0 and 2.1", %{conn: conn} do
      conn = conn |> json_conn() |> get("/.well-known/nodeinfo")
      rels = json_response(conn, 200)["links"] |> Enum.map(& &1["rel"])

      assert "http://nodeinfo.diaspora.software/ns/schema/2.0" in rels
      assert "http://nodeinfo.diaspora.software/ns/schema/2.1" in rels
    end
  end

  describe "GET /nodeinfo/2.1" do
    test "returns NodeInfo 2.1 document", %{conn: conn} do
      conn = conn |> json_conn() |> get("/nodeinfo/2.1")
      body = json_response(conn, 200)

      assert body["version"] == "2.1"
      assert body["software"]["name"] == "baudrate"
      assert "activitypub" in body["protocols"]
      assert is_integer(body["usage"]["users"]["total"])
      assert is_integer(body["usage"]["localPosts"])
    end
  end

  # --- Content Negotiation ---

  describe "content negotiation" do
    test "application/json Accept returns JSON on user actor endpoint", %{conn: conn} do
      user = setup_user("user")

      conn = conn |> json_conn() |> get("/ap/users/#{user.username}")
      body = json_response(conn, 200)

      assert body["type"] == "Person"
      assert body["preferredUsername"] == user.username
    end

    test "application/json Accept returns JSON on board actor endpoint", %{conn: conn} do
      board = setup_board()

      conn = conn |> json_conn() |> get("/ap/boards/#{board.slug}")
      body = json_response(conn, 200)

      assert body["type"] == "Group"
    end

    test "application/json Accept returns JSON on site actor endpoint", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/site")
      body = json_response(conn, 200)

      assert body["type"] == "Organization"
    end

    test "application/json Accept returns JSON on article endpoint", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      article = setup_article(user, board)

      conn = conn |> json_conn() |> get("/ap/articles/#{article.slug}")
      body = json_response(conn, 200)

      assert body["type"] == "Article"
    end

    test "AP Accept on public article URL returns AS2 JSON", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      article = setup_article(user, board)

      conn = conn |> ap_conn() |> get("/articles/#{article.slug}")
      body = json_response(conn, 200)

      assert body["type"] == "Article"
      assert body["id"] =~ "/ap/articles/#{article.slug}"
      assert "Accept" in get_resp_header(conn, "vary")
    end
  end

  # --- CORS ---

  describe "CORS headers" do
    test "GET responses include CORS headers", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/site")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
    end

    test "OPTIONS preflight returns 204", %{conn: conn} do
      conn = conn |> options("/ap/site")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  # --- Vary Header ---

  describe "Vary: Accept header" do
    test "content-negotiated endpoints include Vary: Accept", %{conn: conn} do
      user = setup_user("user")

      conn = conn |> ap_conn() |> get("/ap/users/#{user.username}")

      assert "Accept" in get_resp_header(conn, "vary")
    end

    test "board actor includes Vary: Accept", %{conn: conn} do
      board = setup_board()

      conn = conn |> ap_conn() |> get("/ap/boards/#{board.slug}")

      assert "Accept" in get_resp_header(conn, "vary")
    end

    test "article includes Vary: Accept", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      article = setup_article(user, board)

      conn = conn |> ap_conn() |> get("/ap/articles/#{article.slug}")

      assert "Accept" in get_resp_header(conn, "vary")
    end
  end

  # --- Actor Endpoints ---

  describe "GET /ap/users/:username" do
    test "returns Person JSON-LD for AP accept header", %{conn: conn} do
      user = setup_user("user")

      conn = conn |> ap_conn() |> get("/ap/users/#{user.username}")
      body = json_response(conn, 200)

      assert body["type"] == "Person"
      assert body["preferredUsername"] == user.username
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
      assert body["published"]
      # A successful actor document is cacheable since Phase 3F; `no-store`
      # stays on 404s and redirects.
      assert get_resp_header(conn, "cache-control") == ["public, max-age=180"]
    end

    test "returns Person JSON-LD for ld+json accept header", %{conn: conn} do
      user = setup_user("user")

      conn =
        conn
        |> put_req_header("accept", "application/ld+json")
        |> get("/ap/users/#{user.username}")

      body = json_response(conn, 200)
      assert body["type"] == "Person"
    end

    test "redirects to HTML for browser accept header", %{conn: conn} do
      user = setup_user("user")

      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/ap/users/#{user.username}")

      assert redirected_to(conn, 302) == "/"
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      conn = conn |> ap_conn() |> get("/ap/users/nonexistent")
      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for invalid username format", %{conn: conn} do
      conn = conn |> ap_conn() |> get("/ap/users/invalid user")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "GET /ap/boards/:slug" do
    test "returns Group JSON-LD for AP accept header", %{conn: conn} do
      board = setup_board()

      conn = conn |> ap_conn() |> get("/ap/boards/#{board.slug}")
      body = json_response(conn, 200)

      assert body["type"] == "Group"
      assert body["preferredUsername"] == board.slug
      assert body["name"] == board.name
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
      # A successful actor document is cacheable since Phase 3F; `no-store`
      # stays on 404s and redirects.
      assert get_resp_header(conn, "cache-control") == ["public, max-age=180"]
    end

    test "redirects to board HTML page for browser accept header", %{conn: conn} do
      board = setup_board()

      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/ap/boards/#{board.slug}")

      assert redirected_to(conn, 302) == "/boards/#{board.slug}"
    end

    test "returns 404 for non-existent board", %{conn: conn} do
      conn = conn |> ap_conn() |> get("/ap/boards/nonexistent")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "GET /ap/site" do
    test "returns Organization JSON-LD for AP accept header", %{conn: conn} do
      conn = conn |> ap_conn() |> get("/ap/site")
      body = json_response(conn, 200)

      assert body["type"] == "Organization"
      assert body["name"] == "Test Forum"
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
      # A successful actor document is cacheable since Phase 3F; `no-store`
      # stays on 404s and redirects.
      assert get_resp_header(conn, "cache-control") == ["public, max-age=180"]
    end

    test "redirects to home for browser accept header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/ap/site")

      assert redirected_to(conn, 302) == "/"
    end
  end

  # --- Boards Index ---

  describe "GET /ap/boards" do
    test "returns OrderedCollection of public boards", %{conn: conn} do
      board = setup_board()

      conn = conn |> json_conn() |> get("/ap/boards")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] >= 1
      assert is_list(body["orderedItems"])

      items = body["orderedItems"]
      board_item = Enum.find(items, &(&1["name"] == board.name))
      assert board_item
      assert board_item["type"] == "Group"
      assert board_item["summary"] == board.description
    end

    test "excludes private boards", %{conn: conn} do
      _public_board = setup_board()

      {:ok, _private_board} =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{
          name: "Private Board",
          slug: "private-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })
        |> Repo.insert()

      conn = conn |> json_conn() |> get("/ap/boards")
      body = json_response(conn, 200)

      names = Enum.map(body["orderedItems"], & &1["name"])
      refute "Private Board" in names
    end
  end

  # --- Outbox Endpoints (Paginated) ---

  describe "GET /ap/users/:username/outbox" do
    test "returns root OrderedCollection with totalItems and first link", %{conn: conn} do
      user = setup_user("user")

      conn = conn |> json_conn() |> get("/ap/users/#{user.username}/outbox")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert is_integer(body["totalItems"])
      assert body["first"] =~ "page=1"
      refute body["orderedItems"]
    end

    test "returns OrderedCollectionPage with items when page param given", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      _article = setup_article(user, board)

      conn = conn |> json_conn() |> get("/ap/users/#{user.username}/outbox?page=1")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollectionPage"
      assert body["partOf"] =~ "/outbox"
      assert is_list(body["orderedItems"])
      assert length(body["orderedItems"]) == 1

      [item] = body["orderedItems"]
      assert item["type"] == "Create"
      assert item["object"]["type"] == "Article"
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/users/nonexistent/outbox")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "GET /ap/boards/:slug/outbox" do
    test "returns root OrderedCollection without page param", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      _article = setup_article(user, board)

      conn = conn |> json_conn() |> get("/ap/boards/#{board.slug}/outbox")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 1
      assert body["first"] =~ "page=1"
    end

    test "returns OrderedCollectionPage with Announce activities", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      _article = setup_article(user, board)

      conn = conn |> json_conn() |> get("/ap/boards/#{board.slug}/outbox?page=1")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollectionPage"
      assert length(body["orderedItems"]) == 1
      [item] = body["orderedItems"]
      assert item["type"] == "Announce"
    end

    test "returns 404 for non-existent board", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/boards/nonexistent/outbox")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  # --- Followers Collection Endpoints (Paginated) ---

  describe "GET /ap/users/:username/followers" do
    test "returns root OrderedCollection with totalItems", %{conn: conn} do
      user = setup_user("user")

      conn = conn |> json_conn() |> get("/ap/users/#{user.username}/followers")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 0
      assert body["first"] =~ "page=1"
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/users/nonexistent/followers")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "GET /ap/boards/:slug/followers" do
    test "returns root OrderedCollection for public board", %{conn: conn} do
      board = setup_board()

      conn = conn |> json_conn() |> get("/ap/boards/#{board.slug}/followers")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 0
    end

    test "returns 404 for private board", %{conn: conn} do
      {:ok, board} =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{
          name: "Private",
          slug: "private-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })
        |> Repo.insert()

      conn = conn |> json_conn() |> get("/ap/boards/#{board.slug}/followers")
      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for non-existent board", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/boards/nonexistent/followers")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  # --- Following Collection Endpoints ---

  describe "GET /ap/users/:username/following" do
    test "returns paginated OrderedCollection with zero items", %{conn: conn} do
      user = setup_user("user")

      conn = conn |> json_conn() |> get("/ap/users/#{user.username}/following")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 0
      assert body["first"] =~ "/following?page=1"
      assert body["id"] =~ "/following"
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/users/nonexistent/following")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "GET /ap/boards/:slug/following" do
    test "returns empty OrderedCollection for public board", %{conn: conn} do
      board = setup_board()

      conn = conn |> json_conn() |> get("/ap/boards/#{board.slug}/following")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 0
      assert body["first"] =~ "/following?page=1"
    end

    test "returns 404 for private board", %{conn: conn} do
      {:ok, board} =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{
          name: "Private Following",
          slug: "priv-following-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })
        |> Repo.insert()

      conn = conn |> json_conn() |> get("/ap/boards/#{board.slug}/following")
      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for non-existent board", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/boards/nonexistent/following")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  # --- Article Endpoint ---

  describe "GET /ap/articles/:slug" do
    test "returns Article JSON-LD with HTML content and enriched fields", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      article = setup_article(user, board)

      conn = conn |> ap_conn() |> get("/ap/articles/#{article.slug}")
      body = json_response(conn, 200)

      assert body["type"] == "Article"
      assert body["name"] == article.title
      assert body["mediaType"] == "text/html"
      assert body["content"] =~ "<p>"
      assert body["source"]["mediaType"] == "text/markdown"
      assert body["attributedTo"] =~ user.username
      assert body["replies"] =~ "/replies"
      assert is_boolean(body["baudrate:pinned"])
      assert is_boolean(body["baudrate:locked"])
      assert is_integer(body["baudrate:commentCount"])
      assert is_integer(body["baudrate:likeCount"])
    end

    test "redirects to article HTML page for browser accept header", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      article = setup_article(user, board)

      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> get("/ap/articles/#{article.slug}")

      assert redirected_to(conn, 302) == "/articles/#{article.slug}"
    end

    test "returns 404 for a remote article ingested as followers-only", %{conn: conn} do
      uid = System.unique_integer([:positive])

      {:ok, actor} =
        %Baudrate.Federation.RemoteActor{}
        |> Baudrate.Federation.RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/fo-#{uid}",
          username: "fo_#{uid}",
          domain: "remote.example",
          public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
          inbox: "https://remote.example/users/fo-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      {:ok, %{article: article}} =
        Baudrate.Content.create_remote_article(
          %{
            title: "Followers only",
            body: "secret",
            slug: "fo-#{uid}",
            ap_id: "https://remote.example/notes/fo-#{uid}",
            remote_actor_id: actor.id,
            visibility: "followers_only"
          },
          []
        )

      conn = conn |> ap_conn() |> get("/ap/articles/#{article.slug}")
      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for non-existent article", %{conn: conn} do
      conn = conn |> ap_conn() |> get("/ap/articles/nonexistent-slug")
      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for invalid slug format", %{conn: conn} do
      conn = conn |> ap_conn() |> get("/ap/articles/INVALID SLUG")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  # --- Article Replies ---

  describe "GET /ap/articles/:slug/replies" do
    test "returns OrderedCollection of Note objects", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      article = setup_article(user, board)

      # Create a comment on the article
      {:ok, _comment} =
        Baudrate.Content.create_comment(%{
          "body" => "A test comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      conn = conn |> json_conn() |> get("/ap/articles/#{article.slug}/replies")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 1
      [reply] = body["orderedItems"]
      assert reply["type"] == "Note"
      assert reply["content"] =~ "test comment"
      assert reply["attributedTo"] =~ user.username
      assert reply["inReplyTo"] =~ article.slug
    end

    test "returns empty collection when no comments", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      article = setup_article(user, board)

      conn = conn |> json_conn() |> get("/ap/articles/#{article.slug}/replies")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 0
      assert body["orderedItems"] == []
    end

    test "returns 404 for non-existent article", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/articles/nonexistent-slug/replies")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  # --- Search ---

  describe "GET /ap/search" do
    test "returns results for matching query", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      _article = setup_article(user, board)

      conn = conn |> json_conn() |> get("/ap/search?q=Test+Article&page=1")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollectionPage"
      assert is_integer(body["totalItems"])
      assert is_list(body["orderedItems"])
    end

    test "returns root collection without page param", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/search?q=test")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert is_integer(body["totalItems"])
      assert body["first"] =~ "page=1"
    end

    test "returns 400 when q parameter is missing", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/search")
      assert json_response(conn, 400)["error"] == "Missing q parameter"
    end

    test "returns 400 when q parameter is empty", %{conn: conn} do
      conn = conn |> json_conn() |> get("/ap/search?q=")
      assert json_response(conn, 400)["error"] == "Missing q parameter"
    end

    # The whole outbound gate, not half of it: this collection is
    # unauthenticated and each item is a full Article object stamped
    # `as:Public`, so `ap_enabled` is required as well as guest-readability.
    # The query filtered `min_role_to_view` only, so an article in a board
    # whose federation an admin had switched off was served here with its
    # title and body while its own permalink answered 404.
    test "excludes an article whose only board has federation disabled", %{conn: conn} do
      user = setup_user("user")
      board = setup_board(%{ap_enabled: false})
      article = setup_article(user, board)

      conn = conn |> json_conn() |> get("/ap/search?q=Test+Article&page=1")
      body = json_response(conn, 200)

      ids = Enum.map(body["orderedItems"], & &1["id"])
      refute article.ap_id in ids
      refute Enum.any?(body["orderedItems"], &(&1["name"] == article.title))

      # The permalink already refused it; the collection now agrees.
      assert conn
             |> recycle()
             |> ap_conn()
             |> get("/ap/articles/#{article.slug}")
             |> Map.get(:status) ==
               404
    end

    test "still includes an article in a guest-readable federated board", %{conn: conn} do
      user = setup_user("user")
      board = setup_board(%{ap_enabled: true, min_role_to_view: "guest"})
      article = setup_article(user, board)

      conn = conn |> json_conn() |> get("/ap/search?q=Test+Article&page=1")
      body = json_response(conn, 200)

      assert article.ap_id in Enum.map(body["orderedItems"], & &1["id"])
    end

    # `totalItems` and the page come from one result, so the gate has to be in
    # the query. A filter over the items would advertise a count the pages
    # cannot fill, and offer a `next` page that renders empty.
    test "totalItems agrees with the items it can serve", %{conn: conn} do
      user = setup_user("user")
      open = setup_board(%{ap_enabled: true, min_role_to_view: "guest"})
      closed = setup_board(%{ap_enabled: false})
      _served = setup_article(user, open)
      _withheld = setup_article(user, closed)

      conn = conn |> json_conn() |> get("/ap/search?q=Test+Article&page=1")
      body = json_response(conn, 200)

      assert body["totalItems"] == length(body["orderedItems"])
    end

    # The site is not the fediverse: turning a board's federation off must not
    # remove its articles from the instance's own search.
    test "the site's own search is unaffected by ap_enabled" do
      user = setup_user("user")
      board = setup_board(%{ap_enabled: false})
      article = setup_article(user, board)

      result = Baudrate.Content.search_articles("Test Article", user: user)

      assert article.id in Enum.map(result.articles, & &1.id)
    end
  end

  # --- Federation Kill Switch ---

  describe "federation kill switch" do
    test "AP actor endpoints return 404 when federation is disabled", %{conn: conn} do
      user = setup_user("user")
      Repo.insert!(%Setting{key: "ap_federation_enabled", value: "false"})

      conn = conn |> ap_conn() |> get("/ap/users/#{user.username}")
      assert conn.status == 404
    end

    test "AP board endpoints return 404 when federation is disabled", %{conn: conn} do
      board = setup_board()
      Repo.insert!(%Setting{key: "ap_federation_enabled", value: "false"})

      conn = conn |> ap_conn() |> get("/ap/boards/#{board.slug}")
      assert conn.status == 404
    end

    test "AP site actor returns 404 when federation is disabled", %{conn: conn} do
      Repo.insert!(%Setting{key: "ap_federation_enabled", value: "false"})

      conn = conn |> ap_conn() |> get("/ap/site")
      assert conn.status == 404
    end

    test "AP outbox returns 404 when federation is disabled", %{conn: conn} do
      user = setup_user("user")
      Repo.insert!(%Setting{key: "ap_federation_enabled", value: "false"})

      conn = conn |> json_conn() |> get("/ap/users/#{user.username}/outbox")
      assert conn.status == 404
    end

    test "AP boards index returns 404 when federation is disabled", %{conn: conn} do
      Repo.insert!(%Setting{key: "ap_federation_enabled", value: "false"})

      conn = conn |> json_conn() |> get("/ap/boards")
      assert conn.status == 404
    end

    test "AP search returns 404 when federation is disabled", %{conn: conn} do
      Repo.insert!(%Setting{key: "ap_federation_enabled", value: "false"})

      conn = conn |> json_conn() |> get("/ap/search?q=test")
      assert conn.status == 404
    end

    test "WebFinger still works when federation is disabled", %{conn: conn} do
      user = setup_user("user")
      host = URI.parse(BaudrateWeb.Endpoint.url()).host
      Repo.insert!(%Setting{key: "ap_federation_enabled", value: "false"})

      conn =
        conn
        |> json_conn()
        |> get("/.well-known/webfinger?resource=acct:#{user.username}@#{host}")

      assert json_response(conn, 200)
    end

    test "NodeInfo still works when federation is disabled", %{conn: conn} do
      Repo.insert!(%Setting{key: "ap_federation_enabled", value: "false"})

      conn = conn |> json_conn() |> get("/.well-known/nodeinfo")
      assert json_response(conn, 200)
    end
  end

  # --- Inbox Endpoints ---
  # Note: Inbox endpoints go through HTTP Signature verification.
  # We test the controller actions directly by calling them with
  # pre-assigned conn values, bypassing the plug pipeline.

  describe "shared_inbox" do
    # The plugs have verified the signature by the time the action runs; the
    # activity is admitted, stored and answered, then processed (in tests, at
    # once) by the inbound queue.
    test "stores an admitted activity and answers 202", %{conn: conn} do
      user = setup_user("user")
      remote = inbox_remote_actor()
      local = Baudrate.Federation.actor_uri(:user, user.username)
      activity = inbox_follow(remote, local)

      conn = inbox_post(conn, remote, activity)

      assert json_response(conn, 202)["status"] == "accepted"

      assert [%Baudrate.Federation.InboundActivity{status: "processed", activity_id: id}] =
               Repo.all(Baudrate.Federation.InboundActivity)

      assert id == activity["id"]
      assert Baudrate.Federation.follower_exists?(local, remote.ap_id)
    end

    test "answers 422 for an activity that fails admission, and stores nothing", %{conn: conn} do
      remote = inbox_remote_actor()

      activity =
        inbox_follow(remote, "https://local.example/ap/users/x")
        |> Map.put("actor", "https://remote.example/users/impostor")

      conn = inbox_post(conn, remote, activity)

      assert json_response(conn, 422)["error"] == "Unprocessable"
      assert Repo.aggregate(Baudrate.Federation.InboundActivity, :count) == 0
    end

    test "answers 202 to a redelivery without storing it again", %{conn: conn} do
      user = setup_user("user")
      remote = inbox_remote_actor()
      activity = inbox_follow(remote, Baudrate.Federation.actor_uri(:user, user.username))

      assert json_response(inbox_post(conn, remote, activity), 202)
      assert json_response(inbox_post(build_conn(), remote, activity), 202)

      assert Repo.aggregate(Baudrate.Federation.InboundActivity, :count) == 1
    end

    test "returns 400 for invalid JSON body", %{conn: conn} do
      conn =
        conn
        |> assign(:raw_body, "not valid json{{{")
        |> assign(:remote_actor, nil)

      conn = BaudrateWeb.ActivityPubController.shared_inbox(conn, %{})

      assert json_response(conn, 400)["error"] == "Invalid JSON"
    end
  end

  describe "user_inbox" do
    test "returns 404 for non-existent user", %{conn: conn} do
      conn =
        conn
        |> assign(:raw_body, Jason.encode!(%{"type" => "Follow"}))
        |> assign(:remote_actor, nil)

      conn = BaudrateWeb.ActivityPubController.user_inbox(conn, %{"username" => "nonexistent"})

      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for invalid username format", %{conn: conn} do
      conn =
        conn
        |> assign(:raw_body, Jason.encode!(%{"type" => "Follow"}))
        |> assign(:remote_actor, nil)

      conn = BaudrateWeb.ActivityPubController.user_inbox(conn, %{"username" => "invalid user"})

      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "board_inbox" do
    test "returns 404 for non-existent board", %{conn: conn} do
      conn =
        conn
        |> assign(:raw_body, Jason.encode!(%{"type" => "Follow"}))
        |> assign(:remote_actor, nil)

      conn = BaudrateWeb.ActivityPubController.board_inbox(conn, %{"slug" => "nonexistent"})

      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for private board", %{conn: conn} do
      {:ok, board} =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{
          name: "Private Inbox Board",
          slug: "priv-inbox-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })
        |> Repo.insert()

      conn =
        conn
        |> assign(:raw_body, Jason.encode!(%{"type" => "Follow"}))
        |> assign(:remote_actor, nil)

      conn = BaudrateWeb.ActivityPubController.board_inbox(conn, %{"slug" => board.slug})

      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for AP-disabled board", %{conn: conn} do
      {:ok, board} =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{
          name: "No AP Board",
          slug: "no-ap-#{System.unique_integer([:positive])}",
          min_role_to_view: "guest",
          ap_enabled: false
        })
        |> Repo.insert()

      conn =
        conn
        |> assign(:raw_body, Jason.encode!(%{"type" => "Follow"}))
        |> assign(:remote_actor, nil)

      conn = BaudrateWeb.ActivityPubController.board_inbox(conn, %{"slug" => board.slug})

      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  # --- Board-less Articles ---

  describe "board-less articles" do
    test "returns Article JSON-LD for board-less article", %{conn: conn} do
      user = setup_user("user")
      article = setup_boardless_article(user)

      conn = conn |> ap_conn() |> get("/ap/articles/#{article.slug}")
      body = json_response(conn, 200)

      assert body["type"] == "Article"
      assert body["name"] == article.title
      assert body["attributedTo"] =~ user.username
    end

    test "returns replies for board-less article", %{conn: conn} do
      user = setup_user("user")
      article = setup_boardless_article(user)

      {:ok, _comment} =
        Baudrate.Content.create_comment(%{
          "body" => "Comment on boardless",
          "article_id" => article.id,
          "user_id" => user.id
        })

      conn = conn |> json_conn() |> get("/ap/articles/#{article.slug}/replies")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 1
    end
  end

  # --- Test Helpers ---

  defp inbox_remote_actor do
    uid = System.unique_integer([:positive])

    %Baudrate.Federation.RemoteActor{}
    |> Baudrate.Federation.RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/inbox-#{uid}",
      username: "inbox_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(Baudrate.Federation.KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/inbox-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp inbox_follow(remote, object) do
    %{
      "id" => "#{remote.ap_id}/follows/#{System.unique_integer([:positive])}",
      "type" => "Follow",
      "actor" => remote.ap_id,
      "object" => object
    }
  end

  defp inbox_post(conn, remote, activity) do
    conn
    |> assign(:raw_body, Jason.encode!(activity))
    |> assign(:remote_actor, remote)
    |> BaudrateWeb.ActivityPubController.shared_inbox(%{})
  end

  defp setup_board(attrs \\ %{}) do
    alias Baudrate.Content.Board

    default = %{
      name: "AP Test Board",
      slug: "ap-test-#{System.unique_integer([:positive])}",
      description: "ActivityPub test board"
    }

    {:ok, board} =
      %Board{}
      |> Board.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    board
  end

  defp setup_article(user, board) do
    slug = "ap-article-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(
        %{
          title: "Test Article",
          body: "Test article body for **AP**.",
          slug: slug,
          user_id: user.id
        },
        [board.id]
      )

    Baudrate.Repo.preload(article, [:boards, :user])
  end

  defp setup_boardless_article(user) do
    slug = "ap-boardless-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(
        %{
          title: "Boardless AP Article",
          body: "Body for **boardless** article.",
          slug: slug,
          user_id: user.id
        },
        []
      )

    Baudrate.Repo.preload(article, [:boards, :user])
  end
end
