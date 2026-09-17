defmodule BaudrateWeb.ExportController do
  @moduledoc """
  Serves a data export archive: `POST /exports/:id/download` (ADR 0023 §16).

  `DataExportLive` re-authenticates the user, issues a single-use token and
  submits it here via `phx-trigger-action`. Nothing downloadable is ever
  reachable by a plain link.

  ## Checks, in order

  1. **Fetch Metadata.** The request must be a same-origin, top-level
     navigation (`Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode: navigate`,
     `Sec-Fetch-Dest: document`). A `fetch()`/XHR from injected script, a
     frame, or another site gets 403, so an XSS bug cannot read the ZIP and
     exfiltrate it through a same-origin channel.
  2. **Token.** A `Phoenix.Token` salted `"data_export_download"`, valid 60 s,
     for this request id, this user, and this **session row**. Its nonce is
     consumed atomically (`DataPortability.DownloadNonces`), so it works once.
  3. **Request.** Still downloadable (`DataPortability.fetch_downloadable/2`).
     Then the archive is built, and only after a successful build is the
     download counted (`claim_download/2`), so a busy slot or a failed build
     does not use up one of the three downloads.

  Every failure after step 1 answers **404 with the same body**, whether the
  request does not exist, belongs to someone else, or has expired, so the
  endpoint is no ownership oracle. A busy build slot answers 503 with
  `Retry-After`.

  The response is `Content-Disposition: attachment`, `Cache-Control: no-store`,
  and `X-Content-Type-Options: nosniff`. The temporary archive is deleted after
  sending, including when the client aborts.
  """

  use BaudrateWeb, :controller

  require Logger

  alias Baudrate.{Auth, DataPortability}
  alias Baudrate.DataPortability.{Archive, DownloadNonces}

  @token_salt "data_export_download"
  @token_max_age 60

  @doc "Token salt shared with `DataExportLive`."
  def token_salt, do: @token_salt

  @doc "Handles the download POST."
  def download(conn, %{"id" => id_param} = params) do
    with :ok <- check_fetch_metadata(conn),
         {:ok, request_id} <- parse_id(id_param),
         {:ok, user, session_id} <- current_user_and_session(conn),
         {:ok, claims} <- verify_token(conn, params["token"]),
         :ok <- match_claims(claims, request_id, user.id, session_id),
         :ok <- DownloadNonces.consume(claims["nonce"], user.id),
         %DataPortability.ExportRequest{} <-
           DataPortability.fetch_downloadable(user.id, request_id) || :not_found do
      build_and_send(conn, user, request_id)
    else
      {:error, :fetch_metadata} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(403, "Forbidden")

      _ ->
        not_found(conn)
    end
  end

  defp check_fetch_metadata(conn) do
    if header(conn, "sec-fetch-site") == "same-origin" and
         header(conn, "sec-fetch-mode") == "navigate" and
         header(conn, "sec-fetch-dest") == "document" do
      :ok
    else
      Logger.warning("data_export.download_refused: reason=fetch_metadata")
      {:error, :fetch_metadata}
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp parse_id(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp current_user_and_session(conn) do
    with token when is_binary(token) <- get_session(conn, :session_token),
         {:ok, user} <- Auth.get_user_by_session_token(token),
         session_id when is_integer(session_id) <- Auth.session_id_by_token(token) do
      {:ok, user, session_id}
    else
      _ -> :error
    end
  end

  defp verify_token(conn, token) when is_binary(token) do
    Phoenix.Token.verify(conn, @token_salt, token, max_age: @token_max_age)
  end

  defp verify_token(_conn, _token), do: :error

  defp match_claims(
         %{"request_id" => request_id, "user_id" => user_id, "session_id" => session_id},
         request_id,
         user_id,
         session_id
       ),
       do: :ok

  defp match_claims(_claims, _request_id, _user_id, _session_id), do: :error

  # sobelow_skip ["Traversal.SendFile"]
  defp build_and_send(conn, user, request_id) do
    case Archive.build(user, base_url: BaudrateWeb.Endpoint.url()) do
      {:ok, info} ->
        try do
          case DataPortability.claim_download(user.id, request_id) do
            {:ok, _request} ->
              Logger.info(
                "data_export.download_sent: user_id=#{user.id} request_id=#{request_id} bytes=#{info.size}"
              )

              conn
              |> put_resp_content_type("application/zip")
              |> put_resp_header(
                "content-disposition",
                ~s(attachment; filename="#{filename(user)}")
              )
              |> put_resp_header("cache-control", "no-store")
              |> put_resp_header("x-content-type-options", "nosniff")
              |> send_file(200, info.path)

            {:error, :not_found} ->
              not_found(conn)
          end
        after
          Archive.cleanup(info)
        end

      {:error, :busy} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("text/plain")
        |> send_resp(
          503,
          gettext("Another data export is being prepared. Please try again in a minute.")
        )

      {:error, reason} ->
        Logger.error(
          "data_export.download_failed: user_id=#{user.id} request_id=#{request_id} reason=#{inspect(reason)}"
        )

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          500,
          gettext("The data export could not be prepared. Please try again later.")
        )
    end
  end

  # Local usernames are [A-Za-z0-9_], so this is safe inside the header.
  defp filename(user) do
    "baudrate-export-#{user.username}-#{Date.utc_today() |> Date.to_iso8601()}.zip"
  end

  defp not_found(conn) do
    conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not Found")
  end
end
