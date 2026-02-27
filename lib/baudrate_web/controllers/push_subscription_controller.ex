defmodule BaudrateWeb.PushSubscriptionController do
  @moduledoc """
  API controller for managing Web Push subscriptions.

  Provides create (upsert) and delete endpoints for browser push
  subscriptions. Requires an authenticated session.
  """

  use BaudrateWeb, :controller

  alias Baudrate.Auth
  alias Baudrate.Notification.PushSubscription
  alias Baudrate.Repo

  import Ecto.Query

  plug :require_session_auth

  @doc """
  Creates or updates a push subscription for the current user.

  Expects JSON body with:
  - `endpoint` — push service URL
  - `p256dh` — base64url-encoded client ECDH public key
  - `auth` — base64url-encoded client auth secret
  - `user_agent` (optional) — browser user agent string
  """
  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, p256dh} <- decode_base64url(params["p256dh"], "p256dh"),
         {:ok, auth} <- decode_base64url(params["auth"], "auth") do
      attrs = %{
        endpoint: params["endpoint"],
        p256dh: p256dh,
        auth: auth,
        user_agent: params["user_agent"],
        user_id: user.id
      }

      # Upsert: if endpoint exists, update keys; otherwise insert
      case Repo.one(from(s in PushSubscription, where: s.endpoint == ^params["endpoint"])) do
        nil ->
          case %PushSubscription{} |> PushSubscription.changeset(attrs) |> Repo.insert() do
            {:ok, _sub} ->
              json(conn, %{status: "ok"})

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: changeset_errors(changeset)})
          end

        existing ->
          if existing.user_id == user.id do
            case existing |> PushSubscription.changeset(attrs) |> Repo.update() do
              {:ok, _sub} ->
                json(conn, %{status: "ok"})

              {:error, changeset} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{errors: changeset_errors(changeset)})
            end
          else
            conn
            |> put_status(:conflict)
            |> json(%{error: "endpoint_conflict"})
          end
      end
    else
      {:error, field} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{field => ["invalid base64url encoding"]}})
    end
  end

  @doc """
  Deletes a push subscription by endpoint, scoped to the current user.

  Expects JSON body with:
  - `endpoint` — the push service URL to unsubscribe
  """
  def delete(conn, params) do
    user = conn.assigns.current_user
    endpoint = params["endpoint"]

    case Repo.one(
           from(s in PushSubscription,
             where: s.endpoint == ^endpoint and s.user_id == ^user.id
           )
         ) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      sub ->
        Repo.delete!(sub)
        json(conn, %{status: "ok"})
    end
  end

  # --- Private ---

  defp require_session_auth(conn, _opts) do
    session_token = get_session(conn, :session_token)

    if session_token do
      case Auth.get_user_by_session_token(session_token) do
        {:ok, user} ->
          assign(conn, :current_user, user)

        _ ->
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "unauthorized"})
          |> halt()
      end
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "unauthorized"})
      |> halt()
    end
  end

  defp decode_base64url(value, field) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, field}
    end
  end

  defp decode_base64url(_, field), do: {:error, field}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
