defmodule Baudrate.Auth.RegistrationChallengeTest do
  @moduledoc """
  The acceptance gate for the registration proof-of-work challenge (P5-D1).

  Two halves. The arithmetic: a solution solves exactly its own challenge,
  verification is bounded, and the setting cannot push the difficulty past the
  point where a phone gives up. And the page: a submit that arrives first is
  held and then completed, not refused; and **one solve buys one attempt** —
  after any attempt, success included, the old answer proves nothing.

  The JavaScript solver is checked against Erlang's `:crypto` in the browser
  test `features/registration_challenge_test.exs`, which registers end to end.
  """
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Auth.Challenge
  alias Baudrate.Repo
  alias Baudrate.Setup.{Setting, User}

  # Low enough to brute-force in a test (about 256 attempts), high enough that
  # a wrong answer is almost certainly wrong.
  @bits 8

  defp solve(%{nonce: nonce, bits: bits} = challenge) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&Integer.to_string/1)
    |> Enum.find(&Challenge.solved?(challenge, &1))
    |> tap(fn s -> assert s, "no solution found for #{nonce}/#{bits}" end)
  end

  defp nonce_from(html) do
    [_, nonce] = Regex.run(~r/data-nonce="([0-9a-f]{32})"/, html)
    nonce
  end

  defp registration(username) do
    %{
      username: username,
      password: "SecurePass1!!",
      password_confirmation: "SecurePass1!!",
      terms_accepted: "true"
    }
  end

  defp registered?(username), do: Repo.exists?(from(u in User, where: u.username == ^username))

  describe "the arithmetic" do
    test "0 switches it off, and an off challenge is always satisfied" do
      assert Challenge.issue(0) == nil
      assert Challenge.solved?(nil, nil)
      assert Challenge.solved?(nil, "anything")
    end

    test "an issued challenge carries a fresh 128-bit nonce" do
      a = Challenge.issue(@bits)
      b = Challenge.issue(@bits)

      assert a.nonce =~ ~r/\A[0-9a-f]{32}\z/
      assert a.bits == @bits
      refute a.nonce == b.nonce
    end

    test "a solution solves its own challenge and no other" do
      challenge = Challenge.issue(@bits)
      solution = solve(challenge)

      assert Challenge.solved?(challenge, solution)
      # The same answer to a different nonce is, almost always, not an answer.
      refute Enum.all?(1..20, fn _ -> Challenge.solved?(Challenge.issue(@bits), solution) end)
    end

    test "anything that is not a short string is refused without hashing" do
      challenge = Challenge.issue(@bits)

      refute Challenge.solved?(challenge, nil)
      refute Challenge.solved?(challenge, 42)
      refute Challenge.solved?(challenge, "")
      # Verification must be constant work, so an attacker cannot make the
      # server hash an input of their choosing.
      refute Challenge.solved?(challenge, String.duplicate("0", 33))
    end

    test "the setting is read, clamped at the cap, and a nonsense value falls back" do
      Repo.insert!(%Setting{key: "registration_challenge_bits", value: "12"})
      assert Challenge.bits() == 12

      Repo.update_all(Setting, set: [value: "99"])
      assert Challenge.bits() == Challenge.max_bits()

      Repo.update_all(Setting, set: [value: "-3"])
      assert Challenge.bits() == 0
    end

    test "the cap is where a phone still finishes, not where it gives up" do
      # 24 bits is nearly two minutes on a phone several times slower than a
      # desktop; the cap exists so a slip cannot close the door.
      assert Challenge.max_bits() <= 22
    end
  end

  describe "the registration page" do
    setup do
      Baudrate.Setup.seed_roles_and_permissions()
      Repo.insert!(%Setting{key: "setup_completed", value: "true"})
      Repo.insert!(%Setting{key: "registration_mode", value: "open"})
      Repo.insert!(%Setting{key: "registration_challenge_bits", value: Integer.to_string(@bits)})
      BaudrateWeb.RateLimiter.Sandbox.set_global_response({:allow, 1})
      :ok
    end

    test "renders the challenge for the browser to solve", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/register")

      assert html =~ ~s(id="register-challenge")
      assert html =~ ~s(phx-hook="ChallengeHook")
      assert html =~ ~s(data-bits="#{@bits}")
    end

    test "a submit before the answer is held, not refused, and completed when it lands",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, "/register")
      nonce = nonce_from(html)

      html = lv |> form("#register-form", user: registration("early")) |> render_submit()

      refute registered?("early")
      assert html =~ "Checking this browser"

      html =
        render_hook(lv, "challenge_solved", %{
          "nonce" => nonce,
          "solution" => solve(%{nonce: nonce, bits: @bits})
        })

      assert registered?("early")
      assert html =~ "Recovery Codes"
    end

    test "an answer that arrives first lets the submit go straight through", %{conn: conn} do
      {:ok, lv, html} = live(conn, "/register")
      nonce = nonce_from(html)

      render_hook(lv, "challenge_solved", %{
        "nonce" => nonce,
        "solution" => solve(%{nonce: nonce, bits: @bits})
      })

      lv |> form("#register-form", user: registration("prompt")) |> render_submit()
      assert registered?("prompt")
    end

    test "a wrong answer, or an answer to another nonce, does nothing", %{conn: conn} do
      {:ok, lv, html} = live(conn, "/register")
      nonce = nonce_from(html)

      lv |> form("#register-form", user: registration("forged")) |> render_submit()

      render_hook(lv, "challenge_solved", %{"nonce" => nonce, "solution" => "not-it"})
      other = Challenge.issue(@bits)
      render_hook(lv, "challenge_solved", %{"nonce" => other.nonce, "solution" => solve(other)})

      refute registered?("forged")
    end

    test "one solve buys one attempt: the challenge is re-issued afterwards", %{conn: conn} do
      {:ok, lv, html} = live(conn, "/register")
      nonce = nonce_from(html)
      solution = solve(%{nonce: nonce, bits: @bits})
      render_hook(lv, "challenge_solved", %{"nonce" => nonce, "solution" => solution})

      # An attempt that fails validation still spends the answer.
      lv
      |> form("#register-form", user: %{registration("x") | password_confirmation: "mismatch"})
      |> render_submit()

      assert_push_event(lv, "challenge", %{nonce: fresh_nonce, bits: @bits})
      refute fresh_nonce == nonce

      # Replaying the spent answer does not satisfy the new challenge.
      render_hook(lv, "challenge_solved", %{"nonce" => nonce, "solution" => solution})
      lv |> form("#register-form", user: registration("replayed")) |> render_submit()
      refute registered?("replayed")
    end

    test "a successful registration spends the answer too", %{conn: conn} do
      # The bypass this closes: a consumed challenge left as `nil` would read
      # as "switched off", and a crafted socket could keep submitting on one
      # solve. After success the page shows recovery codes, but the socket
      # still answers events.
      {:ok, lv, html} = live(conn, "/register")
      nonce = nonce_from(html)

      render_hook(lv, "challenge_solved", %{
        "nonce" => nonce,
        "solution" => solve(%{nonce: nonce, bits: @bits})
      })

      lv |> form("#register-form", user: registration("first")) |> render_submit()
      assert registered?("first")

      render_submit(lv, "submit", %{"user" => registration("second")})
      refute registered?("second")
    end
  end

  describe "with the challenge switched off" do
    test "registration works exactly as before", %{conn: conn} do
      Baudrate.Setup.seed_roles_and_permissions()
      Repo.insert!(%Setting{key: "setup_completed", value: "true"})
      Repo.insert!(%Setting{key: "registration_mode", value: "open"})
      Repo.insert!(%Setting{key: "registration_challenge_bits", value: "0"})

      {:ok, lv, html} = live(conn, "/register")
      refute html =~ ~s(id="register-challenge")

      lv |> form("#register-form", user: registration("plain")) |> render_submit()
      assert registered?("plain")
    end
  end
end
