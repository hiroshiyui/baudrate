defmodule Baudrate.Federation.DomainBlock do
  @moduledoc """
  Schema for an instance-level domain block (ADR 0030).

  One row per blocked domain, carrying who blocked it, when, and why. This
  replaced the comma-separated `ap_domain_blocklist` setting, which recorded
  the domain and nothing else.

  `reason` is for staff and is never rendered outside the admin surfaces.
  `public_comment` is the part we are willing to say publicly, and is what a
  future "blocked instances" page would show.

  Domains are stored downcased and bare — no scheme, no port, no `@` — because
  the hiding filter compares them to `remote_actors.domain` with SQL equality.
  `normalize_domain/1` is what puts a pasted value into that shape.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  @type t :: %__MODULE__{}

  schema "domain_blocks" do
    field :domain, :string
    field :reason, :string
    field :public_comment, :string

    belongs_to :blocked_by, User

    timestamps(type: :utc_datetime)
  end

  # A hostname with at least one dot: labels of alphanumerics and hyphens, no
  # leading or trailing hyphen. Deliberately ASCII — an internationalized
  # domain reaches us punycoded, because a URI host is ASCII.
  @hostname ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  @doc """
  Casts and validates a domain block.

  The domain is normalized before validation, so an admin may paste
  `https://Spam.Example/@someone` and get `spam.example`.
  """
  def changeset(domain_block, attrs) do
    domain_block
    |> cast(attrs, [:domain, :reason, :public_comment, :blocked_by_id])
    |> update_change(:domain, &normalize_domain/1)
    |> validate_required([:domain])
    |> validate_format(:domain, @hostname, message: "must be a domain name such as spam.example")
    |> validate_length(:domain, max: 253)
    |> validate_length(:reason, max: 1000)
    |> validate_length(:public_comment, max: 1000)
    |> validate_not_local()
    |> unique_constraint(:domain, message: "is already blocked")
  end

  @doc """
  Reduces a pasted value to a bare, downcased hostname.

  Accepts a URL, an `@user@host` handle, a host with a port, or a plain
  domain. Returns the input trimmed and downcased when it recognizes none of
  those shapes, leaving the format validation to reject it.
  """
  def normalize_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> strip_scheme()
    # The path goes first: in `https://spam.example/@bob` the last `@` belongs
    # to the path, not to a handle.
    |> strip_path()
    |> strip_userinfo()
    |> strip_port()
    |> String.trim_trailing(".")
  end

  def normalize_domain(value), do: value

  defp strip_scheme(value) do
    case String.split(value, "://", parts: 2) do
      [_scheme, rest] -> rest
      [value] -> value
    end
  end

  # `@user@host` and `user@host` both name the host after the last `@`.
  defp strip_userinfo(value) do
    value |> String.split("@") |> List.last()
  end

  defp strip_path(value) do
    value |> String.split(~r{[/?#]}, parts: 2) |> List.first()
  end

  # IPv6 literals are not a thing we federate with, so a colon is a port.
  defp strip_port(value) do
    value |> String.split(":", parts: 2) |> List.first()
  end

  # Blocking our own domain would refuse our own activities at the inbox and
  # stop delivery to ourselves, with no obvious way back through the UI.
  defp validate_not_local(changeset) do
    validate_change(changeset, :domain, fn :domain, domain ->
      if domain == local_domain() do
        [domain: "is this instance's own domain"]
      else
        []
      end
    end)
  end

  defp local_domain do
    BaudrateWeb.Endpoint.url()
    |> URI.parse()
    |> Map.get(:host)
    |> to_string()
    |> String.downcase()
  end
end
