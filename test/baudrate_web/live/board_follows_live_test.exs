defmodule BaudrateWeb.BoardFollowsLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    {:ok, conn: conn}
  end

  defp create_board(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      name: "Board #{uid}",
      slug: "board-#{uid}",
      min_role_to_view: "guest",
      ap_enabled: true,
      ap_accept_policy: "followers_only"
    }

    %Content.Board{}
    |> Content.Board.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      display_name: "Actor #{uid}",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    actor
  end

  describe "access control" do
    test "moderator can access the page", %{conn: conn} do
      user = setup_user("moderator")
      user = Repo.preload(user, :role)
      board = create_board()

      conn = log_in_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/boards/#{board.slug}/follows")
      assert html =~ "Board Follows"
    end

    test "admin can access the page", %{conn: conn} do
      user = setup_user("admin")
      user = Repo.preload(user, :role)
      board = create_board()

      conn = log_in_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/boards/#{board.slug}/follows")
      assert html =~ "Board Follows"
    end

    test "regular user is redirected", %{conn: conn} do
      user = setup_user("user")
      user = Repo.preload(user, :role)
      board = create_board()

      conn = log_in_user(conn, user)
      {:ok, conn} = live(conn, ~p"/boards/#{board.slug}/follows") |> follow_redirect(conn)
      assert conn.request_path == "/boards/#{board.slug}"
    end

    test "guest is redirected to login", %{conn: conn} do
      board = create_board()
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/boards/#{board.slug}/follows")
      assert path =~ "/login"
    end

    test "board moderator (non-admin) can access", %{conn: conn} do
      user = setup_user("user")
      user = Repo.preload(user, :role)
      board = create_board()
      Content.add_board_moderator(board.id, user.id)

      conn = log_in_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/boards/#{board.slug}/follows")
      assert html =~ "Board Follows"
    end
  end

  describe "accept policy change" do
    test "moderator can update accept policy", %{conn: conn} do
      user = setup_user("moderator")
      user = Repo.preload(user, :role)
      board = create_board(%{ap_accept_policy: "followers_only"})

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board.slug}/follows")

      lv |> element("button", "Open") |> render_click()

      updated_board = Content.get_board!(board.id)
      assert updated_board.ap_accept_policy == "open"
    end
  end

  describe "unfollow" do
    test "moderator can unfollow a remote actor", %{conn: conn} do
      user = setup_user("moderator")
      user = Repo.preload(user, :role)
      board = create_board()
      remote_actor = create_remote_actor()

      {:ok, follow} = Federation.create_board_follow(board, remote_actor)
      Federation.accept_board_follow(follow.ap_id)

      conn = log_in_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/boards/#{board.slug}/follows")

      assert html =~ remote_actor.username

      lv |> element("button", "Unfollow") |> render_click()

      assert is_nil(Federation.get_board_follow(board.id, remote_actor.id))
    end
  end
end
