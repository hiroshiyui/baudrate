defmodule BaudrateWeb.SearchLiveLocalUsersTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Federation
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Site"})
    user = setup_user("user")
    user = Repo.preload(user, :role)
    conn = log_in_user(conn, user)

    {:ok, conn: conn, user: user}
  end

  describe "users tab" do
    test "users tab appears in search results", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/search?q=test&tab=users")
      assert html =~ "Users"
    end

    test "shows local users matching query", %{conn: conn} do
      other_user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/search?q=#{other_user.username}&tab=users")
      assert html =~ other_user.username
    end

    test "self not shown in user results", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, "/search?q=#{user.username}&tab=users")
      refute html =~ ~s(phx-value-id="#{user.id}")
    end

    test "shows Local badge on user cards", %{conn: conn} do
      _other_user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/search?q=user&tab=users")
      assert html =~ "Local"
    end

    test "shows follow button for unfollowed users", %{conn: conn} do
      other_user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/search?q=#{other_user.username}&tab=users")
      assert html =~ "Follow"
    end

    test "shows unfollow button for followed users", %{conn: conn, user: user} do
      other_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(user, other_user)

      {:ok, _lv, html} = live(conn, "/search?q=#{other_user.username}&tab=users")
      assert html =~ "Unfollow"
    end
  end

  describe "follow/unfollow events" do
    test "follow_user creates local follow", %{conn: conn, user: user} do
      other_user = setup_user("user")

      {:ok, lv, _html} = live(conn, "/search?q=#{other_user.username}&tab=users")

      html =
        lv
        |> element(~s(button[phx-click="follow_user"][phx-value-id="#{other_user.id}"]))
        |> render_click()

      assert html =~ "Followed successfully"
      assert Federation.local_follows?(user.id, other_user.id)
    end

    test "unfollow_user deletes local follow", %{conn: conn, user: user} do
      other_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(user, other_user)

      {:ok, lv, _html} = live(conn, "/search?q=#{other_user.username}&tab=users")

      html =
        lv
        |> element(~s(button[phx-click="unfollow_user"][phx-value-id="#{other_user.id}"]))
        |> render_click()

      assert html =~ "Unfollowed successfully"
      refute Federation.local_follows?(user.id, other_user.id)
    end
  end

  describe "guest users" do
    test "guest sees sign in to follow button" do
      conn = build_conn()
      _other_user = setup_user("user")

      {:ok, _lv, html} = live(conn, "/search?q=user&tab=users")
      assert html =~ "Sign in to follow"
    end
  end
end
