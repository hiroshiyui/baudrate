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
end
