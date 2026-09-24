defmodule BaudrateWeb.Admin.BoardsLiveTest do
  use BaudrateWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Baudrate.Content
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    {:ok, conn: conn}
  end

  test "admin can view boards page", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, _lv, html} = live(conn, "/admin/boards")
    assert html =~ "Board Management"
  end

  test "non-admin is redirected away", %{conn: conn} do
    user = setup_user("user")
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/admin/boards")
  end

  test "admin can open new board form", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/boards")
    html = lv |> element("button[phx-click=\"new\"]") |> render_click()
    assert html =~ "New Board"
  end

  test "admin can create a board", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/boards")
    lv |> element("button[phx-click=\"new\"]") |> render_click()

    slug = "test-board-#{System.unique_integer([:positive])}"

    html =
      lv
      |> form("#admin-boards-form",
        board: %{
          name: "Test Board",
          slug: slug,
          min_role_to_view: "guest",
          min_role_to_post: "user"
        }
      )
      |> render_submit()

    assert html =~ "Board created successfully"
    assert html =~ "Test Board"
  end

  test "admin can edit a board", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, board} =
      Content.create_board(%{
        name: "Edit Me",
        slug: "edit-me-#{System.unique_integer([:positive])}"
      })

    {:ok, lv, _html} = live(conn, "/admin/boards")
    lv |> element("button[phx-click=\"edit\"][phx-value-id=\"#{board.id}\"]") |> render_click()

    html =
      lv
      |> form("#admin-boards-form", board: %{name: "Edited Name"})
      |> render_submit()

    assert html =~ "Board updated successfully"
    assert html =~ "Edited Name"
  end

  test "admin can delete an empty board", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, board} =
      Content.create_board(%{
        name: "Delete Me",
        slug: "delete-me-#{System.unique_integer([:positive])}"
      })

    {:ok, lv, _html} = live(conn, "/admin/boards")

    html =
      lv
      |> element("button[phx-click=\"delete\"][phx-value-id=\"#{board.id}\"]")
      |> render_click()

    assert html =~ "Board deleted successfully"
    refute html =~ "Delete Me"
    assert_push_event(lv, "focus", %{id: "boards-heading"})
  end

  test "boards table has no live region and row actions name their board", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, board} =
      Content.create_board(%{
        name: "A11y Board",
        slug: "a11y-board-#{System.unique_integer([:positive])}"
      })

    {:ok, lv, _html} = live(conn, "/admin/boards")

    refute has_element?(lv, "#boards-table tbody[aria-live]")
    assert has_element?(lv, "#board-#{board.id} th[scope=\"row\"]", "A11y Board")

    assert has_element?(
             lv,
             "#admin-boards-delete-#{board.id}[aria-label=\"Delete board A11y Board\"]"
           )

    assert has_element?(
             lv,
             "#admin-boards-edit-#{board.id}[aria-label=\"Edit board A11y Board\"]"
           )
  end

  test "admin cannot delete board with articles", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, board} =
      Content.create_board(%{
        name: "Busy Board",
        slug: "busy-#{System.unique_integer([:positive])}"
      })

    # Create article linked to this board
    alias Baudrate.Content.{Article, BoardArticle}
    user = setup_user("user")

    {:ok, article} =
      %Article{}
      |> Article.changeset(%{
        title: "Test",
        body: "Body",
        slug: "art-#{System.unique_integer([:positive])}",
        user_id: user.id
      })
      |> Repo.insert()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%BoardArticle{
      board_id: board.id,
      article_id: article.id,
      inserted_at: now,
      updated_at: now
    })

    {:ok, lv, _html} = live(conn, "/admin/boards")

    html =
      lv
      |> element("button[phx-click=\"delete\"][phx-value-id=\"#{board.id}\"]")
      |> render_click()

    assert html =~ "This board still has articles. Use Move articles"
  end

  describe "ordering and emptying boards (7C)" do
    setup %{conn: conn} do
      admin = setup_user("admin")
      %{conn: log_in_admin(conn, admin), admin: admin}
    end

    defp top_board(name) do
      {:ok, board} =
        Content.create_board(%{
          name: name,
          slug: "#{String.downcase(name)}-#{System.unique_integer([:positive])}"
        })

      board
    end

    test "Move up and Move down reorder siblings, keep focus, and are logged", %{conn: conn} do
      first = top_board("First")
      second = top_board("Second")

      {:ok, lv, _html} = live(conn, "/admin/boards")

      # The first board has no Move up; the last has no Move down.
      refute has_element?(lv, "#admin-boards-move-up-#{first.id}")
      refute has_element?(lv, "#admin-boards-move-down-#{second.id}")
      refute has_element?(lv, ~s(#admin-boards-form input[name="board[position]"]))

      lv |> element("#admin-boards-move-up-#{second.id}") |> render_click()

      ids = Enum.map(Content.list_top_boards(), & &1.id)
      assert Enum.find_index(ids, &(&1 == second.id)) < Enum.find_index(ids, &(&1 == first.id))
      # It is now first, so its Move up is gone and focus goes to Move down.
      assert_push_event(lv, "focus", %{id: "admin-boards-move-down-" <> _})

      assert Repo.exists?(
               from(l in Baudrate.Moderation.Log,
                 where: l.action == "reorder_boards" and l.target_id == ^second.id
               )
             )
    end

    test "Move articles empties a board so it can be deleted", %{conn: conn} do
      from = top_board("Old")
      to = top_board("New")
      user = setup_user("user")

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Keep me",
            body: "b",
            slug: "keep-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [from.id]
        )

      {:ok, lv, _html} = live(conn, "/admin/boards")
      lv |> element("#admin-boards-move-articles-#{from.id}") |> render_click()

      html =
        lv
        |> form("#admin-boards-move-articles-form", %{target_id: to.id})
        |> render_submit()

      assert html =~ "1 article moved from Old to New."
      assert [%{id: id}] = Repo.preload(article, :boards, force: true).boards
      assert id == to.id

      lv |> element("#admin-boards-delete-#{from.id}") |> render_click()
      assert {:error, :not_found} = Content.get_board(from.id)
    end
  end

  test "admin cannot delete board with children", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, parent} =
      Content.create_board(%{
        name: "Parent Board",
        slug: "parent-#{System.unique_integer([:positive])}"
      })

    {:ok, _child} =
      Content.create_board(%{
        name: "Child Board",
        slug: "child-#{System.unique_integer([:positive])}",
        parent_id: parent.id
      })

    {:ok, lv, _html} = live(conn, "/admin/boards")

    html =
      lv
      |> element("button[phx-click=\"delete\"][phx-value-id=\"#{parent.id}\"]")
      |> render_click()

    assert html =~ "Cannot delete board that has sub-boards"
  end

  test "admin can cancel form", %{conn: conn} do
    admin = setup_user("admin")
    conn = log_in_admin(conn, admin)

    {:ok, lv, _html} = live(conn, "/admin/boards")
    lv |> element("button[phx-click=\"new\"]") |> render_click()

    html = lv |> element("button[phx-click=\"cancel\"]") |> render_click()
    refute html =~ "card-title"
  end
end
