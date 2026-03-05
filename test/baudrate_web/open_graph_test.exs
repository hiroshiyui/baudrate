defmodule BaudrateWeb.OpenGraphTest do
  use Baudrate.DataCase, async: true

  alias BaudrateWeb.OpenGraph

  describe "article_tags/2" do
    test "includes og:type article and required tags" do
      user = %Baudrate.Setup.User{
        id: 1,
        username: "alice",
        display_name: "Alice",
        avatar_id: nil
      }

      board = %Baudrate.Content.Board{id: 1, name: "General", slug: "general"}

      article = %Baudrate.Content.Article{
        id: 1,
        title: "Test Article",
        slug: "test-article",
        body: "This is the body of the article.",
        inserted_at: ~N[2026-01-01 12:00:00],
        updated_at: ~N[2026-01-01 13:00:00],
        user: user,
        boards: [board],
        remote_actor_id: nil
      }

      tags = OpenGraph.article_tags(article, [])
      tag_map = Map.new(tags)

      assert tag_map["og:type"] == "article"
      assert tag_map["og:title"] == "Test Article"
      assert tag_map["og:site_name"]
      assert String.contains?(tag_map["og:url"], "/articles/test-article")
      assert tag_map["og:image"]
      assert tag_map["article:published_time"]
      assert tag_map["article:section"] == "General"
      assert tag_map["article:author"] == "Alice"
      assert tag_map["twitter:card"] == "summary"
      assert tag_map["twitter:title"] == "Test Article"
    end

    test "uses summary_large_image card when article has images" do
      article = %Baudrate.Content.Article{
        id: 1,
        title: "With Image",
        slug: "with-image",
        body: "Body text.",
        inserted_at: ~N[2026-01-01 12:00:00],
        updated_at: ~N[2026-01-01 13:00:00],
        user: nil,
        boards: [],
        remote_actor_id: nil
      }

      image = %Baudrate.Content.ArticleImage{
        id: 1,
        filename: "abc123.webp"
      }

      tags = OpenGraph.article_tags(article, [image])
      tag_map = Map.new(tags)

      assert tag_map["twitter:card"] == "summary_large_image"
      assert String.contains?(tag_map["og:image"], "/uploads/article_images/abc123.webp")
    end

    test "uses author avatar when no article images" do
      user = %Baudrate.Setup.User{
        id: 1,
        username: "bob",
        display_name: nil,
        avatar_id: "avatar-uuid-123"
      }

      article = %Baudrate.Content.Article{
        id: 1,
        title: "No Images",
        slug: "no-images",
        body: nil,
        inserted_at: ~N[2026-01-01 12:00:00],
        updated_at: ~N[2026-01-01 13:00:00],
        user: user,
        boards: [],
        remote_actor_id: nil
      }

      tags = OpenGraph.article_tags(article, [])
      tag_map = Map.new(tags)

      assert tag_map["twitter:card"] == "summary"
      assert String.contains?(tag_map["og:image"], "/uploads/avatars/avatar-uuid-123/120.webp")
    end

    test "filters out nil content tags" do
      article = %Baudrate.Content.Article{
        id: 1,
        title: "Minimal",
        slug: "minimal",
        body: nil,
        inserted_at: ~N[2026-01-01 12:00:00],
        updated_at: ~N[2026-01-01 13:00:00],
        user: nil,
        boards: [],
        remote_actor_id: nil
      }

      tags = OpenGraph.article_tags(article, [])

      # No nil values in the tags
      assert Enum.all?(tags, fn {_prop, content} -> not is_nil(content) end)
      # Description should be absent when body is nil
      refute Enum.any?(tags, fn {prop, _} -> prop == "og:description" end)
    end
  end

  describe "board_tags/1" do
    test "includes og:type website and board name" do
      board = %Baudrate.Content.Board{
        id: 1,
        name: "Tech",
        slug: "tech",
        description: "Technology discussion"
      }

      tags = OpenGraph.board_tags(board)
      tag_map = Map.new(tags)

      assert tag_map["og:type"] == "website"
      assert tag_map["og:title"] == "Tech"
      assert tag_map["og:description"] == "Technology discussion"
      assert String.contains?(tag_map["og:url"], "/boards/tech")
      assert tag_map["twitter:card"] == "summary"
    end

    test "omits description when nil" do
      board = %Baudrate.Content.Board{
        id: 1,
        name: "Empty",
        slug: "empty",
        description: nil
      }

      tags = OpenGraph.board_tags(board)
      refute Enum.any?(tags, fn {prop, _} -> prop == "og:description" end)
    end
  end

  describe "user_tags/3" do
    test "includes profile type and user stats" do
      user = %Baudrate.Setup.User{
        id: 1,
        username: "carol",
        display_name: "Carol",
        avatar_id: nil
      }

      tags = OpenGraph.user_tags(user, 10, 25)
      tag_map = Map.new(tags)

      assert tag_map["og:type"] == "profile"
      assert tag_map["og:title"] == "Carol"
      assert tag_map["profile:username"] == "carol"
      assert String.contains?(tag_map["og:description"], "10")
      assert String.contains?(tag_map["og:description"], "25")
      assert tag_map["twitter:card"] == "summary"
    end

    test "uses avatar URL when user has avatar" do
      user = %Baudrate.Setup.User{
        id: 1,
        username: "dave",
        display_name: nil,
        avatar_id: "avatar-dave"
      }

      tags = OpenGraph.user_tags(user, 0, 0)
      tag_map = Map.new(tags)

      assert String.contains?(tag_map["og:image"], "/uploads/avatars/avatar-dave/120.webp")
    end
  end

  describe "home_tags/1" do
    test "includes og:type website and site name" do
      tags = OpenGraph.home_tags("My Forum")
      tag_map = Map.new(tags)

      assert tag_map["og:type"] == "website"
      assert tag_map["og:title"] == "My Forum"
      assert tag_map["og:site_name"]
      assert tag_map["og:image"]
      assert tag_map["twitter:card"] == "summary"
    end
  end

  describe "default_tags/1" do
    test "includes basic og and twitter tags" do
      tags = OpenGraph.default_tags("Some Page")
      tag_map = Map.new(tags)

      assert tag_map["og:type"] == "website"
      assert tag_map["og:title"] == "Some Page"
      assert tag_map["og:image"]
      assert tag_map["twitter:card"] == "summary"
    end
  end
end
