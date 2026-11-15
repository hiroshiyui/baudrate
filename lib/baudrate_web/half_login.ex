defmodule BaudrateWeb.HalfLogin do
  @moduledoc """
  The state of a sign-in whose password has verified and whose second factor
  is still pending or being enrolled.

  It lives only in the cookie session, and `Plug.Session.COOKIE` never expires
  a cookie it can decrypt — `max_age` only sets the browser's expiry. So the
  state carries its own limits: when the password step happened, and a
  fingerprint of the account's credentials at that moment. `user/1` answers
  only while both hold:

    * **at most 10 minutes old** — the time it takes to fetch a phone, not
      a cookie kept for later;
    * **the credentials are unchanged** — a password change, a recovery reset
      or a second-factor change makes every earlier half-login worthless.

  Before this, a copy of a half-login cookie stayed good until
  `SECRET_KEY_BASE` rotated: whoever once knew a password could change it
  back into a session after the owner had changed it, with one phished TOTP
  code or recovery code — or, after an admin cleared the account's second
  factor, by enrolling their own.
  """

  import Plug.Conn

  alias Baudrate.Auth

  @max_age_seconds 600

  @doc "Starts a half-login for `user`. The caller renews the session first."
  @spec put(Plug.Conn.t(), %{id: integer()}) :: Plug.Conn.t()
  def put(conn, user) do
    Enum.reduce(session(user), conn, fn {k, v}, conn -> put_session(conn, k, v) end)
  end

  @doc "The session values of a half-login for `user` started now."
  @spec session(%{id: integer()}) :: %{atom() => term()}
  def session(user) do
    %{
      user_id: user.id,
      half_login_at: System.system_time(:second),
      half_login_stamp: stamp(user)
    }
  end

  @doc """
  The user of a live half-login, or `nil` when there is none, it is older
  than #{@max_age_seconds} seconds, or the account's credentials changed since.
  Takes a conn or a LiveView session map.
  """
  @spec user(Plug.Conn.t() | map()) :: struct() | nil
  def user(%Plug.Conn{} = conn) do
    user(%{
      "user_id" => get_session(conn, :user_id),
      "half_login_at" => get_session(conn, :half_login_at),
      "half_login_stamp" => get_session(conn, :half_login_stamp)
    })
  end

  def user(%{"user_id" => user_id, "half_login_at" => at, "half_login_stamp" => stamp})
      when is_integer(user_id) and is_integer(at) and is_binary(stamp) do
    age = System.system_time(:second) - at

    with true <- age >= 0 and age <= @max_age_seconds,
         %{} = user <- Auth.get_user(user_id),
         true <- Plug.Crypto.secure_compare(stamp(user), stamp) do
      user
    else
      _ -> nil
    end
  end

  def user(_session), do: nil

  @doc "The session keys this module writes."
  @spec keys() :: [atom()]
  def keys, do: [:user_id, :half_login_at, :half_login_stamp]

  # What a half-login is bound to: the password hash and whether a second
  # factor is enrolled. Keyed with the endpoint secret, so the cookie carries
  # nothing derived from the hash that could be checked offline.
  defp stamp(user) do
    material = "#{user.id}|#{user.hashed_password}|#{user.totp_enabled}"
    key = BaudrateWeb.Endpoint.config(:secret_key_base)

    :crypto.mac(:hmac, :sha256, key, "half_login:" <> material)
    |> Base.url_encode64(padding: false)
  end
end
