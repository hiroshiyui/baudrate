defmodule Baudrate.Notification.WebPush do
  @moduledoc """
  Web Push content encryption (RFC 8291) and delivery.

  Encrypts push notification payloads using the aes128gcm content encoding
  scheme and delivers them to push service endpoints with VAPID authentication.

  ## Encryption (RFC 8291 + RFC 8188)

  1. Generate ephemeral ECDH keypair (P-256)
  2. Compute shared secret via ECDH
  3. Derive IKM from auth secret + shared secret (HKDF-SHA256)
  4. Derive content encryption key (CEK, 16 bytes) and nonce (12 bytes) from IKM
  5. Pad plaintext with RFC 8188 delimiter byte (`\\x02`)
  6. AES-128-GCM encrypt
  7. Assemble aes128gcm wire format

  ## Delivery

  Uses `Req` for HTTP POST to push service endpoints with VAPID headers.
  Stale subscriptions (410/404 responses) are automatically cleaned up.
  """

  require Logger

  import Ecto.Query

  alias Baudrate.Notification.PushSubscription
  alias Baudrate.Notification.VAPID
  alias Baudrate.Notification.VapidVault
  alias Baudrate.Repo
  alias Baudrate.Setup

  @req_test_options Application.compile_env(:baudrate, :req_web_push_test_options, [])

  # --- Public API ---

  @doc """
  Encrypts a plaintext payload for Web Push delivery using RFC 8291.

  ## Parameters

  - `plaintext` — the notification payload (typically JSON)
  - `subscriber_p256dh` — the subscriber's P-256 ECDH public key (65 bytes, raw)
  - `subscriber_auth` — the subscriber's auth secret (16 bytes)

  Returns the aes128gcm wire-format binary:

      salt(16) || rs(4) || idlen(1) || keyid(65) || ciphertext || tag(16)
  """
  def encrypt(plaintext, subscriber_p256dh, subscriber_auth) do
    # Generate ephemeral ECDH keypair
    {server_public, server_private} = :crypto.generate_key(:ecdh, :prime256v1)

    # ECDH shared secret
    shared_secret = :crypto.compute_key(:ecdh, subscriber_p256dh, server_private, :prime256v1)

    # Generate random salt
    salt = :crypto.strong_rand_bytes(16)

    # Derive IKM from auth secret (RFC 8291 §3.4)
    # info = "WebPush: info\0" || ua_public || as_public
    auth_info = "WebPush: info\0" <> subscriber_p256dh <> server_public
    ikm = hkdf_sha256(subscriber_auth, shared_secret, auth_info, 32)

    # Derive CEK and nonce from IKM (RFC 8291 §3.3)
    cek_info = "Content-Encoding: aes128gcm\0"
    nonce_info = "Content-Encoding: nonce\0"

    cek = hkdf_sha256(salt, ikm, cek_info, 16)
    nonce = hkdf_sha256(salt, ikm, nonce_info, 12)

    # Pad plaintext (RFC 8188 §2: content || delimiter || padding)
    # delimiter 0x02 = final record
    padded = plaintext <> <<2>>

    # AES-128-GCM encrypt
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, padded, "", true)

    # Record size (4 bytes, big-endian) — max record size (4096 is standard)
    rs = <<4096::unsigned-big-32>>

    # Assemble aes128gcm header: salt(16) || rs(4) || idlen(1) || keyid(65) || encrypted
    salt <> rs <> <<byte_size(server_public)>> <> server_public <> ciphertext <> tag
  end

  @doc """
  Sends an encrypted push notification to a single subscription.

  Loads VAPID keys from settings, encrypts the payload, and POSTs to the
  push service endpoint.

  Returns:
  - `:ok` on success (2xx)
  - `{:error, :gone}` if the subscription is stale (410/404) — subscription is deleted
  - `{:error, {:http_error, status}}` for other errors
  - `{:error, :vapid_not_configured}` if VAPID keys are not set up
  """
  def send_push(%PushSubscription{} = subscription, payload) when is_binary(payload) do
    with {:ok, public_key_b64, private_key} <- load_vapid_keys() do
      p256dh = subscription.p256dh
      auth = subscription.auth

      encrypted = encrypt(payload, p256dh, auth)

      vapid_headers =
        VAPID.authorization_headers(subscription.endpoint, public_key_b64, private_key)

      headers =
        vapid_headers ++
          [
            {"content-type", "application/octet-stream"},
            {"content-encoding", "aes128gcm"},
            {"content-length", Integer.to_string(byte_size(encrypted))}
          ]

      req_opts =
        [
          url: subscription.endpoint,
          headers: headers,
          body: encrypted,
          max_retries: 0,
          decode_body: false
        ]
        |> Keyword.merge(@req_test_options)

      case Req.post(req_opts) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status}} when status in [404, 410] ->
          Repo.delete(subscription)
          {:error, :gone}

        {:ok, %Req.Response{status: status}} ->
          Logger.warning("Web push delivery failed: HTTP #{status} for #{subscription.endpoint}")
          {:error, {:http_error, status}}

        {:error, reason} ->
          Logger.warning(
            "Web push delivery error: #{inspect(reason)} for #{subscription.endpoint}"
          )

          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Delivers a push notification to all subscriptions for the notification's user.

  Builds a JSON payload from the notification and sends it to each registered
  push subscription.
  """
  def deliver_notification(%Baudrate.Notification.Notification{} = notification) do
    notification = Repo.preload(notification, [:actor_user, :actor_remote_actor, :article])

    subscriptions =
      from(s in PushSubscription, where: s.user_id == ^notification.user_id)
      |> Repo.all()

    if subscriptions == [] do
      :ok
    else
      payload = build_payload(notification)
      payload_json = Jason.encode!(payload)

      Enum.each(subscriptions, fn sub ->
        case send_push(sub, payload_json) do
          :ok -> :ok
          {:error, :gone} -> Logger.debug("Removed stale push subscription #{sub.endpoint}")
          {:error, reason} -> Logger.warning("Push delivery failed: #{inspect(reason)}")
        end
      end)

      :ok
    end
  end

  # --- Private helpers ---

  defp load_vapid_keys do
    public_key_b64 = Setup.get_setting("vapid_public_key")
    encrypted_private = Setup.get_setting("vapid_private_key_encrypted")

    cond do
      is_nil(public_key_b64) or is_nil(encrypted_private) ->
        {:error, :vapid_not_configured}

      true ->
        # The encrypted private key is stored as base64
        encrypted_binary = Base.decode64!(encrypted_private)

        case VapidVault.decrypt(encrypted_binary) do
          {:ok, private_key} -> {:ok, public_key_b64, private_key}
          :error -> {:error, :vapid_decrypt_failed}
        end
    end
  end

  defp build_payload(notification) do
    title = notification_title(notification)
    body = notification_body(notification)
    url = notification_url(notification)
    icon = notification_icon(notification)

    %{
      title: title,
      body: body,
      url: url,
      type: notification.type,
      icon: icon
    }
  end

  defp notification_title(notification) do
    actor_name = actor_display_name(notification)

    case notification.type do
      "reply_to_article" -> "#{actor_name} replied to your article"
      "reply_to_comment" -> "#{actor_name} replied to your comment"
      "mention" -> "#{actor_name} mentioned you"
      "new_follower" -> "#{actor_name} followed you"
      "article_liked" -> "#{actor_name} liked your article"
      "article_forwarded" -> "#{actor_name} shared your article"
      "moderation_report" -> "New moderation report"
      "admin_announcement" -> "Admin announcement"
      _ -> "New notification"
    end
  end

  defp notification_body(notification) do
    case notification.type do
      "admin_announcement" ->
        get_in(notification.data || %{}, ["message"]) || ""

      _ ->
        if notification.article do
          notification.article.title || ""
        else
          ""
        end
    end
  end

  defp notification_url(notification) do
    base = BaudrateWeb.Endpoint.url()

    cond do
      notification.article ->
        "#{base}/articles/#{notification.article.slug}"

      notification.type == "new_follower" ->
        "#{base}/notifications"

      true ->
        "#{base}/notifications"
    end
  end

  defp notification_icon(notification) do
    case notification do
      %{actor_user: %{avatar_id: avatar_id}} when not is_nil(avatar_id) ->
        "#{BaudrateWeb.Endpoint.url()}/uploads/avatars/#{avatar_id}.webp"

      _ ->
        nil
    end
  end

  defp actor_display_name(notification) do
    cond do
      notification.actor_user ->
        notification.actor_user.display_name || notification.actor_user.username

      notification.actor_remote_actor ->
        notification.actor_remote_actor.display_name ||
          notification.actor_remote_actor.preferred_username ||
          "Remote user"

      true ->
        "System"
    end
  end

  # HKDF-SHA256 extract-and-expand
  defp hkdf_sha256(salt, ikm, info, length) do
    # Extract
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    # Expand
    hkdf_expand(prk, info, length, 1, <<>>, <<>>)
  end

  defp hkdf_expand(_prk, _info, length, _counter, _prev, acc) when byte_size(acc) >= length do
    binary_part(acc, 0, length)
  end

  defp hkdf_expand(prk, info, length, counter, prev, acc) do
    t = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<counter>>)
    hkdf_expand(prk, info, length, counter + 1, t, acc <> t)
  end
end
