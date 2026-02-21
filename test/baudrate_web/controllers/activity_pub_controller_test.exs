defmodule BaudrateWeb.ActivityPubControllerTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Forum"})
    Hammer.delete_buckets("activity_pub:127.0.0.1")

    conn = put_req_header(conn, "accept", "application/json")
    {:ok, conn: conn}
  end

  # --- WebFinger ---

  describe "GET /.well-known/webfinger" do
    test "resolves user acct resource", %{conn: conn} do
      user = setup_user("user")
      host = URI.parse(BaudrateWeb.Endpoint.url()).host

      conn = get(conn, "/.well-known/webfinger?resource=acct:#{user.username}@#{host}")
      body = json_response(conn, 200)

      assert body["subject"] =~ user.username
      assert [%{"rel" => "self", "type" => "application/activity+json"}] = body["links"]
    end

    test "resolves board acct resource with ! prefix", %{conn: conn} do
      board = setup_board()
      host = URI.parse(BaudrateWeb.Endpoint.url()).host

      conn = get(conn, "/.well-known/webfinger?resource=acct:!#{board.slug}@#{host}")
      body = json_response(conn, 200)

      assert body["subject"] =~ board.slug
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      host = URI.parse(BaudrateWeb.Endpoint.url()).host
      conn = get(conn, "/.well-known/webfinger?resource=acct:nonexistent@#{host}")
      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 400 for invalid resource", %{conn: conn} do
      conn = get(conn, "/.well-known/webfinger?resource=invalid")
      assert json_response(conn, 400)["error"] == "Invalid resource"
    end

    test "returns 400 for missing resource param", %{conn: conn} do
      conn = get(conn, "/.well-known/webfinger")
      assert json_response(conn, 400)["error"] == "Missing resource parameter"
    end
  end

  # --- NodeInfo ---

  describe "GET /.well-known/nodeinfo" do
    test "returns links to nodeinfo 2.1", %{conn: conn} do
      conn = get(conn, "/.well-known/nodeinfo")
      body = json_response(conn, 200)

      assert [%{"rel" => rel, "href" => href}] = body["links"]
      assert rel == "http://nodeinfo.diaspora.software/ns/schema/2.1"
      assert href =~ "/nodeinfo/2.1"
    end
  end

  describe "GET /nodeinfo/2.1" do
    test "returns NodeInfo 2.1 document", %{conn: conn} do
      conn = get(conn, "/nodeinfo/2.1")
      body = json_response(conn, 200)

      assert body["version"] == "2.1"
      assert body["software"]["name"] == "baudrate"
      assert "activitypub" in body["protocols"]
      assert is_integer(body["usage"]["users"]["total"])
      assert is_integer(body["usage"]["localPosts"])
    end
  end

  # --- Actor Endpoints ---

  describe "GET /ap/users/:username" do
    test "returns Person JSON-LD for existing user", %{conn: conn} do
      user = setup_user("user")

      conn = get(conn, "/ap/users/#{user.username}")
      body = json_response(conn, 200)

      assert body["type"] == "Person"
      assert body["preferredUsername"] == user.username
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      conn = get(conn, "/ap/users/nonexistent")
      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for invalid username format", %{conn: conn} do
      conn = get(conn, "/ap/users/invalid user")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "GET /ap/boards/:slug" do
    test "returns Group JSON-LD for existing board", %{conn: conn} do
      board = setup_board()

      conn = get(conn, "/ap/boards/#{board.slug}")
      body = json_response(conn, 200)

      assert body["type"] == "Group"
      assert body["preferredUsername"] == board.slug
      assert body["name"] == board.name
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "returns 404 for non-existent board", %{conn: conn} do
      conn = get(conn, "/ap/boards/nonexistent")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "GET /ap/site" do
    test "returns Organization JSON-LD", %{conn: conn} do
      conn = get(conn, "/ap/site")
      body = json_response(conn, 200)

      assert body["type"] == "Organization"
      assert body["name"] == "Test Forum"
      assert body["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end
  end

  # --- Outbox Endpoints ---

  describe "GET /ap/users/:username/outbox" do
    test "returns OrderedCollection", %{conn: conn} do
      user = setup_user("user")

      conn = get(conn, "/ap/users/#{user.username}/outbox")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert is_integer(body["totalItems"])
      assert is_list(body["orderedItems"])
    end

    test "includes articles as Create activities", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      _article = setup_article(user, board)

      conn = get(conn, "/ap/users/#{user.username}/outbox")
      body = json_response(conn, 200)

      assert body["totalItems"] == 1
      [item] = body["orderedItems"]
      assert item["type"] == "Create"
      assert item["object"]["type"] == "Article"
    end

    test "returns 404 for non-existent user", %{conn: conn} do
      conn = get(conn, "/ap/users/nonexistent/outbox")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  describe "GET /ap/boards/:slug/outbox" do
    test "returns OrderedCollection with Announce activities", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      _article = setup_article(user, board)

      conn = get(conn, "/ap/boards/#{board.slug}/outbox")
      body = json_response(conn, 200)

      assert body["type"] == "OrderedCollection"
      assert body["totalItems"] == 1
      [item] = body["orderedItems"]
      assert item["type"] == "Announce"
    end

    test "returns 404 for non-existent board", %{conn: conn} do
      conn = get(conn, "/ap/boards/nonexistent/outbox")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  # --- Article Endpoint ---

  describe "GET /ap/articles/:slug" do
    test "returns Article JSON-LD", %{conn: conn} do
      user = setup_user("user")
      board = setup_board()
      article = setup_article(user, board)

      conn = get(conn, "/ap/articles/#{article.slug}")
      body = json_response(conn, 200)

      assert body["type"] == "Article"
      assert body["name"] == article.title
      assert body["content"] == article.body
      assert body["attributedTo"] =~ user.username
    end

    test "returns 404 for non-existent article", %{conn: conn} do
      conn = get(conn, "/ap/articles/nonexistent-slug")
      assert json_response(conn, 404)["error"] == "Not Found"
    end

    test "returns 404 for invalid slug format", %{conn: conn} do
      conn = get(conn, "/ap/articles/INVALID SLUG")
      assert json_response(conn, 404)["error"] == "Not Found"
    end
  end

  # --- Test Helpers ---

  defp setup_board do
    alias Baudrate.Content.Board

    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "AP Test Board",
        slug: "ap-test-#{System.unique_integer([:positive])}",
        description: "ActivityPub test board"
      })
      |> Repo.insert()

    board
  end

  defp setup_article(user, board) do
    slug = "ap-article-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(
        %{
          title: "Test Article",
          body: "Test article body for AP.",
          slug: slug,
          user_id: user.id
        },
        [board.id]
      )

    Baudrate.Repo.preload(article, [:boards, :user])
  end
end
