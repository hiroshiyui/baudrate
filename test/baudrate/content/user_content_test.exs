defmodule Baudrate.Content.UserContentTest do
  use Baudrate.DataCase

  alias Baudrate.Content

  setup do
    user = setup_user("user")

    {:ok, board} =
      Content.create_board(%{name: "Test", slug: "test-#{System.unique_integer([:positive])}"})

    {:ok, user: user, board: board}
  end

  describe "list_recent_articles_by_user/2" do
    test "returns recent articles by user", %{user: user, board: board} do
      {:ok, %{article: _}} =
        Content.create_article(
          %{
            "title" => "Article 1",
            "body" => "Body",
            "slug" => "a1-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      articles = Content.list_recent_articles_by_user(user.id)
      assert length(articles) == 1
      assert hd(articles).title == "Article 1"
    end

    test "excludes deleted articles", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Deleted",
            "body" => "Body",
            "slug" => "del-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      Content.soft_delete_article(article, deleted_by: article.user_id)
      articles = Content.list_recent_articles_by_user(user.id)
      assert articles == []
    end
  end

  describe "count_articles_by_user/1" do
    test "counts non-deleted articles", %{user: user, board: board} do
      {:ok, _} =
        Content.create_article(
          %{
            "title" => "A1",
            "body" => "Body",
            "slug" => "ca1-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      assert Content.count_articles_by_user(user.id) == 1
    end
  end

  describe "count_comments_by_user/1" do
    test "counts non-deleted comments", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Art",
            "body" => "Body",
            "slug" => "cc-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      assert Content.count_comments_by_user(user.id) == 1
    end
  end

  describe "count_user_content_stats/1" do
    test "returns {0, 0} for user with no content", %{user: _user} do
      other = setup_user("user")
      assert {0, 0} = Content.count_user_content_stats(other.id)
    end

    test "counts articles and comments together", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Stats Art",
            "body" => "Body",
            "slug" => "stats-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Stats Comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      assert {1, 1} = Content.count_user_content_stats(user.id)
    end

    test "excludes soft-deleted articles and comments", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Del Art",
            "body" => "Body",
            "slug" => "sdel-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "Del Comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      Content.soft_delete_article(article, deleted_by: article.user_id)
      Content.soft_delete_comment(comment, deleted_by: comment.user_id)

      assert {0, 0} = Content.count_user_content_stats(user.id)
    end
  end

  describe "paginate_articles_by_user/2" do
    # Regression: `distinct: a.id` became `DISTINCT ON (a.id)`, which led the
    # ORDER BY and listed the profile's articles oldest first.
    test "lists newest first, a cross-posted article once", %{user: user, board: board} do
      {:ok, other_board} =
        Content.create_board(%{name: "Other", slug: "o-#{System.unique_integer([:positive])}"})

      [old, mid, new] =
        for {n, boards} <- [{1, [board.id]}, {2, [board.id, other_board.id]}, {3, [board.id]}] do
          {:ok, %{article: article}} =
            Content.create_article(
              %{
                "title" => "Ordered #{n}",
                "body" => "Body",
                "slug" => "ord-#{n}-#{System.unique_integer([:positive])}",
                "user_id" => user.id
              },
              boards
            )

          article
        end

      backdate(Baudrate.Content.Article, old.id, 3)
      backdate(Baudrate.Content.Article, mid.id, 2)
      backdate(Baudrate.Content.Article, new.id, 1)

      result = Content.paginate_articles_by_user(user.id, page: 1)
      assert Enum.map(result.articles, & &1.id) == [new.id, mid.id, old.id]
      assert result.total == 3
    end

    test "returns paginated articles by user", %{user: user, board: board} do
      {:ok, %{article: _}} =
        Content.create_article(
          %{
            "title" => "Paginated Article",
            "body" => "Body",
            "slug" => "pa-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      result = Content.paginate_articles_by_user(user.id, page: 1)
      assert length(result.articles) == 1
      assert hd(result.articles).title == "Paginated Article"
      assert result.page == 1
      assert result.total_pages == 1
      assert result.total == 1
    end

    test "excludes deleted articles", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "To Delete",
            "body" => "Body",
            "slug" => "pad-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      Content.soft_delete_article(article, deleted_by: article.user_id)
      result = Content.paginate_articles_by_user(user.id, page: 1)
      assert result.articles == []
      assert result.total == 0
    end

    test "preloads user and boards", %{user: user, board: board} do
      {:ok, _} =
        Content.create_article(
          %{
            "title" => "Preload Test",
            "body" => "Body",
            "slug" => "pap-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      result = Content.paginate_articles_by_user(user.id, page: 1)
      article = hd(result.articles)
      assert %Baudrate.Setup.User{} = article.user
      assert [%Baudrate.Content.Board{}] = article.boards
    end
  end

  describe "paginate_comments_by_user/2" do
    test "lists newest first", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Art",
            "body" => "Body",
            "slug" => "pco-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      [old, new] =
        for n <- 1..2 do
          {:ok, comment} =
            Content.create_comment(%{
              "body" => "Comment #{n}",
              "article_id" => article.id,
              "user_id" => user.id
            })

          comment
        end

      backdate(Baudrate.Content.Comment, old.id, 2)
      backdate(Baudrate.Content.Comment, new.id, 1)

      result = Content.paginate_comments_by_user(user.id, page: 1)
      assert Enum.map(result.comments, & &1.id) == [new.id, old.id]
    end

    test "returns paginated comments by user", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Art",
            "body" => "Body",
            "slug" => "pc-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Paginated Comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      result = Content.paginate_comments_by_user(user.id, page: 1)
      assert length(result.comments) == 1
      assert hd(result.comments).body == "Paginated Comment"
      assert result.page == 1
      assert result.total_pages == 1
      assert result.total == 1
    end

    test "excludes deleted comments", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Art",
            "body" => "Body",
            "slug" => "pcd-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, comment} =
        Content.create_comment(%{
          "body" => "To Delete",
          "article_id" => article.id,
          "user_id" => user.id
        })

      Content.soft_delete_comment(comment, deleted_by: comment.user_id)
      result = Content.paginate_comments_by_user(user.id, page: 1)
      assert result.comments == []
      assert result.total == 0
    end

    test "preloads user and article with boards", %{user: user, board: board} do
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            "title" => "Preload Art",
            "body" => "Body",
            "slug" => "pcp-#{System.unique_integer([:positive])}",
            "user_id" => user.id
          },
          [board.id]
        )

      {:ok, _} =
        Content.create_comment(%{
          "body" => "Preload Comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      result = Content.paginate_comments_by_user(user.id, page: 1)
      comment = hd(result.comments)
      assert %Baudrate.Setup.User{} = comment.user
      assert %Baudrate.Content.Article{} = comment.article
      assert [%Baudrate.Content.Board{}] = comment.article.boards
    end
  end

  defp backdate(schema, id, hours) do
    at = DateTime.add(DateTime.utc_now(:second), -hours * 3600)
    Repo.update_all(from(r in schema, where: r.id == ^id), set: [inserted_at: at])
  end

  defp setup_user(role_name) do
    import Ecto.Query
    alias Baudrate.Repo
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "test_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end
end
