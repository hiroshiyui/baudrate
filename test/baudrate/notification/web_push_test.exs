defmodule Baudrate.Notification.WebPushTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Notification.PushSubscription
  alias Baudrate.Notification.WebPush
  alias Baudrate.Notification.VAPID
  alias Baudrate.Setup.Setting

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    user = create_user("webpush")
    actor = create_user("webpush_actor")

    # Set up VAPID keys
    {public_key_b64, encrypted_private} = VAPID.generate_keypair()
    Repo.insert!(%Setting{key: "vapid_public_key", value: public_key_b64})

    Repo.insert!(%Setting{
      key: "vapid_private_key_encrypted",
      value: Base.encode64(encrypted_private)
    })

    %{user: user, actor: actor}
  end

  describe "encrypt/3" do
    test "returns a binary with aes128gcm wire format" do
      # Generate a subscriber keypair
      {subscriber_pub, _subscriber_priv} = :crypto.generate_key(:ecdh, :prime256v1)
      subscriber_auth = :crypto.strong_rand_bytes(16)

      encrypted = WebPush.encrypt("Hello, world!", subscriber_pub, subscriber_auth)

      assert is_binary(encrypted)
      # Wire format: salt(16) + rs(4) + idlen(1) + keyid(65) + ciphertext + tag(16)
      assert byte_size(encrypted) > 86

      # Verify salt is 16 bytes at the start
      <<salt::binary-16, _rest::binary>> = encrypted
      assert byte_size(salt) == 16

      # Verify record size
      <<_salt::binary-16, rs::unsigned-big-32, _rest::binary>> = encrypted
      assert rs == 4096

      # Verify server public key length
      <<_salt::binary-16, _rs::binary-4, idlen::8, _rest::binary>> = encrypted
      assert idlen == 65
    end

    test "each encryption produces different output" do
      {subscriber_pub, _subscriber_priv} = :crypto.generate_key(:ecdh, :prime256v1)
      subscriber_auth = :crypto.strong_rand_bytes(16)

      encrypted1 = WebPush.encrypt("test", subscriber_pub, subscriber_auth)
      encrypted2 = WebPush.encrypt("test", subscriber_pub, subscriber_auth)

      refute encrypted1 == encrypted2
    end
  end

  describe "send_push/2" do
    test "returns :ok on successful delivery (201)", %{user: user} do
      sub = create_subscription(user)

      Req.Test.stub(Baudrate.Notification.WebPush, fn conn ->
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      assert :ok = WebPush.send_push(sub, ~s({"title":"Test"}))
    end

    test "deletes subscription and returns {:error, :gone} on 410", %{user: user} do
      sub = create_subscription(user)

      Req.Test.stub(Baudrate.Notification.WebPush, fn conn ->
        Plug.Conn.send_resp(conn, 410, "Gone")
      end)

      assert {:error, :gone} = WebPush.send_push(sub, ~s({"title":"Test"}))

      # Subscription should be deleted
      refute Repo.get(PushSubscription, sub.id)
    end

    test "returns {:error, {:http_error, status}} on 500", %{user: user} do
      sub = create_subscription(user)

      Req.Test.stub(Baudrate.Notification.WebPush, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Server Error")
      end)

      assert {:error, {:http_error, 500}} = WebPush.send_push(sub, ~s({"title":"Test"}))
    end
  end

  describe "deliver_notification/1" do
    test "sends to all subscriptions for the user", %{user: user, actor: actor} do
      _sub1 = create_subscription(user, "https://push.example.com/send/1")
      _sub2 = create_subscription(user, "https://push.example.com/send/2")

      notification = create_notification(user, actor)

      Req.Test.stub(Baudrate.Notification.WebPush, fn conn ->
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      assert :ok = WebPush.deliver_notification(notification)
    end

    test "returns :ok when user has no subscriptions", %{user: user, actor: actor} do
      notification = create_notification(user, actor)

      assert :ok = WebPush.deliver_notification(notification)
    end
  end

  # --- Helpers ---

  defp create_user(prefix) do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))
    uid = System.unique_integer([:positive])

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "#{prefix}_#{uid}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp create_subscription(user, endpoint \\ nil) do
    endpoint = endpoint || "https://push.example.com/send/#{System.unique_integer([:positive])}"

    {subscriber_pub, _priv} = :crypto.generate_key(:ecdh, :prime256v1)

    {:ok, sub} =
      %PushSubscription{}
      |> PushSubscription.changeset(%{
        endpoint: endpoint,
        p256dh: subscriber_pub,
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      })
      |> Repo.insert()

    sub
  end

  defp create_notification(user, actor) do
    {:ok, notification} =
      %Baudrate.Notification.Notification{}
      |> Baudrate.Notification.Notification.changeset(%{
        type: "article_liked",
        user_id: user.id,
        actor_user_id: actor.id
      })
      |> Repo.insert()

    notification
  end
end
