defmodule Baudrate.Content.ReadTrackingTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{ArticleRead, BoardRead}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board do
    %Content.Board{}
    |> Content.Board.changeset(%{
      name: "Test",
      slug: "test-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp create_article(user, board) do
    slug = "art-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Body", slug: slug, user_id: user.id},
        [board.id]
      )

    article
  end

  defp set_last_activity_at(article, datetime) do
    from(a in Content.Article, where: a.id == ^article.id)
    |> Repo.update_all(set: [last_activity_at: datetime])

    Repo.get!(Content.Article, article.id)
  end

  describe "mark_article_read/2" do
    test "creates a read record for an article" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      assert {:ok, %ArticleRead{} = read} =
               Content.ReadTracking.mark_article_read(user.id, article.id)

      assert read.user_id == user.id
      assert read.article_id == article.id
      assert read.read_at != nil
    end

    test "upserts read_at on re-read" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, first_read} = Content.ReadTracking.mark_article_read(user.id, article.id)

      # Manually set read_at to the past so the upsert produces a different timestamp
      past = ~U[2020-01-01 00:00:00Z]

      from(ar in ArticleRead, where: ar.id == ^first_read.id)
      |> Repo.update_all(set: [read_at: past])

      {:ok, second_read} = Content.ReadTracking.mark_article_read(user.id, article.id)

      assert DateTime.compare(second_read.read_at, past) == :gt
    end
  end

  describe "mark_board_read/2" do
    test "creates a board read record" do
      user = create_user()
      board = create_board()

      assert {:ok, %BoardRead{} = read} =
               Content.ReadTracking.mark_board_read(user.id, board.id)

      assert read.user_id == user.id
      assert read.board_id == board.id
      assert read.read_at != nil
    end

    test "upserts read_at on re-read" do
      user = create_user()
      board = create_board()

      {:ok, first_read} = Content.ReadTracking.mark_board_read(user.id, board.id)

      past = ~U[2020-01-01 00:00:00Z]

      from(br in BoardRead, where: br.id == ^first_read.id)
      |> Repo.update_all(set: [read_at: past])

      {:ok, second_read} = Content.ReadTracking.mark_board_read(user.id, board.id)

      assert DateTime.compare(second_read.read_at, past) == :gt
    end
  end

  describe "unread_article_ids/3" do
    test "returns unread article IDs" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      # Set last_activity_at to the future so it's definitely after user.inserted_at
      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      article = set_last_activity_at(article, future)

      unread = Content.ReadTracking.unread_article_ids(user, [article.id], board.id)

      assert MapSet.member?(unread, article.id)
    end

    test "returns empty after marking article read" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      article = set_last_activity_at(article, future)

      # Confirm it's unread first
      assert MapSet.member?(
               Content.ReadTracking.unread_article_ids(user, [article.id], board.id),
               article.id
             )

      # Mark as read — need to set read_at to at least `future`
      Content.ReadTracking.mark_article_read(user.id, article.id)

      # Manually bump read_at to match/exceed last_activity_at
      from(ar in ArticleRead,
        where: ar.user_id == ^user.id and ar.article_id == ^article.id
      )
      |> Repo.update_all(set: [read_at: future])

      unread = Content.ReadTracking.unread_article_ids(user, [article.id], board.id)
      assert unread == MapSet.new()
    end

    test "respects board floor via mark_board_read" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      article = set_last_activity_at(article, future)

      # Article is unread
      assert MapSet.member?(
               Content.ReadTracking.unread_article_ids(user, [article.id], board.id),
               article.id
             )

      # Mark board as read with a timestamp >= article's last_activity_at
      Content.ReadTracking.mark_board_read(user.id, board.id)

      from(br in BoardRead,
        where: br.user_id == ^user.id and br.board_id == ^board.id
      )
      |> Repo.update_all(set: [read_at: future])

      unread = Content.ReadTracking.unread_article_ids(user, [article.id], board.id)
      assert unread == MapSet.new()
    end

    test "returns empty MapSet for nil user" do
      assert Content.ReadTracking.unread_article_ids(nil, [1, 2, 3], 1) == MapSet.new()
    end

    test "respects user.inserted_at baseline — articles before registration are read" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      # Set article last_activity_at to far in the past (before user registration)
      past = ~U[2000-01-01 00:00:00Z]
      _article = set_last_activity_at(article, past)

      unread = Content.ReadTracking.unread_article_ids(user, [article.id], board.id)
      assert unread == MapSet.new()
    end

    test "returns empty for empty article_ids list" do
      user = create_user()
      board = create_board()

      assert Content.ReadTracking.unread_article_ids(user, [], board.id) == MapSet.new()
    end
  end

  describe "unread_board_ids/2" do
    test "returns boards with unread articles" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      _article = set_last_activity_at(article, future)

      unread = Content.ReadTracking.unread_board_ids(user, [board.id])
      assert MapSet.member?(unread, board.id)
    end

    test "returns empty after marking board read" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      _article = set_last_activity_at(article, future)

      # Board is unread
      assert MapSet.member?(
               Content.ReadTracking.unread_board_ids(user, [board.id]),
               board.id
             )

      # Mark board as read with timestamp >= last_activity_at
      Content.ReadTracking.mark_board_read(user.id, board.id)

      from(br in BoardRead,
        where: br.user_id == ^user.id and br.board_id == ^board.id
      )
      |> Repo.update_all(set: [read_at: future])

      unread = Content.ReadTracking.unread_board_ids(user, [board.id])
      assert unread == MapSet.new()
    end

    test "returns empty MapSet for nil user" do
      assert Content.ReadTracking.unread_board_ids(nil, [1, 2, 3]) == MapSet.new()
    end

    test "returns empty for empty board_ids list" do
      user = create_user()
      assert Content.ReadTracking.unread_board_ids(user, []) == MapSet.new()
    end

    test "does not include boards where all articles predate user registration" do
      board = create_board()

      # Create user registered "now", but set article last_activity_at to the past
      user = create_user()
      article = create_article(user, board)

      past = ~U[2000-01-01 00:00:00Z]
      _article = set_last_activity_at(article, past)

      unread = Content.ReadTracking.unread_board_ids(user, [board.id])
      assert unread == MapSet.new()
    end
  end
end
