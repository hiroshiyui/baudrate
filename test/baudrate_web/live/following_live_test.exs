defmodule BaudrateWeb.FollowingLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Federation
  alias Baudrate.Federation.{HTTPClient, KeyStore, RemoteActor}
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    {:ok, user} = KeyStore.ensure_user_keypair(user)
    user = Repo.preload(user, :role)
    conn = log_in_user(conn, user)

    {:ok, conn: conn, user: user}
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      display_name: "Remote Actor #{uid}",
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

  describe "page loads" do
    test "renders page with followed actors", %{conn: conn, user: user} do
      actor = create_remote_actor(%{username: "alice", domain: "example.org"})
      {:ok, _follow} = Federation.create_user_follow(user, actor)

      {:ok, _lv, html} = live(conn, "/following")

      assert html =~ "Following"
      assert html =~ "alice"
      assert html =~ "example.org"
      assert html =~ "Pending"
    end

    test "shows empty state when no follows", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/following")
      assert html =~ "haven&#39;t followed anyone yet"
    end

    test "shows accepted badge for accepted follow", %{conn: conn, user: user} do
      actor = create_remote_actor()
      {:ok, follow} = Federation.create_user_follow(user, actor)
      Federation.accept_user_follow(follow.ap_id)

      {:ok, _lv, html} = live(conn, "/following")
      assert html =~ "Accepted"
    end

    test "shows rejected badge for rejected follow", %{conn: conn, user: user} do
      actor = create_remote_actor()
      {:ok, follow} = Federation.create_user_follow(user, actor)
      Federation.reject_user_follow(follow.ap_id)

      {:ok, _lv, html} = live(conn, "/following")
      assert html =~ "Rejected"
    end
  end

  describe "unfollow" do
    test "removes actor from list", %{conn: conn, user: user} do
      actor = create_remote_actor(%{username: "bob", domain: "other.example"})
      {:ok, _follow} = Federation.create_user_follow(user, actor)

      # Stub HTTP for delivery
      Req.Test.stub(HTTPClient, fn conn ->
        Plug.Conn.send_resp(conn, 202, "")
      end)

      {:ok, lv, html} = live(conn, "/following")
      assert html =~ "bob"

      html = lv |> element("button[phx-click=unfollow]") |> render_click()
      assert html =~ "Unfollowed successfully"
      refute html =~ "bob"

      refute Federation.user_follows?(user.id, actor.id)
    end
  end

  describe "local follows" do
    test "shows local follows with Local badge", %{conn: conn, user: user} do
      followed_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(user, followed_user)

      {:ok, _lv, html} = live(conn, "/following")
      assert html =~ followed_user.username
      assert html =~ "Local"
      assert html =~ "Accepted"
    end

    test "unfollow local user removes from list", %{conn: conn, user: user} do
      followed_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(user, followed_user)

      {:ok, lv, html} = live(conn, "/following")
      assert html =~ followed_user.username

      html =
        lv
        |> element(~s(button[phx-click="unfollow_user"][phx-value-id="#{followed_user.id}"]))
        |> render_click()

      assert html =~ "Unfollowed successfully"
      refute html =~ followed_user.username
      refute Federation.local_follows?(user.id, followed_user.id)
    end

    test "shows both local and remote follows", %{conn: conn, user: user} do
      followed_user = setup_user("user")
      {:ok, _} = Federation.create_local_follow(user, followed_user)

      actor = create_remote_actor(%{username: "remote_alice", domain: "example.org"})
      {:ok, _} = Federation.create_user_follow(user, actor)

      {:ok, _lv, html} = live(conn, "/following")
      assert html =~ followed_user.username
      assert html =~ "remote_alice"
      assert html =~ "example.org"
    end
  end

  describe "requires authentication" do
    test "redirects unauthenticated user to login" do
      conn = build_conn()
      {:error, {:redirect, %{to: to}}} = live(conn, "/following")
      assert to =~ "/login"
    end
  end
end
