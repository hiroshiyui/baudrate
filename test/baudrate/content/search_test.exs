defmodule Baudrate.Content.SearchTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Setup

  import Ecto.Query

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name \\ "user") do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "search_#{role_name}_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    %Board{}
    |> Board.changeset(
      Map.merge(
        %{
          name: "Board #{unique}",
          slug: "board-#{unique}",
          min_role_to_view: "guest",
          min_role_to_post: "user"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp create_article(user, board, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, %{article: article}} =
      Content.create_article(
        Map.merge(
          %{
            title: "Article #{unique}",
            body: "Body #{unique}",
            slug: "article-#{unique}",
            user_id: user.id
          },
          attrs
        ),
        [board.id]
      )

    article
  end

  defp create_comment(user, article, body) do
    {:ok, comment} =
      Content.create_comment(%{body: body, article_id: article.id, user_id: user.id})

    comment
  end

  describe "search_boards/2" do
    test "finds boards matching name" do
      user = create_user()
      board = create_board(%{name: "Elixir Discussion"})

      results = Content.search_boards("Elixir", user)
      assert Enum.any?(results, &(&1.id == board.id))
    end

    test "finds boards matching slug" do
      user = create_user()
      board = create_board(%{slug: "phoenix-forum"})

      results = Content.search_boards("phoenix", user)
      assert Enum.any?(results, &(&1.id == board.id))
    end

    test "returns empty list when no match" do
      user = create_user()
      _board = create_board(%{name: "General", slug: "general"})

      results = Content.search_boards("nonexistent_xyz", user)
      assert results == []
    end

    test "filters out boards the user cannot post in" do
      guest = create_user("guest")
      _board = create_board(%{name: "Mod Only Post", min_role_to_post: "moderator"})

      results = Content.search_boards("Mod Only", guest)
      assert results == []
    end

    test "admin can find boards with higher post requirements" do
      admin = create_user("admin")
      board = create_board(%{name: "Admin Posting", min_role_to_post: "admin"})

      results = Content.search_boards("Admin Posting", admin)
      assert Enum.any?(results, &(&1.id == board.id))
    end
  end

  describe "search_visible_boards/2" do
    test "finds boards matching name" do
      board = create_board(%{name: "Visible Board XYZ"})

      result = Content.search_visible_boards("Visible Board XYZ")
      assert Enum.any?(result.boards, &(&1.id == board.id))
      assert result.total >= 1
    end

    test "finds boards matching description" do
      board = create_board(%{name: "Some Board"})

      board
      |> Ecto.Changeset.change(description: "A unique description for testing search")
      |> Repo.update!()

      result = Content.search_visible_boards("unique description")
      assert Enum.any?(result.boards, &(&1.id == board.id))
    end

    test "returns paginated result structure" do
      result = Content.search_visible_boards("anything", page: 1, per_page: 5)

      assert Map.has_key?(result, :boards)
      assert Map.has_key?(result, :total)
      assert Map.has_key?(result, :page)
      assert Map.has_key?(result, :per_page)
      assert Map.has_key?(result, :total_pages)
      assert result.page == 1
      assert result.per_page == 5
    end

    test "guest cannot see boards with higher view requirements" do
      _board =
        create_board(%{name: "Secret Mod Board", min_role_to_view: "moderator"})

      result = Content.search_visible_boards("Secret Mod Board", user: nil)
      refute Enum.any?(result.boards, &(&1.name == "Secret Mod Board"))
    end

    test "authenticated user can see user-level boards" do
      user = create_user()
      board = create_board(%{name: "User Only Visible", min_role_to_view: "user"})

      result = Content.search_visible_boards("User Only Visible", user: user)
      assert Enum.any?(result.boards, &(&1.id == board.id))
    end
  end

  describe "search_articles/2" do
    test "finds articles by English full-text search" do
      user = create_user()
      board = create_board()

      article =
        create_article(user, board, %{title: "Phoenix framework guide", body: "Learn Phoenix"})

      result = Content.search_articles("Phoenix framework", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "finds articles by CJK ILIKE search" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "台灣科技論壇", body: "討論科技話題"})

      result = Content.search_articles("科技", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "returns empty for no match" do
      user = create_user()
      board = create_board()
      _article = create_article(user, board, %{title: "Test", body: "Content"})

      result = Content.search_articles("zzz_nonexistent_zzz", user: user)
      assert result.articles == []
      assert result.total == 0
    end

    test "excludes soft-deleted articles" do
      user = create_user()
      board = create_board()

      article =
        create_article(user, board, %{
          title: "Deletable post about Erlang",
          body: "Erlang content"
        })

      Content.soft_delete_article(article, deleted_by: article.user_id)

      result = Content.search_articles("Erlang", user: user)
      refute Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "respects board visibility for guests" do
      user = create_user()
      restricted_board = create_board(%{min_role_to_view: "moderator"})

      article =
        create_article(user, restricted_board, %{
          title: "Hidden moderator content",
          body: "Secret stuff"
        })

      result = Content.search_articles("moderator content", user: nil)
      refute Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "returns paginated result structure" do
      result = Content.search_articles("test", user: nil, page: 1, per_page: 10)

      assert Map.has_key?(result, :articles)
      assert Map.has_key?(result, :total)
      assert Map.has_key?(result, :page)
      assert Map.has_key?(result, :per_page)
      assert Map.has_key?(result, :total_pages)
    end

    test "author: operator filters by username" do
      user = create_user()
      board = create_board()

      article =
        create_article(user, board, %{title: "Author filtered post", body: "Content here"})

      other_user = create_user()

      _other_article =
        create_article(other_user, board, %{title: "Other author post", body: "Other content"})

      result = Content.search_articles("author:#{user.username}", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))
      refute Enum.any?(result.articles, &(&1.user_id == other_user.id))
    end

    test "board: operator filters by board slug" do
      user = create_user()
      board_a = create_board(%{slug: "board-alpha-#{System.unique_integer([:positive])}"})
      board_b = create_board(%{slug: "board-beta-#{System.unique_integer([:positive])}"})
      article_a = create_article(user, board_a)
      _article_b = create_article(user, board_b)

      result = Content.search_articles("board:#{board_a.slug}", user: user)
      assert Enum.any?(result.articles, &(&1.id == article_a.id))
    end

    test "tag: operator filters by tag" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Tagged post", body: "Has #elixir tag"})

      Content.sync_article_tags(article)

      result = Content.search_articles("tag:elixir", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "before: operator filters articles before a date" do
      user = create_user()
      board = create_board()

      article =
        create_article(user, board, %{title: "Old article about Haskell", body: "Haskell content"})

      # Set article inserted_at to a past date
      past_date = ~U[2025-01-01 00:00:00Z]

      from(a in Content.Article, where: a.id == ^article.id)
      |> Repo.update_all(set: [inserted_at: past_date])

      # A date on its own is not a scope (see "a search needs a scope"), so
      # the board names what is being searched and the date is the only thing
      # that differs between the two calls.
      result = Content.search_articles("board:#{board.slug} before:2025-06-01", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))

      result = Content.search_articles("board:#{board.slug} before:2024-12-31", user: user)
      refute Enum.any?(result.articles, &(&1.id == article.id))
    end

    test "after: operator filters articles after a date" do
      user = create_user()
      board = create_board()

      article =
        create_article(user, board, %{title: "Recent article about Rust", body: "Rust content"})

      future_date = ~U[2026-06-01 00:00:00Z]

      from(a in Content.Article, where: a.id == ^article.id)
      |> Repo.update_all(set: [inserted_at: future_date])

      result = Content.search_articles("board:#{board.slug} after:2026-05-01", user: user)
      assert Enum.any?(result.articles, &(&1.id == article.id))

      result = Content.search_articles("board:#{board.slug} after:2026-07-01", user: user)
      refute Enum.any?(result.articles, &(&1.id == article.id))
    end
  end

  describe "search_comments/2" do
    test "finds comments matching body text" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      comment = create_comment(user, article, "This is a unique comment about testing")

      result = Content.search_comments("unique comment", user: user)
      assert Enum.any?(result.comments, &(&1.id == comment.id))
    end

    test "returns empty for no match" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      _comment = create_comment(user, article, "Normal comment")

      result = Content.search_comments("zzz_nonexistent_zzz", user: user)
      assert result.comments == []
      assert result.total == 0
    end

    test "returns paginated result structure" do
      result = Content.search_comments("test", user: nil, page: 1, per_page: 10)

      assert Map.has_key?(result, :comments)
      assert Map.has_key?(result, :total)
      assert Map.has_key?(result, :page)
      assert Map.has_key?(result, :per_page)
      assert Map.has_key?(result, :total_pages)
    end

    test "respects board visibility" do
      user = create_user()
      restricted_board = create_board(%{min_role_to_view: "admin"})
      article = create_article(user, restricted_board)
      _comment = create_comment(user, article, "Hidden admin comment content")

      result = Content.search_comments("admin comment content", user: nil)
      assert result.comments == []
    end

    test "excludes comments on soft-deleted articles" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      _comment = create_comment(user, article, "Comment on deleted article xyz")

      Content.soft_delete_article(article, deleted_by: article.user_id)

      result = Content.search_comments("deleted article xyz", user: user)
      assert result.comments == []
    end

    test "excludes soft-deleted comments" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      comment = create_comment(user, article, "Soon to be deleted comment abc")

      Content.soft_delete_comment(comment, deleted_by: comment.user_id)

      result = Content.search_comments("deleted comment abc", user: user)
      assert result.comments == []
    end
  end

  describe "search_articles/2 ordering" do
    defp stamp(article, %DateTime{} = at) do
      from(a in Content.Article, where: a.id == ^article.id)
      |> Repo.update_all(set: [inserted_at: at])

      article
    end

    test "relevance puts a title match above a body-only match, even when the body one is newer" do
      user = create_user()
      board = create_board()

      in_body =
        create_article(user, board, %{title: "Something else", body: "a note about kestrels"})
        |> stamp(~U[2026-03-01 00:00:00Z])

      in_title =
        create_article(user, board, %{title: "Kestrels", body: "unrelated"})
        |> stamp(~U[2026-01-01 00:00:00Z])

      result = Content.search_articles("kestrels", user: user, sort: :relevance)
      assert Enum.map(result.articles, & &1.id) == [in_title.id, in_body.id]

      # ...and the same query by date puts them the other way round, which is
      # what proves the ranking is doing the work rather than the timestamps.
      result = Content.search_articles("kestrels", user: user, sort: :newest)
      assert Enum.map(result.articles, & &1.id) == [in_body.id, in_title.id]
    end

    test "newest and oldest are each other's reverse" do
      user = create_user()
      board = create_board()

      old =
        create_article(user, board, %{title: "Pelican one"}) |> stamp(~U[2026-01-01 00:00:00Z])

      new =
        create_article(user, board, %{title: "Pelican two"}) |> stamp(~U[2026-06-01 00:00:00Z])

      newest = Content.search_articles("pelican", user: user, sort: :newest)
      oldest = Content.search_articles("pelican", user: user, sort: :oldest)

      assert Enum.map(newest.articles, & &1.id) == [new.id, old.id]
      assert Enum.map(oldest.articles, & &1.id) == [old.id, new.id]
    end

    test "a CJK query ranks a title match first" do
      user = create_user()
      board = create_board()

      in_body = create_article(user, board, %{title: "別的東西", body: "這篇提到台灣獨立"})
      in_title = create_article(user, board, %{title: "台灣獨立運動", body: "無關"})

      result = Content.search_articles("台灣", user: user, sort: :relevance)
      ids = Enum.map(result.articles, & &1.id)

      assert in_title.id in ids
      assert in_body.id in ids
      assert hd(ids) == in_title.id
    end

    test "relevance falls back to newest when there is nothing to rank" do
      user = create_user()
      board = create_board()

      old = create_article(user, board) |> stamp(~U[2026-01-01 00:00:00Z])
      new = create_article(user, board) |> stamp(~U[2026-06-01 00:00:00Z])

      result = Content.search_articles("board:#{board.slug}", user: user, sort: :relevance)
      assert Enum.map(result.articles, & &1.id) == [new.id, old.id]
    end

    test "an unknown sort is the default rather than an error" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Cormorant"})

      result = Content.search_articles("cormorant", user: user, sort: :engagement)
      assert Enum.map(result.articles, & &1.id) == [article.id]
    end

    test "paging is stable when every result ranks the same" do
      user = create_user()
      board = create_board()

      # Identical text, identical timestamps: without the `id` tiebreaker the
      # database is free to order these differently for each OFFSET, which
      # shows one row on two pages and drops another entirely.
      articles =
        for _ <- 1..5 do
          create_article(user, board, %{title: "Identical guillemot", body: "same body"})
        end

      from(a in Content.Article, where: a.id in ^Enum.map(articles, & &1.id))
      |> Repo.update_all(set: [inserted_at: ~U[2026-04-01 00:00:00Z]])

      seen =
        for page <- 1..3 do
          Content.search_articles("guillemot", user: user, page: page, per_page: 2)
        end
        |> Enum.flat_map(& &1.articles)
        |> Enum.map(& &1.id)

      assert length(seen) == 5
      assert Enum.sort(seen) == Enum.sort(Enum.map(articles, & &1.id))
    end

    test "every order clause ends with the id, whatever the sort" do
      # The test above cannot prove this: with five tied rows PostgreSQL
      # returns a consistent order anyway, so dropping the tiebreaker passes it
      # and only breaks in production, where a reader loses a result between
      # two pages. The clause itself is what gets asserted.
      for surface <- [:articles, :comments],
          sort <- Content.Search.sorts(),
          text <- ["", "kestrels", "台灣"] do
        order = Content.Search.order_for(surface, sort, text)

        {sql, _params} =
          Ecto.Adapters.SQL.to_sql(
            :all,
            Repo,
            from(x in schema_for(surface), order_by: ^order)
          )

        assert sql =~ ~r/ORDER BY .*"id"( DESC)?$/,
               "#{surface}/#{sort}/#{inspect(text)} does not end on the id: #{sql}"
      end
    end

    defp schema_for(:articles), do: Content.Article
    defp schema_for(:comments), do: Content.Comment
  end

  describe "search_comments/2 ordering" do
    test "is newest-first by date, which DISTINCT ON used to silently override" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      old = create_comment(user, article, "an old remark about auks")
      new = create_comment(user, article, "a new remark about auks")

      from(c in Content.Comment, where: c.id == ^old.id)
      |> Repo.update_all(set: [inserted_at: ~U[2026-01-01 00:00:00Z]])

      from(c in Content.Comment, where: c.id == ^new.id)
      |> Repo.update_all(set: [inserted_at: ~U[2026-06-01 00:00:00Z]])

      result = Content.search_comments("auks", user: user, sort: :newest)
      assert Enum.map(result.comments, & &1.id) == [new.id, old.id]

      result = Content.search_comments("auks", user: user, sort: :oldest)
      assert Enum.map(result.comments, & &1.id) == [old.id, new.id]
    end

    test "a comment on a cross-posted article is listed once" do
      user = create_user()
      board_a = create_board()
      board_b = create_board()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Cross posted",
            body: "body",
            slug: "cross-posted-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board_a.id, board_b.id]
        )

      comment = create_comment(user, article, "a remark about shearwaters")

      result = Content.search_comments("shearwaters", user: user)
      assert Enum.map(result.comments, & &1.id) == [comment.id]
      assert result.total == 1
    end
  end

  describe "a search needs a scope" do
    test "a date range on its own returns nothing rather than everything" do
      user = create_user()
      board = create_board()
      create_article(user, board, %{title: "Would have been listed"})

      for query <- ["after:2020-01-01", "before:2099-01-01", "after:2020-01-01 before:2099-01-01"] do
        assert %{articles: [], total: 0} = Content.search_articles(query, user: user)
        assert %{comments: [], total: 0} = Content.search_comments(query, user: user)
      end
    end

    test "neither does has: on its own" do
      user = create_user()
      board = create_board()
      create_article(user, board)

      assert %{articles: [], total: 0} = Content.search_articles("has:images", user: user)
    end

    test "a person, a board, a tag or a word is a scope" do
      user = create_user()
      board = create_board()
      article = create_article(user, board, %{title: "Scoped puffin"})

      for query <- [
            "puffin",
            "author:#{user.username}",
            "board:#{board.slug}",
            "board:#{board.slug} after:2020-01-01"
          ] do
        result = Content.search_articles(query, user: user)
        assert article.id in Enum.map(result.articles, & &1.id), query
      end
    end

    test "the refusal reports an honest empty page rather than a stale one" do
      user = create_user()

      result = Content.search_articles("after:2020-01-01", user: user, page: 3)
      assert result.total == 0
      assert result.total_pages == 1
      assert result.page == 3
    end
  end

  describe "search_comments/2 operators" do
    setup do
      author = create_user()
      other = create_user()
      board = create_board()
      tagged_board = create_board()

      article = create_article(author, board)

      {:ok, %{article: tagged}} =
        Content.create_article(
          %{
            title: "Tagged article",
            body: "body #elixir",
            slug: "tagged-#{System.unique_integer([:positive])}",
            user_id: author.id
          },
          [tagged_board.id]
        )

      %{
        author: author,
        other: other,
        board: board,
        tagged_board: tagged_board,
        article: article,
        tagged: tagged
      }
    end

    test "author: matches the comment's own author, not the article's", ctx do
      mine = create_comment(ctx.other, ctx.article, "a remark about godwits")
      _theirs = create_comment(ctx.author, ctx.article, "another remark about godwits")

      result = Content.search_comments("author:#{ctx.other.username} godwits", user: ctx.author)
      assert Enum.map(result.comments, & &1.id) == [mine.id]
    end

    test "author: is case-insensitive", ctx do
      comment = create_comment(ctx.other, ctx.article, "a remark about dunlins")

      result =
        Content.search_comments(
          "author:#{String.upcase(ctx.other.username)} dunlins",
          user: ctx.author
        )

      assert Enum.map(result.comments, & &1.id) == [comment.id]
    end

    test "board: matches the board the article is in", ctx do
      here = create_comment(ctx.author, ctx.article, "a remark about sandpipers")
      _elsewhere = create_comment(ctx.author, ctx.tagged, "another remark about sandpipers")

      result = Content.search_comments("board:#{ctx.board.slug} sandpipers", user: ctx.author)
      assert Enum.map(result.comments, & &1.id) == [here.id]
    end

    test "tag: matches a tag on the article", ctx do
      tagged = create_comment(ctx.author, ctx.tagged, "a remark about curlews")
      _untagged = create_comment(ctx.author, ctx.article, "another remark about curlews")

      result = Content.search_comments("tag:elixir curlews", user: ctx.author)
      assert Enum.map(result.comments, & &1.id) == [tagged.id]
    end

    test "has:images matches the comment's own images", ctx do
      with_image = create_comment(ctx.author, ctx.article, "a remark about avocets")
      _without = create_comment(ctx.author, ctx.article, "another remark about avocets")

      Repo.insert!(%Content.CommentImage{
        comment_id: with_image.id,
        user_id: ctx.author.id,
        filename: "test.webp",
        storage_path: "/uploads/test.webp",
        width: 10,
        height: 10
      })

      result = Content.search_comments("has:images avocets", user: ctx.author)
      assert Enum.map(result.comments, & &1.id) == [with_image.id]
    end

    test "before: and after: read the comment's date, not the article's", ctx do
      old = create_comment(ctx.author, ctx.article, "an old remark about turnstones")
      new = create_comment(ctx.author, ctx.article, "a new remark about turnstones")

      from(c in Content.Comment, where: c.id == ^old.id)
      |> Repo.update_all(set: [inserted_at: ~U[2026-01-10 12:00:00Z]])

      from(c in Content.Comment, where: c.id == ^new.id)
      |> Repo.update_all(set: [inserted_at: ~U[2026-06-10 12:00:00Z]])

      result = Content.search_comments("turnstones before:2026-02-01", user: ctx.author)
      assert Enum.map(result.comments, & &1.id) == [old.id]

      result = Content.search_comments("turnstones after:2026-02-01", user: ctx.author)
      assert Enum.map(result.comments, & &1.id) == [new.id]
    end

    test "board: narrows and never widens", ctx do
      private = create_board(%{min_role_to_view: "admin"})

      {:ok, %{article: hidden_article}} =
        Content.create_article(
          %{
            title: "Hidden",
            body: "body",
            slug: "hidden-#{System.unique_integer([:positive])}",
            user_id: ctx.author.id
          },
          [private.id]
        )

      create_comment(ctx.author, hidden_article, "a remark about phalaropes")

      # The author is an ordinary member, so the board gate refuses it whether
      # or not the operator names the board.
      result = Content.search_comments("board:#{private.slug} phalaropes", user: ctx.author)
      assert result.comments == []
    end
  end
end
