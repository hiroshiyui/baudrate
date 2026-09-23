defmodule Baudrate.Auth.UserDomainMute do
  @moduledoc """
  A member hiding one remote server's content from their own views
  (ADR 0073).

  Like a user mute it is local and silent: nothing is sent, and nobody else
  sees any change. Unlike an instance domain block
  (`Baudrate.Federation.DomainBlock`) it is one member's choice, and it
  **never refuses an interaction** — the block checks read blocks only.

  The domain is normalized the way a domain block's is, so a pasted URL or
  `@user@host` handle works, and this instance's own domain is refused.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Federation.DomainBlock

  @hostname ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  schema "user_domain_mutes" do
    belongs_to :user, Baudrate.Setup.User
    field :domain, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Casts and validates a domain mute; the domain is normalized first."
  def changeset(mute, attrs) do
    mute
    |> cast(attrs, [:user_id, :domain])
    |> update_change(:domain, &DomainBlock.normalize_domain/1)
    |> validate_required([:user_id, :domain])
    |> validate_format(:domain, @hostname,
      message: "must be a domain name such as example.social"
    )
    |> validate_length(:domain, max: 253)
    |> validate_change(:domain, fn :domain, domain ->
      if domain == local_domain(), do: [domain: "is this site's own domain"], else: []
    end)
    |> unique_constraint([:user_id, :domain], message: "is already muted")
  end

  defp local_domain do
    BaudrateWeb.Endpoint.url()
    |> URI.parse()
    |> Map.get(:host)
    |> to_string()
    |> String.downcase()
  end
end
