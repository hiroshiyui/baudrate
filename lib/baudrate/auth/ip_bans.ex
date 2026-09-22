defmodule Baudrate.Auth.IpBans do
  @moduledoc """
  IP and CIDR bans for registration and sign-in (Phase 5E).

  The one write path for `ip_bans`, and it refreshes `Baudrate.Auth.IpBanCache`
  itself, so a ban takes effect on the next request rather than at the next
  restart — the failure `DomainBlockCache` once had (a block from the
  Federation dashboard ignored until the next settings save).

  ## What a ban refuses, and what it does not

  A ban refuses **registration and sign-in** from an address. It does not stop
  anyone reading: public content stays public (the premise of the whole site),
  and a ban that blanked pages would be a wall that only the innocent people
  sharing the address ever notice. It is checked where an account is created
  and at `SessionController`'s `establish_session/3`, the one function every
  sign-in path goes through to mint a session.

  ## Four refusals

  Each of these looks like a restriction an admin could reasonably want lifted,
  and each is here because the ban would do something other than what was
  meant:

    * **a loopback or private range** — the address every visitor appears as
      when `RealIp` is misconfigured and the proxy's address is being read
      instead of the client's. Banning it bans the whole site. The check asks
      `Federation.HTTPClient.private_ip?/1`, the codebase's one deny-list,
      about both ends of the range;
    * **anything broader than a /8 (IPv4) or a /16 (IPv6)** — there is no
      spam wave that calls for it and no way to make it right;
    * **a range containing the acting admin's own address** — the one mistake
      that locks the person making it out of the page that would undo it, as
      `DomainBlocks` refuses this instance's own domain for the same reason;
    * **a broad range without confirmation** — a /8 to /15 (IPv4) or /16 to
      /31 (IPv6) is sometimes right during a wave from one provider and is
      never an accident worth making silently, so it needs `confirm_broad: true`.

  ## Expiry is read, never swept

  A ban is active while `expires_at` is `NULL` or in the future, decided when
  the cache is read. There is no job that lifts a ban: ADR 0029 refuses one for
  sanctions because a missed run holds someone past their time, and the same
  argument applies to an address somebody else will inherit from their ISP.
  """

  import Ecto.Query

  alias Baudrate.Auth.{IpBan, IpBanCache}
  alias Baudrate.Federation.HTTPClient
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Setup.User

  @permission "admin.manage_users"

  @min_prefix %{inet: 8, inet6: 16}
  @confirm_below %{inet: 16, inet6: 32}

  @type refusal ::
          :unauthorized
          | :invalid_address
          | :private_range
          | :too_broad
          | :needs_confirmation
          | :own_address

  @doc """
  Bans `input` — an address or a CIDR range — on behalf of `actor`.

  ## Options

    * `:actor_ip` — the acting admin's own address, so a range containing it is
      refused. Required: without it the most damaging mistake is unguarded.
    * `:confirm_broad` — `true` to accept a range broad enough to need it.

  `attrs` carries `"reason"` and `"expires_at"`. Writes a `ban_ip` entry to the
  moderation log.
  """
  @spec create(String.t(), map(), User.t(), keyword()) ::
          {:ok, IpBan.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def create(input, attrs, %User{} = actor, opts) do
    actor_ip = Keyword.fetch!(opts, :actor_ip)
    confirm_broad = Keyword.get(opts, :confirm_broad, false)

    with :ok <- authorize(actor),
         {:ok, parsed} <- parse(input),
         :ok <- refuse_private(parsed),
         :ok <- refuse_too_broad(parsed),
         :ok <- require_confirmation(parsed, confirm_broad),
         :ok <- refuse_own_address(parsed, actor_ip),
         {:ok, ban} <- insert(parsed, attrs, actor) do
      IpBanCache.refresh()

      Baudrate.Moderation.log_action(actor.id, "ban_ip",
        target_type: "ip_ban",
        target_id: ban.id,
        details: %{
          "range" => IpBan.to_cidr(ban),
          "reason" => ban.reason,
          "expires_at" => ban.expires_at && DateTime.to_iso8601(ban.expires_at)
        }
      )

      {:ok, ban}
    end
  end

  @doc "Lifts a ban. Writes an `unban_ip` entry to the moderation log."
  @spec delete(integer(), User.t()) :: :ok | {:error, :unauthorized | :not_found}
  def delete(ban_id, %User{} = actor) when is_integer(ban_id) do
    with :ok <- authorize(actor),
         %IpBan{} = ban <- Repo.get(IpBan, ban_id) do
      Repo.delete!(ban)
      IpBanCache.refresh()

      Baudrate.Moderation.log_action(actor.id, "unban_ip",
        target_type: "ip_ban",
        target_id: ban.id,
        details: %{"range" => IpBan.to_cidr(ban)}
      )

      :ok
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Every ban, newest first, expired ones included — the admin page shows both."
  @spec list() :: [IpBan.t()]
  def list do
    from(b in IpBan, order_by: [desc: b.inserted_at, desc: b.id], preload: :created_by)
    |> Repo.all()
  end

  @doc """
  Whether registration and sign-in are refused for `ip`.

  Takes an address tuple or a string. Anything that does not parse — including
  the `"unknown"` a LiveView assigns before its socket connects — is not
  banned: no submit can arrive from an unconnected page, and a fallback that
  refused would lock out every visitor whose address the page never learned.
  """
  @spec banned?(:inet.ip_address() | String.t() | nil) :: boolean()
  def banned?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> banned?(tuple)
      _ -> false
    end
  end

  def banned?(ip) when is_tuple(ip) do
    now = DateTime.utc_now()

    IpBanCache.active_ranges()
    |> Enum.any?(fn range -> active?(range, now) and IpBan.contains?(range, ip) end)
  end

  def banned?(_), do: false

  @doc """
  Every ban as the matcher reads it: the parsed range and its expiry.

  Read by `IpBanCache` to fill ETS, and directly when the cache is disabled in
  tests. Expired rows are returned too, because what is active is decided by
  the clock at the moment of the check, not at the moment of the refresh.
  """
  @spec ranges_from_db() :: [map()]
  def ranges_from_db do
    from(b in IpBan,
      select: %{address: b.address, prefix_length: b.prefix_length, expires_at: b.expires_at}
    )
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      case IpBan.parse("#{row.address}/#{row.prefix_length}") do
        {:ok, parsed} -> [Map.put(parsed, :expires_at, row.expires_at)]
        :error -> []
      end
    end)
  end

  @doc "Whether a ban row is currently in force."
  @spec active?(map(), DateTime.t()) :: boolean()
  def active?(%{expires_at: nil}, _now), do: true
  def active?(%{expires_at: at}, now), do: DateTime.compare(at, now) == :gt

  # --- refusals ---

  defp authorize(%User{} = actor) do
    name =
      case actor do
        %User{role: %{name: name}} when is_binary(name) -> name
        _ -> Repo.preload(actor, :role).role.name
      end

    if Setup.has_permission?(name, @permission), do: :ok, else: {:error, :unauthorized}
  end

  defp parse(input) do
    case IpBan.parse(input) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :invalid_address}
    end
  end

  # Both ends of the range, because a range that starts in public space and
  # ends in private space is still a range that contains the proxy.
  defp refuse_private(parsed) do
    if HTTPClient.private_ip?(parsed.tuple) or HTTPClient.private_ip?(IpBan.last_address(parsed)),
      do: {:error, :private_range},
      else: :ok
  end

  defp refuse_too_broad(%{family: family, prefix_length: prefix}) do
    if prefix < Map.fetch!(@min_prefix, family), do: {:error, :too_broad}, else: :ok
  end

  defp require_confirmation(%{family: family, prefix_length: prefix}, confirmed) do
    if prefix < Map.fetch!(@confirm_below, family) and confirmed != true,
      do: {:error, :needs_confirmation},
      else: :ok
  end

  defp refuse_own_address(parsed, actor_ip) do
    own =
      case actor_ip do
        ip when is_tuple(ip) -> {:ok, ip}
        ip when is_binary(ip) -> :inet.parse_address(String.to_charlist(ip))
        _ -> :error
      end

    case own do
      {:ok, tuple} -> if IpBan.contains?(parsed, tuple), do: {:error, :own_address}, else: :ok
      # An admin whose own address is unknown cannot be protected from banning
      # it, so the ban is refused rather than made blind.
      _ -> {:error, :own_address}
    end
  end

  defp insert(parsed, attrs, actor) do
    %IpBan{
      address: parsed.address,
      prefix_length: parsed.prefix_length,
      family: Atom.to_string(parsed.family),
      created_by_id: actor.id
    }
    |> IpBan.changeset(attrs)
    |> Repo.insert()
  end

  @doc "How broad a range may be before `:confirm_broad` is required, per family."
  def confirm_below, do: @confirm_below

  @doc "The broadest range accepted at all, per family."
  def min_prefix, do: @min_prefix
end
