defmodule Baudrate.Auth.RecoveryChallenge do
  @moduledoc """
  The exact text a member is asked to sign before an admin acts on their
  recovery anchor ([ADR 0067](../../../doc/adr/0067-the-instance-issues-the-challenge-the-admin-still-verifies-it.md),
  refining [ADR 0058](../../../doc/adr/0058-account-recovery-is-anchored-outside-the-instance.md)).

  The instance issues it; **the admin still verifies the signature in their own
  client**, because nothing here parses OpenPGP. What the row adds is
  freshness: a signature over a message the member composed cannot be told
  from one they signed last year, and a replayed request is the cheapest
  attack on this whole path.

  The phrase is **ASCII, one line, and never translated**. It is copied out,
  signed byte for byte and compared by eye, so a locale that reached it would
  mean two admins comparing different strings, and a line break would mean
  comparing whatever the member's mail client did to it.

  It says what it authorizes, and does not read as a random token: somebody
  who is asked out of the blue to "sign this string" may do it, and the same
  person asked to sign *"account recovery for @alice"* has been told what they
  are agreeing to.
  """

  use Ecto.Schema

  alias Baudrate.Setup.User

  # Long enough for a locked-out member to read mail, short enough that a
  # phrase found later is not still live. Expiry is read from the clock
  # (ADR 0029): nothing sweeps this table.
  @ttl_hours 72

  # 16 bytes. This is the whole of the freshness, so it comes from
  # `:crypto.strong_rand_bytes/1` and never `:rand`.
  @nonce_bytes 16

  @type t :: %__MODULE__{}

  schema "recovery_challenges" do
    field :phrase, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :user, User
    belongs_to :recovery_contact, Baudrate.Auth.RecoveryContact
    belongs_to :issued_by, User
    belongs_to :consumed_by, User

    timestamps(type: :utc_datetime)
  end

  @doc "How long an unanswered challenge stays live."
  def ttl_hours, do: @ttl_hours

  @doc """
  Builds an unsaved challenge for `contact`, issued by `admin`.

  There is no `changeset/2`: nothing here is ever cast from parameters. Every
  field is either generated or the caller's own identity, and a challenge an
  admin could word themselves would be a challenge an attacker could ask them
  to word.
  """
  @spec build(Baudrate.Auth.RecoveryContact.t(), User.t(), User.t(), String.t() | nil) :: t()
  def build(contact, %User{} = owner, %User{} = admin, site_name \\ nil) do
    now = DateTime.utc_now(:second)

    %__MODULE__{
      user_id: owner.id,
      recovery_contact_id: contact.id,
      phrase: phrase(owner, site_name, now),
      expires_at: DateTime.add(now, @ttl_hours * 3600, :second),
      issued_by_id: admin.id
    }
  end

  @doc """
  The sentence the member signs: who it is for, when it was asked, and the
  nonce that makes it answerable once.
  """
  @spec phrase(User.t(), String.t() | nil, DateTime.t()) :: String.t()
  def phrase(%User{} = owner, site_name, %DateTime{} = now) do
    [
      site(site_name),
      "account recovery for @#{owner.username}",
      Date.to_iso8601(DateTime.to_date(now)),
      nonce()
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" - ")
  end

  @doc "True while the challenge is unconsumed and unexpired, by the clock."
  @spec live?(t(), DateTime.t()) :: boolean()
  def live?(%__MODULE__{consumed_at: nil, expires_at: expires}, now),
    do: DateTime.compare(expires, now) == :gt

  def live?(%__MODULE__{}, _now), do: false

  defp nonce, do: @nonce_bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # An instance name is a member's own words and may be in any script; the
  # phrase is ASCII because it is compared by eye across two machines, so
  # anything else is dropped rather than transliterated.
  defp site(name) when is_binary(name) do
    ascii = String.replace(name, ~r/[^\x20-\x7e]/, "") |> String.trim()

    if ascii == "", do: "", else: String.slice(ascii, 0, 40)
  end

  defp site(_), do: ""
end
