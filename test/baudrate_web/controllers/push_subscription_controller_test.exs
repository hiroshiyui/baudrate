defmodule BaudrateWeb.PushSubscriptionControllerTest do
  use BaudrateWeb.ConnCase

  alias Baudrate.Notification.PushSubscription
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  import Ecto.Query

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "site_name", value: "Test Forum"})

    user = setup_user("user")
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  describe "POST /api/push-subscriptions" do
    test "creates a new subscription", %{conn: conn, user: user} do
      {pub, _priv} = :crypto.generate_key(:ecdh, :prime256v1)

      params = %{
        "endpoint" => "https://push.example.com/send/test1",
        "p256dh" => Base.url_encode64(pub, padding: false),
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      conn = post(conn, ~p"/api/push-subscriptions", params)
      assert json_response(conn, 200)["status"] == "ok"

      sub = Repo.one!(from(s in PushSubscription, where: s.user_id == ^user.id))
      assert sub.endpoint == "https://push.example.com/send/test1"
    end

    test "upserts existing subscription with same endpoint", %{conn: conn, user: user} do
      {pub1, _priv1} = :crypto.generate_key(:ecdh, :prime256v1)
      auth1 = :crypto.strong_rand_bytes(16)

      # Create initial
      {:ok, _sub} =
        %PushSubscription{}
        |> PushSubscription.changeset(%{
          endpoint: "https://push.example.com/send/upsert",
          p256dh: pub1,
          auth: auth1,
          user_id: user.id
        })
        |> Repo.insert()

      # Upsert with new keys
      {pub2, _priv2} = :crypto.generate_key(:ecdh, :prime256v1)

      params = %{
        "endpoint" => "https://push.example.com/send/upsert",
        "p256dh" => Base.url_encode64(pub2, padding: false),
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      conn = post(conn, ~p"/api/push-subscriptions", params)
      assert json_response(conn, 200)["status"] == "ok"

      # Should still be one subscription
      count = Repo.aggregate(from(s in PushSubscription, where: s.user_id == ^user.id), :count)
      assert count == 1
    end

    test "returns 401 when not authenticated" do
      # Build a fresh conn with no session auth, but init a test session
      # so the browser pipeline plugs can run (setup_completed is already seeded)
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})

      params = %{
        "endpoint" => "https://push.example.com/send/unauth",
        "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      conn = post(conn, ~p"/api/push-subscriptions", params)
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "returns 422 with missing fields", %{conn: conn} do
      conn = post(conn, ~p"/api/push-subscriptions", %{})
      assert json_response(conn, 422)["errors"]
    end

    test "returns 422 with invalid base64url encoding", %{conn: conn} do
      params = %{
        "endpoint" => "https://push.example.com/send/bad",
        "p256dh" => "not-valid-base64url!!!",
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      conn = post(conn, ~p"/api/push-subscriptions", params)
      assert json_response(conn, 422)
    end
  end

  describe "DELETE /api/push-subscriptions" do
    test "deletes own subscription", %{conn: conn, user: user} do
      {pub, _priv} = :crypto.generate_key(:ecdh, :prime256v1)

      {:ok, sub} =
        %PushSubscription{}
        |> PushSubscription.changeset(%{
          endpoint: "https://push.example.com/send/delete-me",
          p256dh: pub,
          auth: :crypto.strong_rand_bytes(16),
          user_id: user.id
        })
        |> Repo.insert()

      conn = delete(conn, ~p"/api/push-subscriptions", %{"endpoint" => sub.endpoint})
      assert json_response(conn, 200)["status"] == "ok"

      refute Repo.get(PushSubscription, sub.id)
    end

    test "returns 404 for non-existent subscription", %{conn: conn} do
      conn =
        delete(conn, ~p"/api/push-subscriptions", %{
          "endpoint" => "https://push.example.com/nonexistent"
        })

      assert json_response(conn, 404)["error"] == "not_found"
    end

    test "cannot delete another user's subscription", %{conn: conn} do
      other_user = setup_user("user")
      {pub, _priv} = :crypto.generate_key(:ecdh, :prime256v1)

      {:ok, sub} =
        %PushSubscription{}
        |> PushSubscription.changeset(%{
          endpoint: "https://push.example.com/send/other-user",
          p256dh: pub,
          auth: :crypto.strong_rand_bytes(16),
          user_id: other_user.id
        })
        |> Repo.insert()

      conn = delete(conn, ~p"/api/push-subscriptions", %{"endpoint" => sub.endpoint})
      assert json_response(conn, 404)["error"] == "not_found"

      # Sub should still exist
      assert Repo.get(PushSubscription, sub.id)
    end
  end
end
