defmodule BaudrateWeb.DmImageController do
  @moduledoc """
  Serves images attached to direct messages, at `/messages/images/:id`
  (ADR 0071) — the only way to read one.

  Every request is checked against the signed-in member
  (`Messaging.accessible_dm_image/2`): a participant in the conversation,
  the uploader of an image not yet sent, or a moderator looking at a message
  an open report names. Everything else — a guest, somebody else, a deleted
  message, an id that never existed — gets the same 404, so the route cannot
  be used to learn whether an image exists.

  The response is `private, no-store`: a direct-message image must not sit in
  a shared cache, nor in the browser's disk cache on a device that may not
  be the member's alone.
  """

  use BaudrateWeb, :controller

  alias Baudrate.Auth
  alias Baudrate.Messaging

  # The path comes only from `Messaging.accessible_dm_image/2`, which rebuilds
  # it from a strict hex filename confined below the uploads root
  # (`DataPortability.Files.image_path/2`); nothing from the request reaches it.
  # sobelow_skip ["Traversal.SendFile"]
  def show(conn, %{"id" => id}) do
    with {:ok, image_id} <- parse_id(id),
         %{} = user <- current_user(conn),
         :ok <- BaudrateWeb.RateLimits.check_dm_image_view(user.id),
         {:ok, _image, path} <- Messaging.accessible_dm_image(user, image_id) do
      conn
      |> put_resp_content_type("image/webp", nil)
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, path)
    else
      {:error, :rate_limited} ->
        conn |> put_resp_header("retry-after", "300") |> send_resp(429, "")

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp current_user(conn) do
    with token when is_binary(token) <- get_session(conn, :session_token),
         {:ok, user} <- Auth.get_user_by_session_token(token) do
      user
    else
      _ -> nil
    end
  end

  defp parse_id(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end
end
