defmodule BaudrateWeb.ExportControllerTest do
  @moduledoc """
  The data export download endpoint (ADR 0023 §16): Fetch Metadata, a
  single-use token bound to the session, and no ownership oracle.
  """

  # Per-test uploads root via application env.
  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query

  alias Baudrate.{Auth, DataPortability, Repo}
  alias Baudrate.DataPortability.{Archive, DownloadNonces, ExportRequest}
  alias Baudrate.Setup.{Setting, User}
  alias BaudrateWeb.ExportController

  @password "Password123!x"

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})

    root =
      Path.join(System.tmp_dir!(), "baudrate-export-ctl-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    Application.put_env(:baudrate, :data_export_uploads_root, root)

    on_exit(fn ->
      Application.delete_env(:baudrate, :data_export_uploads_root)
      File.rm_rf(root)
    end)

    user = setup_user("user")
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)
    eight_days_ago = DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.truncate(:second)

    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [totp_enabled_at: eight_days_ago]
    )

    user = Repo.reload!(user)

    {:ok, request} =
      DataPortability.request_export(
        user,
        %{password: @password, code: totp_code(secret)},
        ip_address: "203.0.113.1"
      )

    request = make_ready(request)
    conn = log_in_user(conn, user)
    session_id = Auth.session_id_by_token(Plug.Conn.get_session(conn, :session_token))

    %{conn: conn, user: user, request: request, session_id: session_id}
  end

  defp make_ready(request) do
    shift = DataPortability.ready_delay_seconds() + 60

    Repo.update_all(from(r in ExportRequest, where: r.id == ^request.id),
      set: [
        requested_at: DateTime.add(request.requested_at, -shift),
        ready_at: DateTime.add(request.ready_at, -shift),
        expires_at: DateTime.add(request.expires_at, -shift)
      ]
    )

    Repo.reload!(request)
  end

  defp token(user, request, session_id, opts \\ []) do
    Phoenix.Token.sign(
      BaudrateWeb.Endpoint,
      ExportController.token_salt(),
      %{
        "request_id" => Keyword.get(opts, :request_id, request.id),
        "user_id" => Keyword.get(opts, :user_id, user.id),
        "session_id" => session_id,
        "nonce" => Keyword.get_lazy(opts, :nonce, fn -> DownloadNonces.issue(user.id) end)
      },
      Keyword.take(opts, [:signed_at])
    )
  end

  defp navigate(conn) do
    conn
    |> put_req_header("sec-fetch-site", "same-origin")
    |> put_req_header("sec-fetch-mode", "navigate")
    |> put_req_header("sec-fetch-dest", "document")
  end

  defp download(conn, request_id, token) do
    post(conn, "/exports/#{request_id}/download", %{"token" => token})
  end

  test "a valid token downloads the archive once, with safe headers",
       %{conn: conn, user: user, request: request, session_id: session_id} do
    before = temp_dirs()
    t = token(user, request, session_id)

    resp = conn |> navigate() |> download(request.id, t)

    assert resp.status == 200
    assert get_resp_header(resp, "content-type") |> hd() =~ "application/zip"
    assert get_resp_header(resp, "cache-control") == ["no-store"]
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
    assert [disposition] = get_resp_header(resp, "content-disposition")
    assert disposition =~ ~s(attachment; filename="baudrate-export-#{user.username}-)
    assert <<"PK", _::binary>> = resp.resp_body

    assert Repo.reload!(request).download_count == 1
    # The temporary archive is gone.
    assert temp_dirs() == before

    # The same token cannot be replayed.
    replay = conn |> navigate() |> download(request.id, t)
    assert replay.status == 404
    assert Repo.reload!(request).download_count == 1
  end

  test "requests that are not a same-origin top-level navigation get 403",
       %{conn: conn, user: user, request: request, session_id: session_id} do
    for headers <- [
          [],
          [
            {"sec-fetch-site", "same-origin"},
            {"sec-fetch-mode", "cors"},
            {"sec-fetch-dest", "empty"}
          ],
          [
            {"sec-fetch-site", "cross-site"},
            {"sec-fetch-mode", "navigate"},
            {"sec-fetch-dest", "document"}
          ],
          [
            {"sec-fetch-site", "same-origin"},
            {"sec-fetch-mode", "navigate"},
            {"sec-fetch-dest", "iframe"}
          ]
        ] do
      c = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
      resp = download(c, request.id, token(user, request, session_id))
      assert resp.status == 403
    end

    assert Repo.reload!(request).download_count == 0
  end

  test "every token or request problem answers the same 404",
       %{conn: conn, user: user, request: request, session_id: session_id} do
    other = setup_user("user")

    cases = [
      {request.id, nil},
      {request.id, "garbage"},
      # Wrong request id in the path.
      {request.id + 1_000, token(user, request, session_id)},
      # Token for a different request id.
      {request.id, token(user, request, session_id, request_id: request.id + 1_000)},
      # Token for another user.
      {request.id, token(user, request, session_id, user_id: other.id)},
      # Token bound to another session of the same user.
      {request.id, token(user, request, session_id + 10_000)},
      # Nonce never issued.
      {request.id, token(user, request, session_id, nonce: "not-issued")},
      # Expired token.
      {request.id, token(user, request, session_id, signed_at: System.system_time(:second) - 120)}
    ]

    for {path_id, t} <- cases do
      resp = conn |> navigate() |> download(path_id, t)
      assert resp.status == 404
      assert resp.resp_body == "Not Found"
    end

    assert Repo.reload!(request).download_count == 0
  end

  test "a request that is not ready, or is cancelled, answers 404",
       %{conn: conn, user: user, request: request, session_id: session_id} do
    {:ok, _} = DataPortability.cancel_export(user.id, request.id)

    resp = conn |> navigate() |> download(request.id, token(user, request, session_id))
    assert resp.status == 404
  end

  test "signed-out requests answer 404", %{user: user, request: request, session_id: session_id} do
    resp =
      build_conn()
      |> navigate()
      |> download(request.id, token(user, request, session_id))

    assert resp.status == 404
  end

  test "a busy build slot answers 503 and does not use up a download",
       %{conn: conn, user: user, request: request, session_id: session_id} do
    config = Repo.config() |> Keyword.drop([:pool, :pool_size, :ownership_timeout])
    {:ok, pg} = Postgrex.start_link(config)
    Postgrex.query!(pg, "SELECT pg_advisory_lock($1)", [Archive.lock_key()])

    try do
      resp = conn |> navigate() |> download(request.id, token(user, request, session_id))
      assert resp.status == 503
      assert get_resp_header(resp, "retry-after") == ["60"]
      assert Repo.reload!(request).download_count == 0
    after
      Postgrex.query!(pg, "SELECT pg_advisory_unlock($1)", [Archive.lock_key()])
      GenServer.stop(pg)
    end
  end

  defp temp_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "baudrate-export-"))
    |> Enum.reject(&String.starts_with?(&1, "baudrate-export-ctl-"))
    |> Enum.reject(&String.starts_with?(&1, "baudrate-export-test-"))
    |> MapSet.new()
  end
end
