defmodule BaudrateWeb.HomeLiveTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content.Board
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
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
