defmodule Baudrate.Content.FeedQueriesTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{Board, BoardArticle}
  alias Baudrate.Repo

  setup do
    user = setup_user("user")
    public_board = insert_board("public-feed", min_role_to_view: "guest")
    private_board = insert_board("private-feed", min_role_to_view: "user")
    {:ok, user: user, public_board: public_board, private_board: private_board}
  end

  describe "list_recent_public_articles/1" do
    test "returns local articles in public boards", %{user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "public-article")

      articles = Content.list_recent_public_articles()
      assert length(articles) == 1
      assert hd(articles).id == article.id
    end

    test "excludes articles in private boards only", %{user: user, private_board: board} do
      {:ok, _} = insert_article(user, board, "private-only-article")

      assert Content.list_recent_public_articles() == []
    end

    test "excludes deleted articles", %{user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "deleted-article")
      Content.soft_delete_article(article)

      assert Content.list_recent_public_articles() == []
    end

    test "excludes remote articles", %{public_board: board} do
      insert_remote_article(board, "remote-feed-article")

      assert Content.list_recent_public_articles() == []
    end

    test "deduplicates cross-posted articles", %{user: user, public_board: board} do
      board2 = insert_board("public-feed-2", min_role_to_view: "guest")

      {:ok, %{article: article}} =
        insert_article(user, board, "cross-posted", extra_boards: [board2.id])

      articles = Content.list_recent_public_articles()
      assert length(articles) == 1
      assert hd(articles).id == article.id
    end

    test "respects limit", %{user: user, public_board: board} do
      for i <- 1..5, do: insert_article(user, board, "limited-#{i}")

      assert length(Content.list_recent_public_articles(3)) == 3
    end

    test "preloads user and boards", %{user: user, public_board: board} do
      {:ok, _} = insert_article(user, board, "preloaded-article")

      [article] = Content.list_recent_public_articles()
      assert %Baudrate.Setup.User{} = article.user
      assert [%Board{} | _] = article.boards
    end
  end

  describe "list_recent_articles_for_public_board/2" do
    test "returns articles for a public board", %{user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "board-feed-article")

      assert {:ok, [fetched]} = Content.list_recent_articles_for_public_board(board)
      assert fetched.id == article.id
    end

    test "returns error for private boards", %{private_board: board} do
      assert {:error, :not_public} = Content.list_recent_articles_for_public_board(board)
    end

    test "excludes remote articles", %{public_board: board} do
      insert_remote_article(board, "remote-board-article")

      assert {:ok, []} = Content.list_recent_articles_for_public_board(board)
    end

    test "excludes deleted articles", %{user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "board-deleted")
      Content.soft_delete_article(article)

      assert {:ok, []} = Content.list_recent_articles_for_public_board(board)
    end
  end

  describe "list_recent_public_articles_by_user/2" do
    test "returns user's articles in public boards", %{user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "user-feed-article")

      articles = Content.list_recent_public_articles_by_user(user.id)
      assert length(articles) == 1
      assert hd(articles).id == article.id
    end

    test "excludes articles only in private boards", %{user: user, private_board: board} do
      {:ok, _} = insert_article(user, board, "user-private-article")

      assert Content.list_recent_public_articles_by_user(user.id) == []
    end

    test "excludes other users' articles", %{public_board: board} do
      other_user = setup_user("user")
      {:ok, _} = insert_article(other_user, board, "other-user-article")

      user = setup_user("user")
      assert Content.list_recent_public_articles_by_user(user.id) == []
    end

    test "excludes deleted articles", %{user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "user-deleted")
      Content.soft_delete_article(article)

      assert Content.list_recent_public_articles_by_user(user.id) == []
    end
  end

  describe "list_recent_activity_by_user/2" do
    test "returns both articles and comments", %{user: user, public_board: board} do
      {:ok, %{article: article}} = insert_article(user, board, "activity-art")

      {:ok, _comment} =
        Content.create_comment(%{
          body: "activity comment",
          article_id: article.id,
          user_id: user.id
        })

      result = Content.list_recent_activity_by_user(user.id)
      types = Enum.map(result, fn {type, _} -> type end)
      assert :article in types
      assert :comment in types
    end

    test "sorts by newest first", %{user: user, public_board: board} do
      {:ok, %{article: a1}} = insert_article(user, board, "activity-older")
      {:ok, %{article: a2}} = insert_article(user, board, "activity-newer")

      # Force distinct timestamps
      import Ecto.Query

      Repo.update_all(
        from(a in Baudrate.Content.Article, where: a.id == ^a1.id),
        set: [inserted_at: ~U[2025-01-01 00:00:00Z]]
      )

      result = Content.list_recent_activity_by_user(user.id)
      ids = Enum.map(result, fn {:article, a} -> a.id end)
      assert ids == [a2.id, a1.id]
    end

    test "respects limit", %{user: user, public_board: board} do
      for i <- 1..5, do: insert_article(user, board, "activity-limit-#{i}")

      assert length(Content.list_recent_activity_by_user(user.id, 3)) == 3
    end

    test "returns empty list when user has no activity", %{user: _user} do
      other_user = setup_user("user")
      assert Content.list_recent_activity_by_user(other_user.id) == []
    end
  end

  describe "list_recent_boosted_articles_by_user/2" do
    test "returns articles boosted by the user", %{user: user, public_board: board} do
      other_user = setup_user("user")
      {:ok, %{article: article}} = insert_article(other_user, board, "boosted-by-user")
      {:ok, _boost} = Content.boost_article(user.id, article.id)

      result = Content.list_recent_boosted_articles_by_user(user.id)
      assert length(result) == 1
      [{_boosted_at, boosted_article}] = result
      assert boosted_article.id == article.id
    end

    test "returns empty list when user has no boosts", %{user: user} do
      assert Content.list_recent_boosted_articles_by_user(user.id) == []
    end

    test "excludes soft-deleted articles", %{user: user, public_board: board} do
      other_user = setup_user("user")
      {:ok, %{article: article}} = insert_article(other_user, board, "boosted-deleted")
      {:ok, _boost} = Content.boost_article(user.id, article.id)
      Content.soft_delete_article(article)

      assert Content.list_recent_boosted_articles_by_user(user.id) == []
    end

    test "preloads boards and article_images", %{user: user, public_board: board} do
      other_user = setup_user("user")
      {:ok, %{article: article}} = insert_article(other_user, board, "boosted-preload")
      {:ok, _boost} = Content.boost_article(user.id, article.id)

      [{_boosted_at, boosted_article}] = Content.list_recent_boosted_articles_by_user(user.id)
      assert [%Board{} | _] = boosted_article.boards
      assert is_list(boosted_article.article_images)
    end

    test "respects limit", %{user: user, public_board: board} do
      other_user = setup_user("user")

      for i <- 1..5 do
        {:ok, %{article: article}} = insert_article(other_user, board, "boosted-limit-#{i}")
        {:ok, _boost} = Content.boost_article(user.id, article.id)
      end

      assert length(Content.list_recent_boosted_articles_by_user(user.id, 3)) == 3
    end

    test "orders by boost time, newest first", %{user: user, public_board: board} do
      other_user = setup_user("user")
      {:ok, %{article: a1}} = insert_article(other_user, board, "boost-order-1")
      {:ok, %{article: a2}} = insert_article(other_user, board, "boost-order-2")

      {:ok, _} = Content.boost_article(user.id, a1.id)
      {:ok, _} = Content.boost_article(user.id, a2.id)

      result = Content.list_recent_boosted_articles_by_user(user.id)
      ids = Enum.map(result, fn {_, a} -> a.id end)
      # a2 boosted last, should appear first
      assert ids == [a2.id, a1.id]
    end
  end

  describe "list_recent_boosted_by_user/2" do
    test "returns both boosted articles and comments", %{user: user, public_board: board} do
      other_user = setup_user("user")
      {:ok, %{article: article}} = insert_article(other_user, board, "boosted-mixed-art")

      {:ok, comment} =
        Content.create_comment(%{
          body: "comment to boost",
          article_id: article.id,
          user_id: other_user.id
        })

      {:ok, _} = Content.boost_article(user.id, article.id)
      {:ok, _} = Content.boost_comment(user.id, comment.id)

      result = Content.list_recent_boosted_by_user(user.id)
      types = Enum.map(result, fn {type, _, _} -> type end)
      assert :article in types
      assert :comment in types
    end

    test "returns empty list when no boosts", %{user: user} do
      assert Content.list_recent_boosted_by_user(user.id) == []
    end

    test "excludes soft-deleted content", %{user: user, public_board: board} do
      other_user = setup_user("user")
      {:ok, %{article: article}} = insert_article(other_user, board, "boosted-del")
      {:ok, _} = Content.boost_article(user.id, article.id)
      Content.soft_delete_article(article)

      assert Content.list_recent_boosted_by_user(user.id) == []
    end

    test "respects limit", %{user: user, public_board: board} do
      other_user = setup_user("user")

      for i <- 1..5 do
        {:ok, %{article: article}} = insert_article(other_user, board, "boosted-lim-#{i}")
        {:ok, _} = Content.boost_article(user.id, article.id)
      end

      assert length(Content.list_recent_boosted_by_user(user.id, 3)) == 3
    end
  end

  # --- Helpers ---

  defp setup_user(role_name) do
    import Ecto.Query
    alias Baudrate.Setup
    alias Baudrate.Setup.{Role, User}

    unless Repo.exists?(from(r in Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    role = Repo.one!(from(r in Role, where: r.name == ^role_name))
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        username: "feedtest#{suffix}",
        password: "ValidPassword123!",
        password_confirmation: "ValidPassword123!"
      })
      |> Ecto.Changeset.put_assoc(:role, role)
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp insert_board(slug, opts) do
    {:ok, board} =
      %Board{}
      |> Board.changeset(%{
        name: "Board #{slug}",
        slug: slug,
        description: "Test board",
        min_role_to_view: Keyword.get(opts, :min_role_to_view, "guest"),
        min_role_to_post: Keyword.get(opts, :min_role_to_post, "user")
      })
      |> Repo.insert()

    board
  end

  defp insert_article(user, board, slug, opts \\ []) do
    extra_boards = Keyword.get(opts, :extra_boards, [])

    Content.create_article(
      %{
        title: "Article #{slug}",
        body: "Body for **#{slug}**.",
        slug: slug,
        user_id: user.id
      },
      [board.id | extra_boards]
    )
  end

  defp insert_remote_article(board, slug) do
    alias Baudrate.Content.Article
    alias Baudrate.Federation.RemoteActor

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/actor/#{slug}",
        username: "remote_#{slug}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nMIIBIjANBg==\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/inbox",
        shared_inbox: "https://remote.example/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, article} =
      %Article{}
      |> Article.remote_changeset(%{
        title: "Remote #{slug}",
        body: "Remote body",
        slug: slug,
        ap_id: "https://remote.example/articles/#{slug}",
        remote_actor_id: actor.id
      })
      |> Repo.insert()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%BoardArticle{
      board_id: board.id,
      article_id: article.id,
      inserted_at: now,
      updated_at: now
    })

    article
  end
end
