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

    test "round-trip encrypt/decrypt produces original plaintext (RFC 8291)" do
      # Generate subscriber keypair (simulates browser-side keys)
      {subscriber_pub, subscriber_priv} = :crypto.generate_key(:ecdh, :prime256v1)
      subscriber_auth = :crypto.strong_rand_bytes(16)

      plaintext = ~s({"title":"Hello","body":"RFC 8291 round-trip test"})
      encrypted = WebPush.encrypt(plaintext, subscriber_pub, subscriber_auth)

      # Decrypt: parse aes128gcm wire format
      <<salt::binary-16, _rs::unsigned-big-32, idlen::8, rest::binary>> = encrypted
      <<server_public::binary-size(idlen), ciphertext_with_tag::binary>> = rest

      # Recompute ECDH shared secret from subscriber's private key + server's public key
      shared_secret = :crypto.compute_key(:ecdh, server_public, subscriber_priv, :prime256v1)

      # Derive IKM (RFC 8291 §3.4)
      auth_info = "WebPush: info\0" <> subscriber_pub <> server_public
      ikm = test_hkdf_sha256(subscriber_auth, shared_secret, auth_info, 32)

      # Derive CEK and nonce (RFC 8291 §3.3)
      cek = test_hkdf_sha256(salt, ikm, "Content-Encoding: aes128gcm\0", 16)
      nonce = test_hkdf_sha256(salt, ikm, "Content-Encoding: nonce\0", 12)

      # Split ciphertext and tag (AES-128-GCM tag is last 16 bytes)
      ct_len = byte_size(ciphertext_with_tag) - 16
      <<ciphertext::binary-size(ct_len), tag::binary-16>> = ciphertext_with_tag

      # Decrypt
      padded =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)

      assert is_binary(padded), "Decryption failed (authentication error)"

      # Remove RFC 8188 padding: content ends at delimiter byte 0x02
      # padded = plaintext <> <<2>> (from encrypt/3)
      assert :binary.last(padded) == 2
      decrypted = binary_part(padded, 0, byte_size(padded) - 1)

      assert decrypted == plaintext
    end

    test "round-trip works with various payload sizes" do
      {subscriber_pub, subscriber_priv} = :crypto.generate_key(:ecdh, :prime256v1)
      subscriber_auth = :crypto.strong_rand_bytes(16)

      for size <- [0, 1, 16, 100, 1000, 3900] do
        plaintext = :binary.copy(<<0x41>>, size)
        encrypted = WebPush.encrypt(plaintext, subscriber_pub, subscriber_auth)

        decrypted = test_decrypt(encrypted, subscriber_pub, subscriber_priv, subscriber_auth)
        assert decrypted == plaintext, "Round-trip failed for #{size}-byte payload"
      end
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

  describe "deliver_notification/1 with soft-deleted article" do
    test "succeeds when article is soft-deleted", %{user: user, actor: actor} do
      _sub = create_subscription(user)

      article = create_article(user)
      notification = create_notification_with_article(user, actor, article)

      # Soft-delete the article
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(
        from(a in Baudrate.Content.Article, where: a.id == ^article.id),
        set: [deleted_at: now]
      )

      Req.Test.stub(Baudrate.Notification.WebPush, fn conn ->
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      # Should succeed without crashing — soft-deleted article
      # causes fallback body/url instead of showing deleted content
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

  defp create_article(user) do
    uid = System.unique_integer([:positive])

    {:ok, article} =
      %Baudrate.Content.Article{}
      |> Baudrate.Content.Article.changeset(%{
        title: "Test Article #{uid}",
        body: "Article body for testing",
        slug: "test-article-#{uid}",
        user_id: user.id
      })
      |> Repo.insert()

    article
  end

  defp create_notification_with_article(user, actor, article) do
    {:ok, notification} =
      %Baudrate.Notification.Notification{}
      |> Baudrate.Notification.Notification.changeset(%{
        type: "reply_to_article",
        user_id: user.id,
        actor_user_id: actor.id,
        article_id: article.id
      })
      |> Repo.insert()

    notification
  end

  # RFC 8291 decryption for round-trip testing
  defp test_decrypt(encrypted, subscriber_pub, subscriber_priv, subscriber_auth) do
    <<salt::binary-16, _rs::unsigned-big-32, idlen::8, rest::binary>> = encrypted
    <<server_public::binary-size(idlen), ciphertext_with_tag::binary>> = rest

    shared_secret = :crypto.compute_key(:ecdh, server_public, subscriber_priv, :prime256v1)

    auth_info = "WebPush: info\0" <> subscriber_pub <> server_public
    ikm = test_hkdf_sha256(subscriber_auth, shared_secret, auth_info, 32)

    cek = test_hkdf_sha256(salt, ikm, "Content-Encoding: aes128gcm\0", 16)
    nonce = test_hkdf_sha256(salt, ikm, "Content-Encoding: nonce\0", 12)

    ct_len = byte_size(ciphertext_with_tag) - 16
    <<ciphertext::binary-size(ct_len), tag::binary-16>> = ciphertext_with_tag

    padded = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)
    binary_part(padded, 0, byte_size(padded) - 1)
  end

  defp test_hkdf_sha256(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    test_hkdf_expand(prk, info, length, 1, <<>>, <<>>)
  end

  defp test_hkdf_expand(_prk, _info, length, _counter, _prev, acc)
       when byte_size(acc) >= length do
    binary_part(acc, 0, length)
  end

  defp test_hkdf_expand(prk, info, length, counter, prev, acc) do
    t = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<counter>>)
    test_hkdf_expand(prk, info, length, counter + 1, t, acc <> t)
  end
end
