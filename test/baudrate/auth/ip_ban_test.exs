defmodule Baudrate.Auth.IpBanTest do
  @moduledoc """
  The acceptance gate for IP and CIDR bans (Phase 5E).

  Three things are gated here: what a ban *matches* (the parsing and the
  arithmetic, where a wrong mask silently bans the wrong people), what an admin
  is *refused* (each refusal stops a ban doing something other than what was
  meant), and where it is *enforced* — including `SessionController`'s
  `establish_session/3`, the one function every sign-in path passes through.
  """
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Auth.{IpBan, IpBans}
  alias Baudrate.Moderation.Log
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  doctest Baudrate.Auth.IpBan

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    BaudrateWeb.RateLimit.reset_all()
    :ok
  end

  # Enforcement tests put a row in directly: the LiveView test peer is
  # 127.0.0.1, which `create/4` rightly refuses to ban, and what is under test
  # there is whether a ban is honoured, not how one is made.
  defp insert_ban!(cidr, expires_at \\ nil) do
    {:ok, parsed} = IpBan.parse(cidr)

    Repo.insert!(%IpBan{
      address: parsed.address,
      prefix_length: parsed.prefix_length,
      family: Atom.to_string(parsed.family),
      expires_at: expires_at
    })
  end

  describe "parse/1" do
    test "a bare address is a host route" do
      assert {:ok, %{family: :inet, prefix_length: 32, address: "8.8.8.8"}} =
               IpBan.parse("8.8.8.8")

      assert {:ok, %{family: :inet6, prefix_length: 128}} = IpBan.parse("2606:4700::1111")
    end

    test "host bits are cleared, so two spellings of one range are one row" do
      assert {:ok, %{address: "8.8.8.0", prefix_length: 24}} = IpBan.parse("8.8.8.200/24")
      assert {:ok, %{address: "8.8.8.0", prefix_length: 24}} = IpBan.parse(" 8.8.8.7/24 ")
    end

    test "an IPv4-mapped IPv6 address becomes its IPv4 form" do
      # The client address is unmapped the same way before it is compared, so
      # a ban typed either way matches a visitor arriving either way.
      assert {:ok, %{family: :inet, address: "8.8.8.8", prefix_length: 32}} =
               IpBan.parse("::ffff:8.8.8.8")
    end

    test "anything that is not an address is refused, not stored" do
      for bad <- ["", "not-an-ip", "8.8.8.8/33", "8.8.8.8/-1", "8.8.8.8/x", "999.1.1.1", nil] do
        assert IpBan.parse(bad) == :error, "accepted #{inspect(bad)}"
      end
    end
  end

  describe "contains?/2" do
    test "matches inside the range and nowhere else" do
      {:ok, range} = IpBan.parse("8.8.8.0/24")

      assert IpBan.contains?(range, {8, 8, 8, 1})
      assert IpBan.contains?(range, {8, 8, 8, 255})
      refute IpBan.contains?(range, {8, 8, 9, 0})
      refute IpBan.contains?(range, {8, 8, 7, 255})
    end

    test "never matches an address of the other family" do
      {:ok, range} = IpBan.parse("0.0.0.0/8")
      refute IpBan.contains?(range, {0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "an IPv4-mapped visitor matches an IPv4 ban" do
      # The production endpoint binds the IPv6 any-address, so an IPv4 peer
      # arrives as ::ffff:a.b.c.d (the pre-v1.15.0 RealIp bug). A ban that did
      # not unmap would never match anyone.
      {:ok, range} = IpBan.parse("8.8.8.0/24")
      assert IpBan.contains?(range, {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0801})
    end

    test "IPv6 ranges match across the full width" do
      {:ok, range} = IpBan.parse("2606:4700::/32")
      assert IpBan.contains?(range, {0x2606, 0x4700, 0xFFFF, 0, 0, 0, 0, 1})
      refute IpBan.contains?(range, {0x2606, 0x4701, 0, 0, 0, 0, 0, 1})
    end
  end

  describe "create/4 refuses" do
    setup do
      {:ok, admin: setup_user("admin")}
    end

    test "a private or loopback range, which is what everyone looks like behind a bad proxy",
         %{admin: admin} do
      for range <- ["127.0.0.1", "10.0.0.5", "192.168.1.0/24", "::1", "fd00::/8"] do
        assert {:error, :private_range} =
                 IpBans.create(range, %{}, admin, actor_ip: "1.1.1.1", confirm_broad: true),
               "banned #{range}"
      end
    end

    test "a range broader than the minimum, even confirmed", %{admin: admin} do
      assert {:error, :too_broad} =
               IpBans.create("8.0.0.0/7", %{}, admin, actor_ip: "1.1.1.1", confirm_broad: true)

      assert {:error, :too_broad} =
               IpBans.create("2606::/15", %{}, admin, actor_ip: "1.1.1.1", confirm_broad: true)
    end

    test "a broad range without the second tick", %{admin: admin} do
      assert {:error, :needs_confirmation} =
               IpBans.create("8.8.0.0/15", %{}, admin, actor_ip: "1.1.1.1")

      assert {:ok, _} =
               IpBans.create("8.8.0.0/15", %{}, admin, actor_ip: "1.1.1.1", confirm_broad: true)
    end

    test "a range containing the acting admin's own address", %{admin: admin} do
      assert {:error, :own_address} =
               IpBans.create("8.8.8.0/24", %{}, admin, actor_ip: "8.8.8.8")
    end

    test "any range when the admin's own address is unknown", %{admin: admin} do
      # Refused rather than made blind: without the address, the mistake that
      # locks the admin out of this page is unguarded.
      assert {:error, :own_address} = IpBans.create("8.8.8.0/24", %{}, admin, actor_ip: nil)
    end

    test "anyone without admin.manage_users" do
      moderator = setup_user("moderator")

      assert {:error, :unauthorized} =
               IpBans.create("8.8.8.0/24", %{}, moderator, actor_ip: "1.1.1.1")
    end

    test "the same range twice, however it is spelled", %{admin: admin} do
      assert {:ok, _} = IpBans.create("8.8.8.7/24", %{}, admin, actor_ip: "1.1.1.1")

      assert {:error, %Ecto.Changeset{}} =
               IpBans.create("8.8.8.200/24", %{}, admin, actor_ip: "1.1.1.1")
    end
  end

  describe "create/4 and delete/2" do
    test "write the moderation log, so every ban has a named author" do
      admin = setup_user("admin")

      {:ok, ban} =
        IpBans.create("8.8.8.0/24", %{"reason" => "signup wave"}, admin, actor_ip: "1.1.1.1")

      assert Repo.get_by!(Log, action: "ban_ip", target_id: ban.id).actor_id == admin.id

      :ok = IpBans.delete(ban.id, admin)
      assert Repo.get_by!(Log, action: "unban_ip", target_id: ban.id)
    end
  end

  describe "banned?/1" do
    test "honours an active ban and ignores everything else" do
      insert_ban!("8.8.8.0/24")

      assert IpBans.banned?("8.8.8.8")
      assert IpBans.banned?({8, 8, 8, 8})
      refute IpBans.banned?("8.8.9.8")
      # The "unknown" a LiveView assigns before it connects is never banned.
      refute IpBans.banned?("unknown")
      refute IpBans.banned?(nil)
    end

    test "an expired ban stops applying by the clock, with no sweep" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      insert_ban!("8.8.8.0/24", past)
      insert_ban!("9.9.9.0/24", future)

      refute IpBans.banned?("8.8.8.8")
      assert IpBans.banned?("9.9.9.9")
    end
  end

  describe "enforcement" do
    test "sign-in is refused before the password is tested", %{conn: conn} do
      insert_ban!("127.0.0.1")
      user = setup_user("user")

      {:ok, lv, _html} = live(conn, "/login")

      html =
        lv
        |> form("#login-form", login: %{username: user.username, password: "Password123!x"})
        |> render_submit()

      assert html =~ "not available from your network"
      # Nothing was recorded against the account, so a banned address learns
      # nothing about which usernames exist.
      refute Repo.exists?(
               from(a in Baudrate.Auth.LoginAttempt, where: a.username == ^user.username)
             )
    end

    test "registration is refused, and says so without a form to fill in", %{conn: conn} do
      insert_ban!("127.0.0.1")

      {:ok, _lv, html} = live(conn, "/register")

      assert html =~ "not available from your network"
      refute html =~ ~s(id="register-form")
    end

    test "the session is not minted even when the password step was passed", %{conn: conn} do
      # The backstop. A ban issued between the password step and the token
      # POST, or any sign-in path added later that skips LoginLive, still ends
      # at establish_session/3.
      user = setup_user("user")
      insert_ban!("8.8.8.0/24")

      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)

      conn =
        %{conn | remote_ip: {8, 8, 8, 8}}
        |> post("/auth/session", %{"token" => token})

      assert redirected_to(conn) == "/login"
      assert is_nil(get_session(conn, :session_token))
      assert is_nil(get_session(conn, :user_id))
    end

    test "an unbanned address signs in as before", %{conn: conn} do
      user = setup_user("user")
      insert_ban!("8.8.8.0/24")

      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", user.id)
      conn = %{conn | remote_ip: {9, 9, 9, 9}} |> post("/auth/session", %{"token" => token})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :session_token)
    end
  end

  test "the Auth facade answers the same question" do
    insert_ban!("8.8.8.0/24")
    assert Auth.ip_banned?("8.8.8.8")
  end
end
