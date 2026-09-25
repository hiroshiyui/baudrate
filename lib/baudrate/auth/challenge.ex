defmodule Baudrate.Auth.Challenge do
  @moduledoc """
  The proof-of-work challenge a visitor solves before registering (P5-D1).

  The server issues a random nonce and a difficulty in bits; the browser finds
  a `solution` such that `SHA-256(nonce <> solution)` begins with that many
  zero bits, and the server checks the one hash that proves it. Finding the
  solution takes about 2^bits hashes; checking it takes one.

  ## What it is for, and what it is not

  It does not stop a determined attacker. Native code computes SHA-256 far
  faster than a browser — OpenSSL on one desktop core, about 9 million
  hashes a second against the browser's one — so a spammer running their own
  client pays some 30 ms per account at 18 bits where a person's phone pays a
  second or two, and a graphics card pays nothing worth counting. What it does
  is **put a price on every registration attempt**, and **make the attacker
  run the protocol** — hold a LiveView socket open, receive the nonce, solve
  it, answer — rather than replay a form post. Together with the per-address
  rate limit, the IP bans and the approval queue, that is enough to turn an
  automated wave from free into merely cheap, which is the difference between
  a flood and a trickle a moderator can keep up with.

  It is self-hosted because the alternative is a third-party CAPTCHA, which is
  a subresource from a host we do not control on the one page every new member
  must load — exactly what ADR 0006 refuses — and which hands that host every
  registrant's address and browser.

  ## One solve buys one attempt

  The challenge lives in the registering LiveView's socket assigns and is
  **re-issued after every attempt**, whether it succeeded or not. Nothing is
  stored, so there is no table, no cleanup, and nothing about a visitor kept.
  A solution that worked once proves nothing about the next submit, which is
  what stops one solve being spent on a hundred invite-code guesses.

  ## Bounds, and why they are these numbers

  The difficulty is the `registration_challenge_bits` setting, and each bit
  doubles the work. On one desktop, `challenge_solver.js` manages about 1.3
  million hashes a second in V8 (Chrome, Edge) and 0.9 million in Firefox; a
  phone is taken to be several times slower. So, expected:

  | bits | desktop | a phone ~8× slower |
  |------|---------|--------------------|
  | 16 | 0.05 s | 0.4 s |
  | **18** (default) | 0.2 s | 1.7 s |
  | 20 | 0.8 s | 7 s |
  | 22 (cap) | 3.4 s | 27 s |

  Those are *expected* times: the work is geometric, so some visitors take
  three or four times as long. 18 is the default because it is the highest
  value at which an unlucky phone still finishes before the person does;
  the plan's first figure of 20 sat at seven seconds, which is long enough
  to look broken. The cap is 22 because 24 costs a phone nearly two minutes
  and would make registration impossible in practice — raising the setting
  during a spam wave is its purpose, and a slip of the keyboard must not be
  able to close the door. 0 turns the challenge off.

  Observed on production at 20 bits (2026-09-22): headless Firefox on a
  desktop took a median 2.5 s from page load to answer over eight loads,
  worst 3.2 s, connection and worker start-up included; and a Pixel 8a
  answered before its owner had finished the form, so the "checking this
  browser" line never appeared. The phone column is still an estimate, but
  a current mid-range phone does not contradict it.

  A solution longer than 32 bytes is refused unhashed, so verifying one is
  constant work and cannot itself be used to make the server hash large
  inputs.
  """

  alias Baudrate.Setup

  @default_bits 18
  @max_bits 22
  @max_solution_bytes 32

  @typedoc "An issued challenge, or `nil` when the challenge is switched off."
  @type t :: %{nonce: String.t(), bits: pos_integer()} | nil

  @doc "The highest difficulty the setting accepts."
  def max_bits, do: @max_bits

  @doc """
  The configured difficulty in bits (0–#{@max_bits}).

  The setting wins; with no setting, the application default applies
  (#{@default_bits} in production, and 0 in the test suite so that tests which
  are not about the challenge are not made to solve one).
  """
  @spec bits() :: non_neg_integer()
  def bits do
    case Setup.get_setting("registration_challenge_bits") do
      nil -> Application.get_env(:baudrate, :registration_challenge_bits, @default_bits)
      value -> parse_bits(value)
    end
    |> clamp()
  end

  @doc "Issues a fresh challenge at the configured difficulty, or `nil` when it is off."
  @spec issue() :: t()
  def issue, do: issue(bits())

  @doc "Issues a fresh challenge at `bits`, or `nil` for 0."
  @spec issue(non_neg_integer()) :: t()
  def issue(0), do: nil

  def issue(bits) when is_integer(bits) and bits > 0 do
    %{nonce: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower), bits: clamp(bits)}
  end

  @doc """
  Whether `solution` solves `challenge`.

  A `nil` challenge — the feature switched off — is always satisfied. Anything
  that is not a non-empty binary of at most #{@max_solution_bytes} bytes is
  refused without being hashed.
  """
  @spec solved?(t(), term()) :: boolean()
  def solved?(nil, _solution), do: true

  def solved?(%{nonce: nonce, bits: bits}, solution)
      when is_binary(solution) and byte_size(solution) in 1..@max_solution_bytes do
    hash = :crypto.hash(:sha256, nonce <> solution)
    match?(<<0::size(^bits), _::bitstring>>, hash)
  end

  def solved?(_challenge, _solution), do: false

  defp parse_bits(value) when is_integer(value), do: value

  defp parse_bits(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> @default_bits
    end
  end

  defp parse_bits(_), do: @default_bits

  defp clamp(n) when n < 0, do: 0
  defp clamp(n) when n > @max_bits, do: @max_bits
  defp clamp(n), do: n
end
