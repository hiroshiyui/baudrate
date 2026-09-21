defmodule BaudrateWeb.ArticleNewLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    conn = log_in_user(conn, user)

    board =
      %Board{}
      |> Board.changeset(%{name: "General", slug: "general"})
      |> Repo.insert!()

    {:ok, conn: conn, user: user, board: board}
  end

  test "redirects unauthenticated user to login" do
    conn = Phoenix.ConnTest.build_conn()

    assert {:error, {:redirect, %{to: "/login" <> _}}} =
             live(conn, "/articles/new")
  end

  test "renders article creation form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/articles/new")
    assert html =~ "Create Article"
    assert html =~ "Title"
    assert html =~ "Body"
  end

  test "renders form with fixed board when accessed from board URL", %{conn: conn, board: board} do
    {:ok, _lv, html} = live(conn, "/boards/#{board.slug}/articles/new")
    assert html =~ "Create Article"
    # Board is fixed via hidden input, no picker shown
    assert html =~ ~s(type="hidden" name="board_ids[]" value="#{board.id}")
    refute html =~ ~s(type="checkbox" name="board_ids[]")
  end

  test "creates article from board URL without selecting boards", %{conn: conn, board: board} do
    {:ok, lv, _html} = live(conn, "/boards/#{board.slug}/articles/new")

    lv
    |> form("#article-new-form",
      article: %{title: "Board Article", body: "Posted from board page"}
    )
    |> render_submit()

    {path, _flash} = assert_redirect(lv)
    assert path =~ "/articles/"
  end

  test "renders form with fixed sub-board when accessed from sub-board URL", %{
    conn: conn,
    board: board
  } do
    sub_board =
      %Board{}
      |> Board.changeset(%{name: "Sub Board", slug: "sub", parent_id: board.id})
      |> Repo.insert!()

    {:ok, _lv, html} = live(conn, "/boards/#{sub_board.slug}/articles/new")
    assert html =~ "Create Article"
    assert html =~ ~s(type="hidden" name="board_ids[]" value="#{sub_board.id}")
  end

  test "creates article successfully", %{conn: conn, board: board} do
    {:ok, lv, _html} = live(conn, "/articles/new")

    lv
    |> form("#article-new-form", article: %{title: "Test Article", body: "Test body content"})
    |> render_submit(%{"board_ids" => ["#{board.id}"]})

    {path, _flash} = assert_redirect(lv)
    assert path =~ "/articles/"
  end

  test "shows error when no board selected", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/articles/new")

    html =
      lv
      |> form("#article-new-form", article: %{title: "No Board", body: "Test body"})
      |> render_submit()

    assert html =~ "Please select at least one board"
  end

  test "renders form with DraftSaveHook and draft indicator", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/articles/new")
    assert html =~ ~s(phx-hook="DraftSaveHook")
    assert html =~ ~s(data-draft-key="draft:article:new")
    assert html =~ ~s(data-draft-fields="article[title],article[body]")
    assert html =~ "draft-indicator-new"
  end

  test "pre-fills form from share query params", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, "/articles/new?title=Shared+Title&text=Some+text&url=https://example.com")

    assert html =~ "Shared Title"
    assert html =~ "Some text"
    assert html =~ "https://example.com"
    assert html =~ "No board selected"
  end

  test "boardless article submission succeeds when from share", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/articles/new?title=Shared+Article&text=Shared+body+content")

    lv
    |> form("#article-new-form", article: %{title: "Shared Article", body: "Shared body content"})
    |> render_submit()

    {path, _flash} = assert_redirect(lv)
    assert path =~ "/articles/"
  end

  test "share hint is not shown without share params", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/articles/new")
    refute html =~ "No board selected"
  end

  describe "board search" do
    test "short query returns no results", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      html =
        lv
        |> element(~s|#article-new-boards input[name="board_search_query"]|)
        |> render_keyup(%{"value" => "a"})

      refute html =~ ~s(id="board-search-results")
      refute html =~ board.name
    end

    test "matches board by name", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      html =
        lv
        |> element(~s|#article-new-boards input[name="board_search_query"]|)
        |> render_keyup(%{"value" => "Gen"})

      assert html =~ ~s(id="board-search-results")
      assert html =~ board.name
    end

    test "adding a board shows it as a selected chip and creates a hidden input", %{
      conn: conn,
      board: board
    } do
      {:ok, lv, _html} = live(conn, "/articles/new")

      lv
      |> element(~s|#article-new-boards input[name="board_search_query"]|)
      |> render_keyup(%{"value" => board.name})

      html =
        lv |> element("#board-search-results button", board.name) |> render_click()

      assert html =~ ~s(<ul) and html =~ "selected-boards"
      assert html =~ ~s(type="hidden" name="board_ids[]" value="#{board.id}")
      # Search results list is cleared after adding
      refute html =~ ~s(id="board-search-results")
    end

    test "removing a selected board clears the hidden input", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      lv
      |> element(~s|#article-new-boards input[name="board_search_query"]|)
      |> render_keyup(%{"value" => board.name})

      lv |> element("#board-search-results button", board.name) |> render_click()

      html =
        lv
        |> element(~s|button[phx-click="remove_board"][phx-value-board-id="#{board.id}"]|)
        |> render_click()

      refute html =~ ~s(type="hidden" name="board_ids[]" value="#{board.id}")
    end

    test "creates article via search flow", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      lv
      |> element(~s|#article-new-boards input[name="board_search_query"]|)
      |> render_keyup(%{"value" => board.name})

      lv |> element("#board-search-results button", board.name) |> render_click()

      lv
      |> form("#article-new-form",
        article: %{title: "Searched Board Article", body: "Body content"}
      )
      |> render_submit()

      {path, _flash} = assert_redirect(lv)
      assert path =~ "/articles/"
    end

    test "search excludes boards the user cannot post in", %{conn: conn} do
      mod_only_board =
        %Board{}
        |> Board.changeset(%{
          name: "ModOnly-#{System.unique_integer([:positive])}",
          slug: "mod-only-#{System.unique_integer([:positive])}",
          min_role_to_post: "moderator"
        })
        |> Repo.insert!()

      {:ok, lv, _html} = live(conn, "/articles/new")

      html =
        lv
        |> element(~s|#article-new-boards input[name="board_search_query"]|)
        |> render_keyup(%{"value" => "ModOnly"})

      refute html =~ mod_only_board.name
    end

    test "submit rejects a forged board_ids[] for a board the user cannot post in",
         %{conn: conn} do
      # Simulates a DevTools-crafted submission where the client injects a
      # hidden input for a moderator-only board that was never surfaced by
      # the search UI. Server-side Content.authorize_post_in_boards/2 must
      # reject the submission before any article row is inserted.
      mod_only_board =
        %Board{}
        |> Board.changeset(%{
          name: "PrivateBoard-#{System.unique_integer([:positive])}",
          slug: "private-#{System.unique_integer([:positive])}",
          min_role_to_post: "moderator"
        })
        |> Repo.insert!()

      {:ok, lv, _html} = live(conn, "/articles/new")

      html =
        lv
        |> form("#article-new-form",
          article: %{title: "Forged Attempt", body: "Bypass via DevTools"}
        )
        |> render_submit(%{"board_ids" => ["#{mod_only_board.id}"]})

      assert html =~ "not allowed to post in one or more of the selected boards"

      refute Baudrate.Repo.get_by(Baudrate.Content.Article, title: "Forged Attempt")
    end
  end

  test "redirects pending user away from article creation", %{conn: _conn} do
    {:ok, pending_user, _codes} =
      Baudrate.Auth.register_user(%{
        "username" => "pendingwriter",
        "password" => "SecurePass1!!",
        "password_confirmation" => "SecurePass1!!",
        "terms_accepted" => "true"
      })

    conn =
      Phoenix.ConnTest.build_conn()
      |> log_in_user(pending_user)

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/articles/new")
  end

  describe "server-owned fields" do
    test "ignores client-supplied ap_id, url and published_at", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, "/boards/#{board.slug}/articles/new")

      render_hook(lv, "submit", %{
        "article" => %{
          "title" => "Squat Attempt",
          "body" => "Body",
          "ap_id" => "https://lemmy.example/post/12346",
          "url" => "javascript:alert(1)",
          "published_at" => "2015-01-01T00:00:00Z",
          "user_id" => "1"
        },
        "board_ids" => ["#{board.id}"]
      })

      article = Baudrate.Repo.get_by!(Baudrate.Content.Article, title: "Squat Attempt")

      assert String.starts_with?(article.ap_id, Baudrate.Federation.base_url())
      assert is_nil(article.url)
      assert is_nil(article.published_at)
    end
  end

  describe "accessibility" do
    test "image file input is keyboard reachable (not display:none)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      assert has_element?(lv, "#article-new-attachments-toolbar input[type=file].sr-only")
      refute has_element?(lv, "#article-new-attachments-toolbar input[type=file].hidden")
    end

    test "board search is a labelled input without combobox roles", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      assert has_element?(lv, "#article-new-board-search-input[aria-label]")
      refute has_element?(lv, "#article-new-board-search-input[role]")
      assert has_element?(lv, ~s(#article-new-board-search-status[role="status"]))
    end

    test "poll toggle exposes its expanded state", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/articles/new")

      assert has_element?(lv, ~s(#article-new-toggle-poll[aria-expanded="false"]))
      lv |> element("#article-new-toggle-poll") |> render_click()
      assert has_element?(lv, ~s(#article-new-toggle-poll[aria-expanded="true"]))
    end
  end

  # LiveView ignores phx-change on the poll's fieldset, so poll edits arrive with
  # the article form's change event. Unless that event keeps them, the re-render
  # resets every option input in the browser and no poll can be created.
  test "poll fields typed into the form are rendered back after a change", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/articles/new")
    lv |> element("#article-new-toggle-poll") |> render_click()

    lv
    |> form("#article-new-form",
      article: %{title: "Lunch"},
      poll_options: %{"0" => "Noodles", "1" => "Curry"},
      poll_mode: "multiple",
      poll_expires: "1d"
    )
    |> render_change()

    assert has_element?(lv, ~s(#article-new-poll-option-0[value="Noodles"]))
    assert has_element?(lv, ~s(#article-new-poll-option-1[value="Curry"]))
    assert has_element?(lv, "#article-new-poll-mode-multiple[checked]")
    assert has_element?(lv, ~s(#poll-expires option[value="1d"][selected]))
  end
end
