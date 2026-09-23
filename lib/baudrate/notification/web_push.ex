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

  Uses the federation HTTP client for DNS-pinned, SSRF-safe HTTP POSTs to push
  service endpoints with VAPID headers. Stale subscriptions (410/404 responses)
  are automatically cleaned up.
  """

  require Logger

  import Ecto.Query

  use Gettext, backend: BaudrateWeb.Gettext

  alias Baudrate.Notification.PushSubscription
  alias Baudrate.Notification.VAPID

  @security_types Baudrate.Notification.Notification.always_delivered_types()
  alias Baudrate.Notification.VapidVault
  alias Baudrate.Repo
  alias Baudrate.Setup

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
    # PRK = HKDF-Extract(salt=auth_secret, IKM=ecdh_secret)
    # hkdf_sha256(salt, ikm, ...) → :crypto.mac(:hmac, :sha256, salt, ikm)
    # This is correct: salt=subscriber_auth, IKM=shared_secret per RFC 8291
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

      case Baudrate.Federation.HTTPClient.post_raw(subscription.endpoint, encrypted, headers) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:error, {:http_error, status, _body}} when status in [404, 410] ->
          Repo.delete(subscription)
          {:error, :gone}

        {:error, {:http_error, status, _body}} ->
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
    notification =
      Repo.preload(notification, [:user, :actor_user, :actor_remote_actor, :article, :comment])

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

  @doc """
  Pushes "New message from …" to every subscription `recipient` holds
  (ADR 0071).

  **The payload carries no message text.** It is encrypted on its way through
  the browser vendor's push service, but a phone shows it on the lock screen
  to whoever is holding it, and a direct message is the private channel. The
  `type` is `"dm-<conversation_id>"`, which the service worker uses as the
  notification `tag`, so a burst from one conversation replaces itself
  instead of stacking.

  `sender` is a local `%User{}` or a `%RemoteActor{}`. Whether to send at all
  is `Baudrate.Messaging.Push`'s decision.
  """
  def deliver_direct_message(%Baudrate.Setup.User{} = recipient, sender, conversation_id) do
    subscriptions =
      from(s in PushSubscription, where: s.user_id == ^recipient.id)
      |> Repo.all()

    if subscriptions != [] do
      payload_json = recipient |> build_dm_payload(sender, conversation_id) |> Jason.encode!()

      Enum.each(subscriptions, fn sub ->
        case send_push(sub, payload_json) do
          :ok -> :ok
          {:error, :gone} -> Logger.debug("Removed stale push subscription #{sub.endpoint}")
          {:error, reason} -> Logger.warning("Push delivery failed: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  @doc """
  The payload `deliver_direct_message/3` sends: a title naming the sender in
  the recipient's language, an **empty body**, the conversation's URL, a
  per-conversation `type` and the sender's avatar.
  """
  def build_dm_payload(%Baudrate.Setup.User{} = recipient, sender, conversation_id) do
    title =
      with_recipient_locale(%{user: recipient}, fn ->
        gettext("New message from %{name}", name: dm_sender_name(sender))
      end)

    %{
      title: title,
      body: "",
      url: BaudrateWeb.Endpoint.url() <> "/messages/#{conversation_id}",
      type: "dm-#{conversation_id}",
      icon: dm_sender_icon(sender)
    }
  end

  defp dm_sender_name(%Baudrate.Setup.User{} = user), do: BaudrateWeb.Helpers.display_name(user)
  defp dm_sender_name(%{username: username, domain: domain}), do: "#{username}@#{domain}"

  defp dm_sender_icon(%Baudrate.Setup.User{avatar_id: avatar_id}) when not is_nil(avatar_id),
    do: BaudrateWeb.Endpoint.url() <> Baudrate.Avatar.avatar_url(avatar_id, 120)

  defp dm_sender_icon(_sender), do: nil

  # --- Private helpers ---

  defp load_vapid_keys do
    public_key_b64 = Setup.get_setting("vapid_public_key")
    encrypted_private = Setup.get_setting("vapid_private_key_encrypted")

    cond do
      is_nil(public_key_b64) or is_nil(encrypted_private) ->
        {:error, :vapid_not_configured}

      true ->
        # The encrypted private key is stored as base64. A settings row that
        # is not valid Base64 is as unusable as one that fails to decrypt, and
        # push is a background job: report it, never raise.
        with {:ok, encrypted_binary} <- Base.decode64(encrypted_private),
             {:ok, private_key} <- VapidVault.decrypt(encrypted_binary) do
          {:ok, public_key_b64, private_key}
        else
          _ -> {:error, :vapid_decrypt_failed}
        end
    end
  end

  @doc """
  Builds the push payload map (`title`, `body`, `url`, `type`, `icon`) for a
  notification whose `:user`, `:actor_user`, `:actor_remote_actor`,
  `:article` and `:comment` associations are preloaded. A notification about
  a comment links to the page of the thread it is on.

  Account security notices (`Notification.security_types/0`) are rendered in
  the recipient's preferred locale and link to `/profile/security`, where the security
  keys and TOTP settings live. Data export notices link to `/profile/export`
  `totp_login_failed` to `/profile/password`, and `account_*` notices to
  `/profile/move`.
  """
  def build_payload(notification) do
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

  # Titles mirror the in-app notification list: the actor's name followed by
  # the same translated `Helpers.notification_text/1` fragment, rendered in the
  # recipient's preferred locale. Account security notices have no actor and
  # their text is already a full sentence. Deriving titles from the shared
  # text keeps every notification type covered; a separate hard-coded list
  # here drifted (comment likes and boosts fell through to a generic title)
  # and was English-only.
  defp notification_title(%{type: type} = notification) when type in @security_types do
    with_recipient_locale(notification, fn -> BaudrateWeb.Helpers.notification_text(type) end)
  end

  defp notification_title(%{type: type} = notification) do
    with_recipient_locale(notification, fn ->
      "#{actor_display_name(notification)} #{BaudrateWeb.Helpers.notification_text(type)}"
    end)
  end

  defp notification_body(%{type: type} = notification) when type in @security_types do
    get_in(notification.data || %{}, ["label"]) || ""
  end

  defp notification_body(notification) do
    case notification.type do
      "admin_announcement" ->
        get_in(notification.data || %{}, ["message"]) || ""

      type when type in ["actor_moved", "board_actor_moved"] ->
        get_in(notification.data || %{}, ["label"]) || ""

      _ ->
        if notification.article && is_nil(notification.article.deleted_at) do
          notification.article.title || ""
        else
          ""
        end
    end
  end

  defp notification_url(%{type: "data_export_" <> _}) do
    BaudrateWeb.Endpoint.url() <> "/profile/export"
  end

  defp notification_url(%{type: "account_deletion_" <> _}) do
    BaudrateWeb.Endpoint.url() <> "/profile/account"
  end

  defp notification_url(%{type: "account_" <> _}) do
    BaudrateWeb.Endpoint.url() <> "/profile/move"
  end

  defp notification_url(%{type: "totp_login_failed"}) do
    BaudrateWeb.Endpoint.url() <> "/profile/password"
  end

  defp notification_url(%{type: type}) when type in @security_types do
    BaudrateWeb.Endpoint.url() <> "/profile/security"
  end

  defp notification_url(notification) do
    base = BaudrateWeb.Endpoint.url()

    cond do
      # A comment is linked on the page it is on, for the recipient — a bare
      # `#comment-N` only finds it on page 1.
      notification.article && is_nil(notification.article.deleted_at) &&
          match?(%Baudrate.Content.Comment{}, notification.comment) ->
        base <>
          BaudrateWeb.Helpers.comment_link(
            notification.article,
            notification.comment,
            notification.user
          )

      notification.article && is_nil(notification.article.deleted_at) ->
        "#{base}/articles/#{notification.article.slug}"

      notification.type == "new_follower" ->
        "#{base}/notifications"

      true ->
        "#{base}/notifications"
    end
  end

  defp with_recipient_locale(%{user: %Baudrate.Setup.User{preferred_locales: locales}}, fun) do
    case BaudrateWeb.Locale.resolve_from_preferences(locales) do
      nil -> fun.()
      locale -> Gettext.with_locale(BaudrateWeb.Gettext, locale, fun)
    end
  end

  defp with_recipient_locale(_notification, fun), do: fun.()

  defp notification_icon(notification) do
    case notification do
      %{actor_user: %{avatar_id: avatar_id}} when not is_nil(avatar_id) ->
        # Avatars are stored per size (`avatars/<id>/<size>.webp`); there is no
        # unsized file. 120 px is the largest rendition.
        BaudrateWeb.Endpoint.url() <> Baudrate.Avatar.avatar_url(avatar_id, 120)

      _ ->
        nil
    end
  end

  # Same naming as `BaudrateWeb.NotificationsLive`: a local user's display name
  # (falling back to the username), or `username@domain` for a remote actor.
  defp actor_display_name(%{actor_user: %Baudrate.Setup.User{} = user}),
    do: BaudrateWeb.Helpers.display_name(user)

  defp actor_display_name(%{actor_remote_actor: %{username: username, domain: domain}}),
    do: "#{username}@#{domain}"

  defp actor_display_name(_notification), do: gettext("Someone")

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
