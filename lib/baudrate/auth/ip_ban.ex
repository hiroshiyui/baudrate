defmodule Baudrate.Auth.IpBan do
  @moduledoc """
  An address or address range refused at registration and sign-in.

  A ban names a **network**: an address plus a prefix length, with the host
  bits cleared, so `203.0.113.7/24` and `203.0.113.200/24` are the same row.
  A bare address is a `/32` (IPv4) or a `/128` (IPv6).

  ## Normalisation

  `parse/1` is the only way an address reaches this schema, and it does three
  things a hand-typed value needs:

    * trims it and parses it with `:inet.parse_address/1`, so anything that is
      not an address is refused rather than stored as a string nobody matches;
    * **unmaps an IPv4-mapped IPv6 address** (`::ffff:203.0.113.7`) to its IPv4
      form, through `BaudrateWeb.Plugs.RealIp.unmap_ipv4/1` — the same one
      definition the client IP goes through before it is compared, so a ban
      typed either way matches a visitor arriving either way. Only
      `::ffff:0:0/96` is unmapped: NAT64 and 6to4 prefixes name *different*
      hosts, and decoding them would widen what a ban reaches;
    * clears the host bits, so the stored row is the network and the unique
      index can refuse the same range entered twice under different spellings.

  ## What is not castable

  `address`, `prefix_length` and `family` come from `parse/1` and are put on
  the changeset by `Baudrate.Auth.IpBans`, never cast from a form. `created_by_id`
  is the acting admin. Only `reason` and `expires_at` are the admin's to type.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  @max_reason_length 500

  schema "ip_bans" do
    field :address, :string
    field :prefix_length, :integer
    field :family, :string
    field :reason, :string
    field :expires_at, :utc_datetime

    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end

  @type parsed :: %{
          family: :inet | :inet6,
          tuple: :inet.ip_address(),
          prefix_length: non_neg_integer(),
          address: String.t()
        }

  @doc "Changeset for the fields an admin types: the reason and the expiry."
  def changeset(ban, attrs) do
    ban
    |> cast(attrs, [:reason, :expires_at])
    |> validate_length(:reason, max: @max_reason_length)
    |> validate_required([:address, :prefix_length, :family])
    |> validate_inclusion(:family, ~w(inet inet6))
    |> unique_constraint([:address, :prefix_length],
      message: "is already banned"
    )
    |> foreign_key_constraint(:created_by_id)
  end

  @doc """
  Parses a typed address or CIDR range into its network form.

      iex> Baudrate.Auth.IpBan.parse("203.0.113.7/24")
      {:ok, %{family: :inet, tuple: {203, 0, 113, 0}, prefix_length: 24, address: "203.0.113.0"}}

      iex> Baudrate.Auth.IpBan.parse("not an address")
      :error
  """
  @spec parse(String.t() | nil) :: {:ok, parsed()} | :error
  def parse(input) when is_binary(input) do
    with [addr | rest] <- String.split(String.trim(input), "/", parts: 2),
         {:ok, tuple} <- :inet.parse_address(String.to_charlist(addr)),
         tuple = BaudrateWeb.Plugs.RealIp.unmap_ipv4(tuple),
         family = family(tuple),
         {:ok, prefix} <- prefix(rest, family) do
      network = network(tuple, prefix)

      {:ok,
       %{
         family: family,
         tuple: network,
         prefix_length: prefix,
         address: network |> :inet.ntoa() |> to_string()
       }}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "The number of bits in an address of this family."
  @spec width(:inet | :inet6) :: 32 | 128
  def width(:inet), do: 32
  def width(:inet6), do: 128

  @doc """
  Whether `ip` (an address tuple) falls inside the range `family`/`tuple`/`prefix`.

  An address of the other family is never inside, whatever the bits say.
  """
  @spec contains?(parsed() | map(), :inet.ip_address()) :: boolean()
  def contains?(%{family: family, tuple: network, prefix_length: prefix}, ip) when is_tuple(ip) do
    ip = BaudrateWeb.Plugs.RealIp.unmap_ipv4(ip)

    family(ip) == family and
      mask(to_integer(ip), prefix, width(family)) == to_integer(network)
  end

  def contains?(_, _), do: false

  @doc "The last address in a range, for the private-range and own-address checks."
  @spec last_address(parsed()) :: :inet.ip_address()
  def last_address(%{family: family, tuple: network, prefix_length: prefix}) do
    bits = width(family)
    host_bits = bits - prefix
    last = to_integer(network) + (Bitwise.bsl(1, host_bits) - 1)
    from_integer(last, family)
  end

  @doc "How many addresses a range covers, shown in the form before an admin commits."
  @spec size(parsed()) :: pos_integer()
  def size(%{family: family, prefix_length: prefix}), do: Bitwise.bsl(1, width(family) - prefix)

  @doc "The range as it is written: `203.0.113.0/24`, or a bare address for a host."
  @spec to_cidr(map()) :: String.t()
  def to_cidr(%{family: family, address: address, prefix_length: prefix}) do
    if prefix == width(family_atom(family)), do: address, else: "#{address}/#{prefix}"
  end

  @doc """
  The family as an atom, from either the stored string or a parsed atom.

  Explicit clauses rather than `String.to_existing_atom/1`: the column is
  validated to these two values, but the rule in this codebase is that a string
  from storage never becomes an atom by conversion.
  """
  @spec family_atom(String.t() | atom()) :: :inet | :inet6
  def family_atom("inet"), do: :inet
  def family_atom("inet6"), do: :inet6
  def family_atom(:inet), do: :inet
  def family_atom(:inet6), do: :inet6

  # --- internals ---

  defp family(tuple) when tuple_size(tuple) == 4, do: :inet
  defp family(tuple) when tuple_size(tuple) == 8, do: :inet6

  defp prefix([], family), do: {:ok, width(family)}

  defp prefix([text], family) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n >= 0 -> if n <= width(family), do: {:ok, n}, else: :error
      _ -> :error
    end
  end

  defp network(tuple, prefix) do
    family = family(tuple)
    tuple |> to_integer() |> mask(prefix, width(family)) |> from_integer(family)
  end

  defp mask(int, prefix, bits) do
    host_bits = bits - prefix
    int |> Bitwise.bsr(host_bits) |> Bitwise.bsl(host_bits)
  end

  defp to_integer({a, b, c, d}),
    do: Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d

  defp to_integer({_, _, _, _, _, _, _, _} = t) do
    t |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> Bitwise.bsl(acc, 16) + part end)
  end

  defp from_integer(int, :inet) do
    {Bitwise.band(Bitwise.bsr(int, 24), 0xFF), Bitwise.band(Bitwise.bsr(int, 16), 0xFF),
     Bitwise.band(Bitwise.bsr(int, 8), 0xFF), Bitwise.band(int, 0xFF)}
  end

  defp from_integer(int, :inet6) do
    for shift <- [112, 96, 80, 64, 48, 32, 16, 0] do
      Bitwise.band(Bitwise.bsr(int, shift), 0xFFFF)
    end
    |> List.to_tuple()
  end
end
