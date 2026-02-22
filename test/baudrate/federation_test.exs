defmodule Baudrate.FederationTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation
  alias Baudrate.Federation.KeyStore
  alias Baudrate.Setup.Setting

  setup do
    # Seed site name for nodeinfo tests
    Repo.insert!(%Setting{key: "site_name", value: "Test Forum"})
    :ok
  end

  describe "actor_uri/2" do
    test "builds user actor URI" do
      uri = Federation.actor_uri(:user, "alice")
      assert uri =~ "/ap/users/alice"
    end

    test "builds board actor URI" do
      uri = Federation.actor_uri(:board, "sysop")
      assert uri =~ "/ap/boards/sysop"
    end

    test "builds site actor URI" do
      uri = Federation.actor_uri(:site, nil)
      assert uri =~ "/ap/site"
    end

    test "builds article URI" do
      uri = Federation.actor_uri(:article, "hello-world")
      assert uri =~ "/ap/articles/hello-world"
    end
  end

  describe "webfinger/1" do
    test "resolves user by acct URI" do
      user = setup_user_with_role("user")
      host = URI.parse(Federation.base_url()).host

      {:ok, jrd} = Federation.webfinger("acct:#{user.username}@#{host}")
      assert jrd["subject"] =~ user.username
      assert [%{"rel" => "self", "type" => "application/activity+json"}] = jrd["links"]
    end

    test "resolves board by acct URI with ! prefix" do
      board = setup_board("wb-test")
      host = URI.parse(Federation.base_url()).host

      {:ok, jrd} = Federation.webfinger("acct:!#{board.slug}@#{host}")
      assert jrd["subject"] =~ board.slug
      assert [%{"rel" => "self", "href" => href}] = jrd["links"]
      assert href =~ "/ap/boards/#{board.slug}"
    end

    test "returns error for non-existent user" do
      host = URI.parse(Federation.base_url()).host
      assert {:error, :not_found} = Federation.webfinger("acct:nonexistent@#{host}")
    end

    test "returns error for invalid resource format" do
      assert {:error, :invalid_resource} = Federation.webfinger("invalid")
    end

    test "returns error for wrong host" do
      assert {:error, :invalid_resource} = Federation.webfinger("acct:alice@wrong.host")
    end

    test "returns error for invalid username characters" do
      host = URI.parse(Federation.base_url()).host
      assert {:error, :invalid_resource} = Federation.webfinger("acct:al ice@#{host}")
    end
  end

  describe "nodeinfo/0" do
    test "returns valid NodeInfo 2.1 structure" do
      info = Federation.nodeinfo()

      assert info["version"] == "2.1"
      assert info["software"]["name"] == "baudrate"
      assert "activitypub" in info["protocols"]
      assert is_integer(info["usage"]["users"]["total"])
      assert is_integer(info["usage"]["localPosts"])
      assert info["metadata"]["nodeName"] == "Test Forum"
    end
  end

  describe "nodeinfo_links/0" do
    test "returns links with nodeinfo 2.1 href" do
      links = Federation.nodeinfo_links()

      assert [%{"rel" => rel, "href" => href}] = links["links"]
      assert rel == "http://nodeinfo.diaspora.software/ns/schema/2.1"
      assert href =~ "/nodeinfo/2.1"
    end
  end

  describe "user_actor/1" do
    test "returns Person JSON-LD" do
      user = setup_user_with_role("user")
      {:ok, user} = KeyStore.ensure_user_keypair(user)

      actor = Federation.user_actor(user)

      assert actor["type"] == "Person"
      assert actor["preferredUsername"] == user.username
      assert actor["id"] =~ "/ap/users/#{user.username}"
      assert actor["inbox"] =~ "/inbox"
      assert actor["outbox"] =~ "/outbox"
      assert actor["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end
  end

  describe "board_actor/1" do
    test "returns Group JSON-LD" do
      board = setup_board("ba-test")
      {:ok, board} = KeyStore.ensure_board_keypair(board)

      actor = Federation.board_actor(board)

      assert actor["type"] == "Group"
      assert actor["preferredUsername"] == board.slug
      assert actor["name"] == board.name
      assert actor["id"] =~ "/ap/boards/#{board.slug}"
      assert actor["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end
  end

  describe "site_actor/0" do
    test "returns Organization JSON-LD" do
      actor = Federation.site_actor()

      assert actor["type"] == "Organization"
      assert actor["name"] == "Test Forum"
      assert actor["id"] =~ "/ap/site"
      assert actor["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end
  end

  describe "article_object/1" do
    test "returns Article JSON-LD" do
      user = setup_user_with_role("user")
      board = setup_board("art-test")
      article = setup_article(user, board)

      obj = Federation.article_object(article)

      assert obj["type"] == "Article"
      assert obj["name"] == article.title
      assert obj["content"] =~ "<p>"
      assert obj["mediaType"] == "text/html"
      assert obj["source"]["content"] == article.body
      assert obj["source"]["mediaType"] == "text/markdown"
      assert obj["attributedTo"] =~ "/ap/users/#{user.username}"
      assert obj["url"] =~ "/articles/#{article.slug}"
      assert length(obj["audience"]) == 1
    end
  end

  describe "user_outbox/1" do
    test "returns root OrderedCollection without page param" do
      user = setup_user_with_role("user")
      board = setup_board("uo-test")
      _article = setup_article(user, board)

      outbox = Federation.user_outbox(user)

      assert outbox["type"] == "OrderedCollection"
      assert outbox["totalItems"] == 1
      assert outbox["first"] =~ "page=1"
      refute outbox["orderedItems"]
    end

    test "returns OrderedCollectionPage with Create activities" do
      user = setup_user_with_role("user")
      board = setup_board("uo-test2")
      _article = setup_article(user, board)

      outbox = Federation.user_outbox(user, %{"page" => "1"})

      assert outbox["type"] == "OrderedCollectionPage"
      [item] = outbox["orderedItems"]
      assert item["type"] == "Create"
      assert item["object"]["type"] == "Article"
    end

    test "returns empty root collection for user with no articles" do
      user = setup_user_with_role("user")
      outbox = Federation.user_outbox(user)

      assert outbox["totalItems"] == 0
      assert outbox["first"] =~ "page=1"
    end
  end

  describe "board_outbox/1" do
    test "returns OrderedCollectionPage with Announce activities" do
      user = setup_user_with_role("user")
      board = setup_board("bo-test")
      _article = setup_article(user, board)

      outbox = Federation.board_outbox(board, %{"page" => "1"})

      assert outbox["type"] == "OrderedCollectionPage"
      [item] = outbox["orderedItems"]
      assert item["type"] == "Announce"
    end
  end

  # --- Test Helpers ---

  defp setup_user_with_role(role_name) do
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "fed_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp setup_board(slug) do
    alias Baudrate.Content.Board

    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "Board #{slug}",
        slug: slug,
        description: "Test board"
      })
      |> Repo.insert()

    board
  end

  defp setup_article(user, board) do
    slug = "test-article-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(
        %{
          title: "Test Article",
          body: "This is a test article body.",
          slug: slug,
          user_id: user.id
        },
        [board.id]
      )

    Repo.preload(article, [:boards, :user])
  end
end
