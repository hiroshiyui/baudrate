defmodule BaudrateWeb.HomeLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Content.PubSub, as: ContentPubSub
  alias Baudrate.Repo
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  test "renders JSON-LD with sioc:Site", %{conn: conn} do
    Repo.insert!(%Setting{key: "site_name", value: "Test BBS"})
    {:ok, _lv, html} = live(conn, "/")

    assert html =~ "application/ld+json"
    assert html =~ "sioc:Site"
    assert html =~ "Test BBS"
  end

  describe "guest" do
    test "sees public boards", %{conn: conn} do
      %Board{}
      |> Board.changeset(%{
        name: "Public Board",
        slug: "public-home-#{System.unique_integer([:positive])}",
        min_role_to_view: "guest"
      })
      |> Repo.insert!()

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "Public Board"
    end

    test "does not see restricted boards", %{conn: conn} do
      %Board{}
      |> Board.changeset(%{
        name: "Members Only",
        slug: "members-home-#{System.unique_integer([:positive])}",
        min_role_to_view: "user"
      })
      |> Repo.insert!()

      {:ok, _lv, html} = live(conn, "/")

      refute html =~ "Members Only"
    end

    test "sees generic welcome message", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "Welcome to Baudrate"
      refute html =~ "You are signed in as"
    end
  end

  describe "when no board is visible to the viewer" do
    # Setup always seeds the SysOp board and `delete_board/1` refuses to remove
    # it, so "no boards at all" cannot happen. "None this viewer may see" can:
    # nothing stops an admin raising SysOp's `min_role_to_view`, and the home
    # page lists `list_visible_top_boards/1`, not every board.

    test "a guest is not told to browse boards that are not there", %{conn: conn} do
      %Board{}
      |> Board.changeset(%{
        name: "Members Only",
        slug: "restricted-home-#{System.unique_integer([:positive])}",
        min_role_to_view: "user"
      })
      |> Repo.insert!()

      {:ok, _lv, html} = live(conn, "/")

      refute html =~ "Browse the boards below"
      assert html =~ "No boards are open to visitors yet"
    end

    test "a guest gets an empty state rather than a bare heading", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")

      assert html =~ ~s(id="boards-empty")
      assert html =~ "No boards to show."
      assert html =~ "Signing in may show more."
    end

    test "the empty state never names a board the viewer cannot see", %{conn: conn} do
      %Board{}
      |> Board.changeset(%{
        name: "Secret Cabal",
        slug: "secret-home-#{System.unique_integer([:positive])}",
        min_role_to_view: "admin"
      })
      |> Repo.insert!()

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ ~s(id="boards-empty")
      refute html =~ "Secret Cabal"
    end

    test "a signed-in member sees the empty state without the guest hint", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      %Board{}
      |> Board.changeset(%{
        name: "Admin Only",
        slug: "adminonly-home-#{System.unique_integer([:positive])}",
        min_role_to_view: "admin"
      })
      |> Repo.insert!()

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "No boards to show."
      refute html =~ "Signing in may show more."
    end

    test "the empty state is gone as soon as one board is visible", %{conn: conn} do
      %Board{}
      |> Board.changeset(%{
        name: "Open Board",
        slug: "open-home-#{System.unique_integer([:positive])}",
        min_role_to_view: "guest"
      })
      |> Repo.insert!()

      {:ok, _lv, html} = live(conn, "/")

      refute html =~ ~s(id="boards-empty")
      assert html =~ "Browse the boards below"
      assert html =~ "Open Board"
    end
  end

  describe "unread indicators" do
    test "refreshes unread board indicator in real-time when article is created", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      board =
        %Board{}
        |> Board.changeset(%{
          name: "Live Board",
          slug: "live-board-#{System.unique_integer([:positive])}",
          min_role_to_view: "user"
        })
        |> Repo.insert!()

      # Move user registration to the past so articles are newer
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      Repo.update_all(
        from(u in Baudrate.Setup.User, where: u.id == ^user.id),
        set: [inserted_at: past]
      )

      {:ok, lv, html} = live(conn, "/")
      refute html =~ "rounded-full bg-primary"

      # Create article (triggers PubSub broadcast)
      {:ok, _} =
        Content.create_article(
          %{
            title: "Breaking News",
            body: "body",
            slug: "breaking-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      # Trigger PubSub manually to simulate the broadcast
      ContentPubSub.broadcast_to_board(board.id, :article_created, %{article_id: 0})

      html = render(lv)
      assert html =~ "rounded-full bg-primary"
    end

    test "guests do not subscribe and see no unread indicators", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/")
      refute html =~ "rounded-full bg-primary"
    end
  end

  describe "authenticated user" do
    test "sees boards matching their role level", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      %Board{}
      |> Board.changeset(%{
        name: "User Board",
        slug: "user-home-#{System.unique_integer([:positive])}",
        min_role_to_view: "user"
      })
      |> Repo.insert!()

      %Board{}
      |> Board.changeset(%{
        name: "Admin Board",
        slug: "admin-home-#{System.unique_integer([:positive])}",
        min_role_to_view: "admin"
      })
      |> Repo.insert!()

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "User Board"
      refute html =~ "Admin Board"
    end

    test "sees personalized welcome message", %{conn: conn} do
      user = setup_user("user")
      conn = log_in_user(conn, user)

      {:ok, _lv, html} = live(conn, "/")

      assert html =~ "Welcome, #{user.username}!"
      assert html =~ "You are signed in as user."
    end
  end

  describe "branding and purpose (4A)" do
    test "the welcome heading uses the site's own name, not \"Baudrate\"" do
      Repo.insert!(%Setting{key: "site_name", value: "Hsinchu BBS"})

      {:ok, _lv, html} = live(build_conn(), "/")

      assert html =~ "Welcome to Hsinchu BBS"
      refute html =~ "Welcome to Baudrate"
    end

    test "a guest is told what the site is for" do
      Repo.insert!(%Setting{key: "site_description", value: "A quiet board for radio amateurs."})

      {:ok, _lv, html} = live(build_conn(), "/")

      assert html =~ ~s(id="home-site-description")
      assert html =~ "A quiet board for radio amateurs."
    end

    test "an unset description renders nothing rather than an empty box" do
      {:ok, _lv, html} = live(build_conn(), "/")

      refute html =~ ~s(id="home-site-description")
    end

    test "a member is not told, every visit, what the site they are on is", %{conn: conn} do
      Repo.insert!(%Setting{key: "site_description", value: "A quiet board for radio amateurs."})
      conn = log_in_user(conn, setup_user("user"))

      {:ok, _lv, html} = live(conn, "/")

      refute html =~ ~s(id="home-site-description")
    end
  end

  describe "last activity on a board card (ADR 0054)" do
    test "a board with a post says when it was last active" do
      board = insert_board("Busy Board", "guest")
      user = setup_user("user")

      {:ok, _} =
        Content.create_article(
          %{
            title: "Something",
            body: "body",
            slug: "activity-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      {:ok, _lv, html} = live(build_conn(), "/")

      card = isolate_card(html, board.slug)
      assert card =~ "Last active"
      assert card =~ "<time"
    end

    test "a board nobody has posted in shows nothing, not a zero" do
      board = insert_board("Empty Board", "guest")

      {:ok, _lv, html} = live(build_conn(), "/")

      card = isolate_card(html, board.slug)
      assert card =~ "Empty Board", "could not isolate the card"

      refute card =~ "Last active",
             "an empty board claimed a last-active time"

      refute card =~ ~r/\b0\b/,
             "a board with nothing in it rendered a zero. ADR 0054: a count " <>
               "is a scoreboard between boards, and zero is the loudest entry " <>
               "on it."
    end

    test "activity rolls up from a sub-board, matching the unread dot" do
      parent = insert_board("Parent Board", "guest")

      child =
        %Board{}
        |> Board.changeset(%{
          name: "Child Board",
          slug: "child-#{System.unique_integer([:positive])}",
          min_role_to_view: "guest",
          parent_id: parent.id
        })
        |> Repo.insert!()

      user = setup_user("user")

      {:ok, _} =
        Content.create_article(
          %{
            title: "In the child",
            body: "body",
            slug: "child-activity-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [child.id]
        )

      # The parent is what the home page lists; a post in the child is still
      # activity in the parent, which is how the unread badge already behaves.
      assert %{} = activity = Content.last_activity_by_board([parent.id])
      assert Map.has_key?(activity, parent.id)

      {:ok, _lv, html} = live(build_conn(), "/")
      assert isolate_card(html, parent.slug) =~ "Last active"
    end

    test "a soft-deleted article stops counting as activity" do
      board = insert_board("Deleted Board", "guest")
      user = setup_user("user")

      # `create_article/2` answers with the Ecto.Multi result map, not a bare
      # article.
      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Doomed",
            body: "body",
            slug: "doomed-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [board.id]
        )

      assert Map.has_key?(Content.last_activity_by_board([board.id]), board.id)

      Repo.update_all(from(a in Baudrate.Content.Article, where: a.id == ^article.id),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      refute Map.has_key?(Content.last_activity_by_board([board.id]), board.id),
             "a withdrawn article kept the board looking active"
    end
  end

  defp insert_board(name, min_role_to_view) do
    %Board{}
    |> Board.changeset(%{
      name: name,
      slug:
        "#{String.downcase(String.replace(name, " ", "-"))}-#{System.unique_integer([:positive])}",
      min_role_to_view: min_role_to_view
    })
    |> Repo.insert!()
  end

  defp isolate_card(html, slug) do
    [_, rest] = String.split(html, ~s(id="board-#{slug}"), parts: 2)
    rest |> String.split("</a>", parts: 2) |> List.first()
  end
end
