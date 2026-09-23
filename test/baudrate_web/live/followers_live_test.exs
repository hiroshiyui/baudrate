defmodule BaudrateWeb.FollowersLiveTest do
  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Federation
  alias Baudrate.Federation.{DeliveryJob, RemoteActor}
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    %{conn: log_in_user(conn, user), user: user}
  end

  test "requires signing in" do
    assert {:error, {:redirect, %{to: "/login" <> _}}} = live(build_conn(), "/followers")
  end

  test "lists both kinds of follower with their counts", %{conn: conn, user: user} do
    fan = setup_user("user")
    {:ok, _} = Federation.create_local_follow(fan, user)
    remote = follow_remotely!(user)

    {:ok, lv, _html} = live(conn, "/followers")

    assert has_element?(lv, "#follower-local-#{fan.id}")
    assert has_element?(lv, ".followers-local-count", "1")
    assert has_element?(lv, "#follower-remote-#{remote.id}", "@#{remote.remote_actor.username}")
    assert has_element?(lv, ".followers-remote-count", "1")
  end

  test "removes a member of this site, silently", %{conn: conn, user: user} do
    fan = setup_user("user")
    {:ok, _} = Federation.create_local_follow(fan, user)
    {:ok, lv, _html} = live(conn, "/followers")

    lv |> element("#follower-local-remove-#{fan.id}") |> render_click()

    refute has_element?(lv, "#follower-local-#{fan.id}")
    refute Federation.local_follows?(fan.id, user.id)
    assert_push_event(lv, "focus", %{id: "followers-heading"})
  end

  test "removes an account elsewhere with a Reject", %{conn: conn, user: user} do
    remote = follow_remotely!(user)
    {:ok, lv, _html} = live(conn, "/followers")

    lv |> element("#follower-remote-remove-#{remote.id}") |> render_click()

    refute has_element?(lv, "#follower-remote-#{remote.id}")
    assert [job] = Repo.all(DeliveryJob)
    assert Jason.decode!(job.activity_json)["type"] == "Reject"
  end

  test "a forged id removes nothing", %{conn: conn, user: _user} do
    other = setup_user("user")
    theirs = follow_remotely!(other)
    {:ok, lv, _html} = live(conn, "/followers")

    html = render_click(lv, "remove_remote", %{"id" => to_string(theirs.id)})

    assert html =~ "Could not remove that follower."
    assert Repo.all(DeliveryJob) == []
  end

  # ADR 0070: a follower count compares people, so only the member sees it.
  test "the public profile shows no follower count", %{user: user} do
    fan = setup_user("user")
    {:ok, _} = Federation.create_local_follow(fan, user)
    _ = follow_remotely!(user)

    {:ok, _lv, html} = live(build_conn(), "/users/#{user.username}")
    refute html =~ ~r/follower/i
  end

  defp follow_remotely!(user) do
    n = System.unique_integer([:positive])

    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/f#{n}",
        username: "f#{n}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/f#{n}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follower} =
      Federation.create_follower(
        Federation.actor_uri(:user, user.username),
        actor,
        "https://remote.example/follows/#{n}"
      )

    Repo.preload(follower, :remote_actor)
  end
end
