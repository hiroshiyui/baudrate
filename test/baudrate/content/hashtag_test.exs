defmodule Baudrate.Content.HashtagTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{ArticleTag, Board}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name \\ "user") do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "ht_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board(attrs \\ %{}) do
    defaults = %{
      name: "Board #{System.unique_integer([:positive])}",
      slug: "ht-board-#{System.unique_integer([:positive])}",
      min_role_to_view: "guest"
    }

    %Board{}
    |> Board.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp create_article(user, board, attrs) do
    defaults = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Body",
      slug: "ht-art-#{System.unique_integer([:positive])}",
      user_id: user.id
    }

    {:ok, %{article: article}} =
      Content.create_article(Map.merge(defaults, attrs), [board.id])

    article
  end

  # --- extract_tags/1 ---

  describe "extract_tags/1" do
    test "extracts basic hashtags" do
      assert Content.extract_tags("Hello #elixir and #phoenix") == ["elixir", "phoenix"]
    end

    test "extracts CJK hashtags" do
      tags = Content.extract_tags("Check out #台灣 and #エリクサー")
      assert "台灣" in tags
      assert "エリクサー" in tags
    end

    test "excludes tags inside inline code" do
      assert Content.extract_tags("Use `#not_a_tag` here") == []
    end

    test "excludes tags inside fenced code blocks" do
      text = """
      ```
      #code_tag
      ```
      #real_tag
      """

      assert Content.extract_tags(text) == ["real_tag"]
    end

    test "deduplicates tags" do
      assert Content.extract_tags("#elixir #elixir #elixir") == ["elixir"]
    end

    test "normalizes tags to lowercase" do
      assert Content.extract_tags("#Elixir #PHOENIX") == ["elixir", "phoenix"]
    end

    test "returns empty list for nil" do
      assert Content.extract_tags(nil) == []
    end

    test "returns empty list for empty string" do
      assert Content.extract_tags("") == []
    end

    test "ignores markdown headings (# Heading)" do
      assert Content.extract_tags("# Heading\n#tag") == ["tag"]
    end
  end

  # --- sync_article_tags/1 ---

  describe "sync_article_tags/1" do
    test "creates tags from article body" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{body: "Hello #elixir and #phoenix"})

      assert :ok = Content.sync_article_tags(article)

      tags =
        from(at in ArticleTag,
          where: at.article_id == ^article.id,
          select: at.tag,
          order_by: at.tag
        )
        |> Repo.all()

      assert tags == ["elixir", "phoenix"]
    end

    test "updates tags on edit — adds new and removes old" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{body: "Hello #elixir and #phoenix"})

      Content.sync_article_tags(article)

      # Simulate an edit: body now has #elixir and #otp (phoenix removed, otp added)
      updated_article = %{article | body: "Hello #elixir and #otp"}
      Content.sync_article_tags(updated_article)

      tags =
        from(at in ArticleTag,
          where: at.article_id == ^article.id,
          select: at.tag,
          order_by: at.tag
        )
        |> Repo.all()

      assert tags == ["elixir", "otp"]
    end

    test "removes all tags when body has no hashtags" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{body: "Hello #elixir"})

      Content.sync_article_tags(article)
      assert Repo.exists?(from(at in ArticleTag, where: at.article_id == ^article.id))

      updated_article = %{article | body: "No tags here"}
      Content.sync_article_tags(updated_article)

      refute Repo.exists?(from(at in ArticleTag, where: at.article_id == ^article.id))
    end
  end

  # --- articles_by_tag/2 ---

  describe "articles_by_tag/2" do
    test "returns articles matching the tag" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{body: "Check out #elixir"})
      Content.sync_article_tags(article)

      _other = create_article(user, board, %{body: "No relevant tags here"})

      result = Content.articles_by_tag("elixir")
      article_ids = Enum.map(result.articles, & &1.id)

      assert article.id in article_ids
      assert result.total == 1
    end

    test "respects board visibility — guest cannot see user-only board articles" do
      user = create_user()
      public_board = create_board(%{min_role_to_view: "guest"})
      private_board = create_board(%{min_role_to_view: "user"})

      pub_article = create_article(user, public_board, %{body: "Public #visibility"})
      priv_article = create_article(user, private_board, %{body: "Private #visibility"})

      Content.sync_article_tags(pub_article)
      Content.sync_article_tags(priv_article)

      # Guest (user: nil) should only see the public article
      result = Content.articles_by_tag("visibility", user: nil)
      article_ids = Enum.map(result.articles, & &1.id)

      assert pub_article.id in article_ids
      refute priv_article.id in article_ids
    end

    test "excludes soft-deleted articles" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{body: "Will be deleted #softdelete"})
      Content.sync_article_tags(article)

      Content.soft_delete_article(article)

      result = Content.articles_by_tag("softdelete")
      assert result.articles == []
      assert result.total == 0
    end

    test "returns empty results when no articles match" do
      result = Content.articles_by_tag("nonexistenttag")
      assert result.articles == []
      assert result.total == 0
    end
  end

  # --- search_tags/2 ---

  describe "search_tags/2" do
    test "returns tags matching a prefix" do
      user = create_user()
      board = create_board()

      a1 = create_article(user, board, %{body: "#elixir is great"})
      a2 = create_article(user, board, %{body: "#erlang is also great"})
      a3 = create_article(user, board, %{body: "#phoenix framework"})

      Content.sync_article_tags(a1)
      Content.sync_article_tags(a2)
      Content.sync_article_tags(a3)

      results = Content.search_tags("eli")
      assert results == ["elixir"]
    end

    test "returns tags sorted alphabetically" do
      user = create_user()
      board = create_board()

      a1 = create_article(user, board, %{body: "#phoenix #elixir #erlang"})
      Content.sync_article_tags(a1)

      results = Content.search_tags("e")
      assert results == ["elixir", "erlang"]
    end

    test "respects limit option" do
      user = create_user()
      board = create_board()

      tags = for i <- 1..5, do: "#tag#{i}"
      a = create_article(user, board, %{body: Enum.join(tags, " ")})
      Content.sync_article_tags(a)

      results = Content.search_tags("tag", limit: 3)
      assert length(results) == 3
    end

    test "returns empty list when no tags match" do
      assert Content.search_tags("zzz") == []
    end
  end
end
