defmodule Baudrate.Content.MuteFilteringTest do
  use Baudrate.DataCase

  alias Baudrate.{Auth, Content}
  alias Baudrate.Content.Board
  alias Baudrate.Setup
  alias Baudrate.Setup.{Role, User}

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name) do
    role = Repo.one!(from r in Role, where: r.name == ^role_name)

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board(attrs) do
    %Board{}
    |> Board.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_article(user, board, title) do
    slug = Content.generate_slug(title)

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: title, body: "body", slug: slug, user_id: user.id},
        [board.id]
      )

    article
  end

  # --- Article listing filtering ---

  describe "paginate_articles_for_board/2 with mutes" do
    test "filters articles from muted local users" do
      viewer = create_user("user")
      author = create_user("user")

      board =
        create_board(%{
          name: "Mute Board",
          slug: "mute-board-#{System.unique_integer([:positive])}"
        })

      create_article(author, board, "Visible Article")
      create_article(viewer, board, "My Article")

      # Before muting, all visible
      result = Content.paginate_articles_for_board(board, user: viewer)
      assert result.total == 2

      # Mute the author
      {:ok, _} = Auth.mute_user(viewer, author)

      # After muting, muted user's article is hidden
      result = Content.paginate_articles_for_board(board, user: viewer)
      assert result.total == 1
      assert hd(result.articles).title == "My Article"
    end

    test "guests see all articles (no filtering)" do
      author = create_user("user")

      board =
        create_board(%{
          name: "Guest Board",
          slug: "guest-board-#{System.unique_integer([:positive])}"
        })

      create_article(author, board, "Visible to Guests")

      result = Content.paginate_articles_for_board(board, user: nil)
      assert result.total == 1
    end
  end

  # --- SysOp board exemption ---

  describe "SysOp board exemption" do
    test "admin articles in SysOp board are visible even when admin is muted" do
      viewer = create_user("user")
      admin = create_user("admin")
      sysop_board = create_board(%{name: "SysOp", slug: "sysop", position: 0})

      create_article(admin, sysop_board, "System Announcement")

      # Mute the admin
      {:ok, _} = Auth.mute_user(viewer, admin)

      # Admin articles in SysOp board should still be visible
      result = Content.paginate_articles_for_board(sysop_board, user: viewer)
      assert result.total == 1
      assert hd(result.articles).title == "System Announcement"
    end

    test "non-admin articles in SysOp board are still filtered when muted" do
      viewer = create_user("user")
      regular_user = create_user("user")
      sysop_board = create_board(%{name: "SysOp", slug: "sysop", position: 0})

      create_article(regular_user, sysop_board, "Regular Post in SysOp")

      # Mute the regular user
      {:ok, _} = Auth.mute_user(viewer, regular_user)

      # Regular user's article in SysOp board should be filtered
      result = Content.paginate_articles_for_board(sysop_board, user: viewer)
      assert result.total == 0
    end

    test "admin articles in non-SysOp boards are filtered when admin is muted" do
      viewer = create_user("user")
      admin = create_user("admin")

      regular_board =
        create_board(%{name: "General", slug: "general-#{System.unique_integer([:positive])}"})

      create_article(admin, regular_board, "Admin Post")

      # Mute the admin
      {:ok, _} = Auth.mute_user(viewer, admin)

      # Admin articles in non-SysOp boards should be filtered
      result = Content.paginate_articles_for_board(regular_board, user: viewer)
      assert result.total == 0
    end
  end

  # --- Search filtering ---

  describe "search_articles/2 with mutes" do
    test "filters muted users' articles from search results" do
      viewer = create_user("user")
      author = create_user("user")

      board =
        create_board(%{
          name: "Search Mute",
          slug: "search-mute-#{System.unique_integer([:positive])}",
          min_role_to_view: "guest"
        })

      create_article(author, board, "Muted Author Post searchmute")
      create_article(viewer, board, "My Own Post searchmute")

      # Mute the author
      {:ok, _} = Auth.mute_user(viewer, author)

      result = Content.search_articles("searchmute", user: viewer)
      titles = Enum.map(result.articles, & &1.title)
      assert "My Own Post searchmute" in titles
      refute "Muted Author Post searchmute" in titles
    end
  end

  describe "search_comments/2 with mutes" do
    test "filters muted users' comments from search results" do
      viewer = create_user("user")
      author = create_user("user")

      board =
        create_board(%{
          name: "Cmt Mute",
          slug: "cmt-mute-#{System.unique_integer([:positive])}",
          min_role_to_view: "guest"
        })

      article = create_article(viewer, board, "Article with Comments")

      {:ok, _} =
        Content.create_comment(%{
          "body" => "visible muted_comment_test",
          "article_id" => article.id,
          "user_id" => viewer.id
        })

      {:ok, _} =
        Content.create_comment(%{
          "body" => "hidden muted_comment_test",
          "article_id" => article.id,
          "user_id" => author.id
        })

      # Mute the author
      {:ok, _} = Auth.mute_user(viewer, author)

      result = Content.search_comments("muted_comment_test", user: viewer)
      assert result.total == 1
      assert hd(result.comments).body =~ "visible"
    end
  end

  # --- Comment listing filtering ---

  describe "list_comments_for_article/2 with mutes" do
    test "filters comments from muted local users" do
      viewer = create_user("user")
      author = create_user("user")

      board =
        create_board(%{
          name: "Cmt List Mute",
          slug: "cmt-list-mute-#{System.unique_integer([:positive])}"
        })

      article = create_article(viewer, board, "Article for Comment Muting")

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Visible comment",
          "article_id" => article.id,
          "user_id" => viewer.id
        })

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Hidden comment",
          "article_id" => article.id,
          "user_id" => author.id
        })

      # Mute the author
      {:ok, _} = Auth.mute_user(viewer, author)

      comments = Content.list_comments_for_article(article, viewer)
      assert length(comments) == 1
      assert hd(comments).body == "Visible comment"
    end
  end
end
