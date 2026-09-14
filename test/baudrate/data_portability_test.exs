defmodule Baudrate.DataPortabilityTest do
  use Baudrate.DataCase, async: true

  import Ecto.Query

  alias Baudrate.{Auth, DataPortability, Repo}
  alias Baudrate.Auth.LoginAttempt
  alias Baudrate.DataPortability.{ExportRequest, UserAgent}
  alias Baudrate.Notification.Notification, as: NotificationSchema
  alias Baudrate.Setup.User

  @password "Password123!x"
  @firefox "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    {user, secret} = eligible_user()
    %{user: user, secret: secret}
  end

  defp create_user(role \\ "user") do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == ^role))

    {:ok, user} =
      %User{}
      |> User.registration_changeset(%{
        "username" => "export_#{System.unique_integer([:positive])}",
        "password" => @password,
        "password_confirmation" => @password,
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  # TOTP enabled 8 days ago: eligible.
  defp eligible_user do
    user = create_user()
    secret = Auth.generate_totp_secret()
    {:ok, _} = Auth.enable_totp(user, secret)
    backdate_totp(user, 8 * 86_400)
    {Repo.reload!(user), secret}
  end

  defp backdate_totp(user, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [totp_enabled_at: at])
  end

  defp creds(secret, password \\ @password),
    do: %{password: password, code: totp_code(secret)}

  defp opts, do: [ip_address: "203.0.113.5", user_agent: @firefox]

  defp request!(user, secret) do
    {:ok, request} = DataPortability.request_export(user, creds(secret), opts())
    # The code is now used up (ADR 0024). A real user comes back with a new one.
    forget_totp_use(user)
    request
  end

  # Moves a request's timeline back by `seconds`.
  defp shift_back(request, seconds) do
    Repo.update_all(from(r in ExportRequest, where: r.id == ^request.id),
      set: [
        requested_at: DateTime.add(request.requested_at, -seconds, :second),
        ready_at: DateTime.add(request.ready_at, -seconds, :second),
        expires_at: DateTime.add(request.expires_at, -seconds, :second)
      ]
    )

    Repo.reload!(request)
  end

  defp make_ready(request), do: shift_back(request, DataPortability.ready_delay_seconds() + 60)

  defp notices(user, type) do
    Repo.all(
      from(n in NotificationSchema,
        where: n.user_id == ^user.id and n.type == ^type,
        order_by: [asc: n.id]
      )
    )
  end

  defp failed_attempts(user) do
    Repo.aggregate(
      from(a in LoginAttempt, where: a.username == ^user.username and a.success == false),
      :count
    )
  end

  describe "eligibility/1" do
    test "an active user with TOTP older than 7 days is eligible", %{user: user} do
      assert :ok = DataPortability.eligibility(user)
    end

    test "refuses bots, inactive accounts, and accounts without TOTP" do
      plain = create_user()
      assert {:error, :totp_required} = DataPortability.eligibility(plain)

      {bot, _} = eligible_user()
      assert {:error, :bot} = DataPortability.eligibility(%{bot | is_bot: true})

      {pending, _} = eligible_user()
      assert {:error, :not_active} = DataPortability.eligibility(%{pending | status: "pending"})
      assert {:error, :not_active} = DataPortability.eligibility(%{pending | status: "banned"})
    end

    test "refuses TOTP enabled less than 7 days ago and reports the days left" do
      user = create_user()
      {:ok, fresh} = Auth.enable_totp(user, Auth.generate_totp_secret())
      assert {:error, {:totp_too_new, 7}} = DataPortability.eligibility(fresh)

      backdate_totp(user, 6 * 86_400 + 3600)
      assert {:error, {:totp_too_new, 1}} = DataPortability.eligibility(Repo.reload!(user))

      # TOTP on but no timestamp fails closed.
      assert {:error, {:totp_too_new, 7}} =
               DataPortability.eligibility(%{fresh | totp_enabled_at: nil})
    end
  end

  describe "request_export/3" do
    test "creates a pending request 24 h out, stores only the browser family, notifies",
         %{user: user, secret: secret} do
      assert {:ok, request} = DataPortability.request_export(user, creds(secret), opts())

      assert request.status == "pending"
      assert request.source == "self_service"
      assert DateTime.diff(request.ready_at, request.requested_at) == 24 * 3600
      assert DateTime.diff(request.expires_at, request.ready_at) == 48 * 3600
      assert request.requested_user_agent_family == "Firefox on Linux"
      assert request.download_count == 0

      assert [%{data: %{"browser" => "Firefox on Linux"}}] =
               notices(user, "data_export_requested")
    end

    test "wrong password or TOTP is refused and recorded; no request is created",
         %{user: user, secret: secret} do
      assert {:error, :invalid_credentials} =
               DataPortability.request_export(user, creds(secret, "wrong"), opts())

      assert {:error, :invalid_credentials} =
               DataPortability.request_export(
                 user,
                 %{password: @password, code: "000000"},
                 opts()
               )

      assert failed_attempts(user) == 2
      assert Repo.aggregate(ExportRequest, :count) == 0
    end

    test "a recovery code never authorizes an export", %{user: user} do
      [code | _] = Auth.generate_recovery_codes(user)

      assert {:error, :invalid_credentials} =
               DataPortability.request_export(user, %{password: @password, code: code}, opts())
    end

    test "ineligible users are refused before re-authentication" do
      plain = create_user()

      assert {:error, :totp_required} =
               DataPortability.request_export(plain, %{password: @password}, opts())

      assert failed_attempts(plain) == 0
    end

    test "uses the database's current state, not a stale struct", %{user: user, secret: secret} do
      {:ok, _} = Auth.disable_totp(user)

      # `user` still says totp_enabled: true.
      assert {:error, :totp_required} =
               DataPortability.request_export(user, creds(secret), opts())
    end

    test "only one active request at a time, refused before re-authentication",
         %{user: user, secret: secret} do
      request!(user, secret)

      assert {:error, :active_request_exists} =
               DataPortability.request_export(user, creds(secret, "wrong"), opts())

      assert failed_attempts(user) == 0
    end

    test "the partial unique index backs the one-active-request rule", %{user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        user_id: user.id,
        status: "pending",
        source: "self_service",
        requested_at: now,
        ready_at: now,
        expires_at: now
      }

      {:ok, _} = %ExportRequest{} |> ExportRequest.create_changeset(attrs) |> Repo.insert()

      assert {:error, changeset} =
               %ExportRequest{} |> ExportRequest.create_changeset(attrs) |> Repo.insert()

      assert errors_on(changeset).user_id != []
    end

    test "at most 2 requests per 7 days, cancelled ones included", %{user: user, secret: secret} do
      first = request!(user, secret)
      {:ok, _} = DataPortability.cancel_export(user.id, first.id)
      second = request!(user, secret)
      {:ok, _} = DataPortability.cancel_export(user.id, second.id)

      assert {:error, :weekly_limit_reached} =
               DataPortability.request_export(user, creds(secret), opts())
    end
  end

  describe "status transitions" do
    test "pending becomes ready after 24 h and notifies exactly once",
         %{user: user, secret: secret} do
      request = request!(user, secret)
      assert DataPortability.active_request(user.id).status == "pending"

      make_ready(request)
      assert DataPortability.active_request(user.id).status == "ready"
      DataPortability.sweep_transitions(:all)
      DataPortability.sweep_transitions(user.id)

      assert length(notices(user, "data_export_ready")) == 1
    end

    test "a request whose whole window passed unseen expires without a ready notice",
         %{user: user, secret: secret} do
      request = request!(user, secret)
      shift_back(request, 80 * 3600)

      DataPortability.sweep_transitions(:all)

      assert Repo.reload!(request).status == "expired"
      assert DataPortability.active_request(user.id) == nil
      assert notices(user, "data_export_ready") == []
    end
  end

  describe "authorize_download/4 and claim_download/2" do
    test "nothing is downloadable during the 24 h wait, and no attempt is used",
         %{user: user, secret: secret} do
      request = request!(user, secret)

      assert {:error, :not_found} =
               DataPortability.authorize_download(user, request.id, creds(secret), opts())

      assert {:error, :not_found} = DataPortability.claim_download(user.id, request.id)
      assert failed_attempts(user) == 0
    end

    test "a ready request needs step-up re-authentication to authorize",
         %{user: user, secret: secret} do
      request = user |> request!(secret) |> make_ready()

      assert {:error, :invalid_credentials} =
               DataPortability.authorize_download(
                 user,
                 request.id,
                 creds(secret, "wrong"),
                 opts()
               )

      assert {:ok, %ExportRequest{id: id}} =
               DataPortability.authorize_download(user, request.id, creds(secret), opts())

      assert id == request.id
      # Authorizing does not count as a download.
      assert Repo.reload!(request).download_count == 0
    end

    test "at most 3 downloads, then the request is completed", %{user: user, secret: secret} do
      request = user |> request!(secret) |> make_ready()

      assert {:ok, %{download_count: 1, status: "ready"}} =
               DataPortability.claim_download(user.id, request.id)

      assert {:ok, %{download_count: 2}} = DataPortability.claim_download(user.id, request.id)

      assert {:ok, %{download_count: 3, status: "completed"}} =
               DataPortability.claim_download(user.id, request.id)

      assert {:error, :not_found} = DataPortability.claim_download(user.id, request.id)
      assert length(notices(user, "data_export_downloaded")) == 3
    end

    test "concurrent claims never exceed the cap", %{user: user, secret: secret} do
      request = user |> request!(secret) |> make_ready()

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> DataPortability.claim_download(user.id, request.id) end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert Repo.reload!(request).download_count == 3
    end

    test "another user's request, or an expired one, answers :not_found",
         %{user: user, secret: secret} do
      request = user |> request!(secret) |> make_ready()
      {other, other_secret} = eligible_user()

      assert {:error, :not_found} = DataPortability.claim_download(other.id, request.id)

      assert {:error, :not_found} =
               DataPortability.authorize_download(
                 other,
                 request.id,
                 creds(other_secret),
                 opts()
               )

      shift_back(request, 49 * 3600)
      assert {:error, :not_found} = DataPortability.claim_download(user.id, request.id)
    end
  end

  describe "cancellation" do
    test "the owner can cancel; another user cannot", %{user: user, secret: secret} do
      request = request!(user, secret)
      {other, _} = eligible_user()

      assert {:error, :not_found} = DataPortability.cancel_export(other.id, request.id)

      assert {:ok, %{status: "cancelled", cancel_reason: "user"}} =
               DataPortability.cancel_export(user.id, request.id)

      assert [%{data: %{"reason" => "user"}}] = notices(user, "data_export_cancelled")
      assert {:error, :not_found} = DataPortability.cancel_export(user.id, request.id)
    end

    test "changing the password cancels the active request", %{user: user, secret: secret} do
      request = request!(user, secret)
      {:ok, token, _} = Auth.create_user_session(user.id)
      new = "N3w-Passw0rd!x"

      {:ok, _, _} =
        Auth.change_password(
          user,
          %{"password" => new, "password_confirmation" => new},
          Auth.session_id_by_token(token)
        )

      assert %{status: "cancelled", cancel_reason: "password_changed"} = Repo.reload!(request)
    end

    test "a recovery-code password reset cancels the active request",
         %{user: user, secret: secret} do
      request = request!(user, secret)
      [code | _] = Auth.generate_recovery_codes(user)
      new = "N3w-Passw0rd!x"

      {:ok, _} = Auth.reset_password_with_recovery_code(user.username, code, new, new)

      assert %{cancel_reason: "password_changed"} = Repo.reload!(request)
    end

    test "sign out everywhere cancels the active request", %{user: user, secret: secret} do
      request = request!(user, secret)
      {:ok, token, _} = Auth.create_user_session(user.id)

      {:ok, _} = Auth.sign_out_other_sessions(user, Auth.session_id_by_token(token))

      assert %{cancel_reason: "signed_out_everywhere"} = Repo.reload!(request)
    end

    test "disabling TOTP (also part of a TOTP reset) cancels the active request",
         %{user: user, secret: secret} do
      request = request!(user, secret)

      {:ok, _} = Auth.disable_totp(user)

      assert %{cancel_reason: "totp_changed"} = Repo.reload!(request)
    end

    test "a ban cancels the active request", %{user: user, secret: secret} do
      request = request!(user, secret)
      admin = create_user("admin")

      {:ok, _, _} = Auth.ban_user(user, admin.id, "spam")

      assert %{cancel_reason: "banned"} = Repo.reload!(request)
    end
  end

  describe "history" do
    test "is listed newest first and old finished requests are purged",
         %{user: user, secret: secret} do
      old = request!(user, secret)
      {:ok, _} = DataPortability.cancel_export(user.id, old.id)
      shift_back(old, 400 * 86_400)
      recent = request!(user, secret)

      assert [%{id: first}, %{id: second}] = DataPortability.list_export_history(user.id)
      assert {first, second} == {recent.id, old.id}

      assert DataPortability.purge_old_history() == 1
      assert [%{id: ^first}] = DataPortability.list_export_history(user.id)
    end

    test "active requests are never purged, however old", %{user: user, secret: secret} do
      request = request!(user, secret)
      # Only the requested_at moves; the request is still pending.
      Repo.update_all(from(r in ExportRequest, where: r.id == ^request.id),
        set: [requested_at: ~U[2020-01-01 00:00:00Z]]
      )

      assert DataPortability.purge_old_history() == 0
    end
  end

  describe "UserAgent.family/1" do
    test "reduces a user agent to browser and OS families only" do
      assert UserAgent.family(@firefox) == "Firefox on Linux"

      assert UserAgent.family(
               "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36 Edg/128.0"
             ) == "Edge on Windows"

      assert UserAgent.family(
               "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
             ) == "Safari on iOS"

      assert UserAgent.family("curl/8.0") == nil
      assert UserAgent.family(nil) == nil
    end
  end
end
