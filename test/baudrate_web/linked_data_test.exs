defmodule BaudrateWeb.LinkedDataTest do
  use Baudrate.DataCase

  alias BaudrateWeb.LinkedData
  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  defp setup_roles do
    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end
  end

  defp create_user(username \\ "testuser") do
    setup_roles()
    role = Repo.one!(from(r in Role, where: r.name == "user"))

    %User{}
    |> User.registration_changeset(%{
      username: username <> "#{System.unique_integer([:positive])}",
      password: "ValidPassword123!",
      role_id: role.id
    })
    |> Repo.insert!()
    |> Repo.preload(:role)
  end

  describe "site_jsonld/1" do
    test "returns sioc:Site with correct structure" do
      result = LinkedData.site_jsonld("Test BBS")

      assert result["@type"] == "sioc:Site"
      assert result["sioc:name"] == "Test BBS"
      assert result["foaf:name"] == "Test BBS"
      assert result["@context"]["sioc"] == "http://rdfs.org/sioc/ns#"
      assert result["@context"]["foaf"] == "http://xmlns.com/foaf/0.1/"
      assert result["@context"]["dc"] == "http://purl.org/dc/elements/1.1/"
      assert result["@context"]["dcterms"] == "http://purl.org/dc/terms/"
      assert String.ends_with?(result["@id"], "/")
      assert String.ends_with?(result["foaf:homepage"], "/")
    end

    test "falls back to Baudrate when site_name is nil" do
      result = LinkedData.site_jsonld(nil)
      assert result["sioc:name"] == "Baudrate"
    end
  end

  describe "board_jsonld/2" do
    test "returns sioc:Forum with correct structure" do
      board = %Board{name: "General", slug: "general", description: "Main board"}
      result = LinkedData.board_jsonld(board)

      assert result["@type"] == "sioc:Forum"
      assert result["sioc:name"] == "General"
      assert result["dc:title"] == "General"
      assert result["dc:description"] == "Main board"
      assert String.ends_with?(result["@id"], "/boards/general")
      assert result["sioc:has_host"]["@id"] =~ ~r{/$}
      refute Map.has_key?(result, "sioc:has_parent")
    end

    test "includes parent when parent_slug provided" do
      board = %Board{name: "Sub", slug: "sub"}
      result = LinkedData.board_jsonld(board, parent_slug: "general")

      assert result["sioc:has_parent"]["@id"] =~ "/boards/general"
    end

    test "omits description when nil" do
      board = %Board{name: "Empty", slug: "empty", description: nil}
      result = LinkedData.board_jsonld(board)

      refute Map.has_key?(result, "dc:description")
    end

    test "omits description when empty string" do
      board = %Board{name: "Empty", slug: "empty", description: ""}
      result = LinkedData.board_jsonld(board)

      refute Map.has_key?(result, "dc:description")
    end
  end

  describe "article_jsonld/1" do
    test "returns sioc:Post with correct structure" do
      user = create_user()

      board =
        %Board{}
        |> Board.changeset(%{
          name: "General",
          slug: "general-ld-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Test Article",
            body: "Hello world content here",
            slug: "ld-test-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      article = Repo.preload(article, [:user, :boards])
      result = LinkedData.article_jsonld(article)

      assert result["@type"] == "sioc:Post"
      assert result["dc:title"] == "Test Article"
      assert result["dc:creator"] == user.username
      assert result["sioc:num_replies"] == 0
      assert result["dcterms:created"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
      assert result["dcterms:modified"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
      assert String.ends_with?(result["@id"], "/articles/" <> article.slug)

      assert result["sioc:has_creator"]["@type"] == "foaf:Person"
      assert result["sioc:has_creator"]["foaf:nick"] == user.username

      assert is_list(result["sioc:has_container"])
      assert length(result["sioc:has_container"]) == 1

      assert result["dc:description"] =~ "Hello world"
    end

    test "includes correct comment count" do
      user = create_user()
      commenter = create_user("commenter")

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Board",
          slug: "board-ld-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "With Comments",
            body: "Body",
            slug: "ld-comments-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      for _ <- 1..3 do
        Content.create_comment(%{
          "body" => "A comment",
          "article_id" => article.id,
          "user_id" => commenter.id
        })
      end

      article = Repo.preload(article, [:user, :boards])
      result = LinkedData.article_jsonld(article)
      assert result["sioc:num_replies"] == 3
    end

    test "omits creator when user is nil" do
      user = create_user()

      board =
        %Board{}
        |> Board.changeset(%{name: "B", slug: "b-ld-#{System.unique_integer([:positive])}"})
        |> Repo.insert!()

      {:ok, %{article: real_article}} =
        Content.create_article(
          %{
            title: "No Author Display",
            body: "body",
            slug: "ld-noauth-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      # Simulate nil user on article
      article_no_user = %{Repo.preload(real_article, [:boards]) | user: nil}
      result = LinkedData.article_jsonld(article_no_user)

      refute Map.has_key?(result, "sioc:has_creator")
      refute Map.has_key?(result, "dc:creator")
    end
  end

  describe "user_jsonld/1" do
    test "returns foaf:Person + sioc:UserAccount" do
      user = create_user()
      result = LinkedData.user_jsonld(user)

      assert result["@type"] == ["foaf:Person", "sioc:UserAccount"]
      assert result["foaf:name"] == user.username
      assert result["foaf:nick"] == user.username
      assert String.ends_with?(result["@id"], "/users/#{user.username}")
      assert String.ends_with?(result["foaf:homepage"], "/users/#{user.username}")
      refute Map.has_key?(result, "foaf:depiction")
    end

    test "uses display_name when set" do
      user = create_user()
      user = %{user | display_name: "Cool User"}
      result = LinkedData.user_jsonld(user)

      assert result["foaf:name"] == "Cool User"
      assert result["foaf:nick"] == user.username
    end

    test "includes avatar depiction when avatar_id is set" do
      user = create_user()
      user = %{user | avatar_id: "abc123"}
      result = LinkedData.user_jsonld(user)

      assert result["foaf:depiction"] =~ "/uploads/avatars/abc123/"
    end

    test "omits depiction when no avatar" do
      user = create_user()
      result = LinkedData.user_jsonld(user)

      refute Map.has_key?(result, "foaf:depiction")
    end
  end

  describe "dublin_core_meta/2" do
    test "returns DC.title for board" do
      board = %Board{name: "General", slug: "general", description: "A board"}
      meta = LinkedData.dublin_core_meta(:board, board)

      assert {"DC.title", "General"} in meta
      assert {"DC.description", "A board"} in meta
    end

    test "omits DC.description for board without description" do
      board = %Board{name: "Bare", slug: "bare", description: nil}
      meta = LinkedData.dublin_core_meta(:board, board)

      assert meta == [{"DC.title", "Bare"}]
    end

    test "returns correct meta for article" do
      user = create_user()

      board =
        %Board{}
        |> Board.changeset(%{name: "B", slug: "b-dc-#{System.unique_integer([:positive])}"})
        |> Repo.insert!()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "DC Article",
            body: "Some body text",
            slug: "dc-test-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      article = Repo.preload(article, [:user, :boards])
      meta = LinkedData.dublin_core_meta(:article, article)

      assert {"DC.title", "DC Article"} in meta
      assert {"DC.type", "Text"} in meta
      assert {"DC.creator", user.username} in meta
      assert Enum.any?(meta, fn {k, _} -> k == "DC.date" end)
      assert Enum.any?(meta, fn {k, _} -> k == "DC.description" end)
    end

    test "returns DC.title for user" do
      user = create_user()
      meta = LinkedData.dublin_core_meta(:user, user)

      assert meta == [{"DC.title", user.username}]
    end
  end

  describe "encode_jsonld/1" do
    test "produces valid JSON" do
      data = LinkedData.site_jsonld("Test")
      json = LinkedData.encode_jsonld(data)

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["@type"] == "sioc:Site"
    end

    test "escapes </script> sequences" do
      data = %{"content" => "Hello </script> world"}
      json = LinkedData.encode_jsonld(data)

      refute json =~ "</script>"
      assert json =~ "<\\/script>"
    end
  end
end
