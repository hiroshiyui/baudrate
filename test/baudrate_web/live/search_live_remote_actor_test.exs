defmodule BaudrateWeb.SearchLiveRemoteActorTest do
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

  defp create_remote_actor(attrs) do
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

  defp stub_remote_lookup(username \\ "alice", domain \\ "remote.example") do
    {public_pem, _private_pem} = KeyStore.generate_keypair()

    actor_json =
      Jason.encode!(%{
        "id" => "https://#{domain}/users/#{username}",
        "type" => "Person",
        "preferredUsername" => username,
        "inbox" => "https://#{domain}/users/#{username}/inbox",
        "publicKey" => %{
          "id" => "https://#{domain}/users/#{username}#main-key",
          "owner" => "https://#{domain}/users/#{username}",
          "publicKeyPem" => public_pem
        }
      })

    webfinger_json =
      Jason.encode!(%{
        "subject" => "acct:#{username}@#{domain}",
        "links" => [
          %{
            "rel" => "self",
            "type" => "application/activity+json",
            "href" => "https://#{domain}/users/#{username}"
          }
        ]
      })

    Req.Test.stub(HTTPClient, fn conn ->
      cond do
        String.contains?(conn.request_path, ".well-known/webfinger") ->
          Plug.Conn.send_resp(conn, 200, webfinger_json)

        true ->
          Plug.Conn.send_resp(conn, 200, actor_json)
      end
    end)
  end

  describe "remote actor lookup" do
    test "searching @user@domain triggers remote actor lookup", %{conn: conn} do
      stub_remote_lookup()
      {:ok, lv, _html} = live(conn, "/search?q=@alice@remote.example")

      # Wait for async lookup to complete
      html = render_async(lv)
      assert html =~ "alice"
      assert html =~ "remote.example"
    end

    test "searching https:// actor URL triggers lookup", %{conn: conn} do
      stub_remote_lookup()
      {:ok, lv, _html} = live(conn, "/search?q=https://remote.example/users/alice")

      html = render_async(lv)
      assert html =~ "alice"
      assert html =~ "remote.example"
    end

    test "regular text search does NOT trigger remote actor lookup", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/search?q=hello+world")

      # Should not show loading indicator or remote actor card
      refute html =~ "Looking up remote actor"
      refute html =~ "Remote actor"
    end

    test "authenticated user sees Follow button", %{conn: conn} do
      stub_remote_lookup()
      {:ok, lv, _html} = live(conn, "/search?q=@alice@remote.example")

      html = render_async(lv)
      assert html =~ "Follow"
      refute html =~ "Sign in to follow"
    end

    test "guest user sees Sign in to follow", %{conn: _conn} do
      stub_remote_lookup()
      guest_conn = build_conn()

      {:ok, lv, _html} = live(guest_conn, "/search?q=@alice@remote.example")

      html = render_async(lv)
      assert html =~ "Sign in to follow"
      refute html =~ ~r/phx-click="follow"/
    end

    test "follow button triggers follow and shows pending state", %{conn: conn, user: user} do
      remote_actor = create_remote_actor(%{username: "bob", domain: "other.example"})

      # Stub HTTP to return existing actor for lookup
      actor_json =
        Jason.encode!(%{
          "id" => remote_actor.ap_id,
          "type" => "Person",
          "preferredUsername" => "bob",
          "inbox" => remote_actor.inbox,
          "publicKey" => %{
            "id" => "#{remote_actor.ap_id}#main-key",
            "owner" => remote_actor.ap_id,
            "publicKeyPem" => remote_actor.public_key_pem
          }
        })

      webfinger_json =
        Jason.encode!(%{
          "subject" => "acct:bob@other.example",
          "links" => [
            %{
              "rel" => "self",
              "type" => "application/activity+json",
              "href" => remote_actor.ap_id
            }
          ]
        })

      Req.Test.stub(HTTPClient, fn conn ->
        cond do
          String.contains?(conn.request_path, ".well-known/webfinger") ->
            Plug.Conn.send_resp(conn, 200, webfinger_json)

          true ->
            Plug.Conn.send_resp(conn, 200, actor_json)
        end
      end)

      {:ok, lv, _html} = live(conn, "/search?q=@bob@other.example")
      render_async(lv)

      html = lv |> element("button[phx-click=follow]") |> render_click()
      assert html =~ "Follow request sent"

      # Verify follow record exists
      assert Federation.user_follows?(user.id, remote_actor.id)
    end

    test "unfollow button triggers unfollow", %{conn: conn, user: user} do
      remote_actor = create_remote_actor(%{username: "carol", domain: "third.example"})
      {:ok, _follow} = Federation.create_user_follow(user, remote_actor)

      # Stub HTTP for delivery
      Req.Test.stub(HTTPClient, fn conn ->
        case conn.method do
          "POST" ->
            Plug.Conn.send_resp(conn, 202, "")

          "GET" ->
            actor_json =
              Jason.encode!(%{
                "id" => remote_actor.ap_id,
                "type" => "Person",
                "preferredUsername" => "carol",
                "inbox" => remote_actor.inbox,
                "publicKey" => %{
                  "id" => "#{remote_actor.ap_id}#main-key",
                  "owner" => remote_actor.ap_id,
                  "publicKeyPem" => remote_actor.public_key_pem
                }
              })

            webfinger_json =
              Jason.encode!(%{
                "subject" => "acct:carol@third.example",
                "links" => [
                  %{
                    "rel" => "self",
                    "type" => "application/activity+json",
                    "href" => remote_actor.ap_id
                  }
                ]
              })

            cond do
              String.contains?(conn.request_path, ".well-known/webfinger") ->
                Plug.Conn.send_resp(conn, 200, webfinger_json)

              true ->
                Plug.Conn.send_resp(conn, 200, actor_json)
            end
        end
      end)

      {:ok, lv, _html} = live(conn, "/search?q=@carol@third.example")
      render_async(lv)

      html = lv |> element("button[phx-click=unfollow]") |> render_click()
      assert html =~ "Unfollowed successfully"

      refute Federation.user_follows?(user.id, remote_actor.id)
    end
  end
end
