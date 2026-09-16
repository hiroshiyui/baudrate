defmodule Baudrate.Federation.DomainBlocks do
  @moduledoc """
  Instance-level domain blocks (ADR 0030).

  A domain block is a row, not a fragment of a setting: it records who blocked
  the domain, when, and why, and it can be lifted again. `Federation.Validator`
  and everything behind it keep reading blocks through
  `Baudrate.Federation.DomainBlockCache`; this module is the only write path,
  and refreshes that cache on every change.

  Allowlist mode is deliberately *not* handled here (ADR 0030, decision 2): an
  allowlist is a configuration choice about who may reach us at all, and stays
  in `ap_domain_allowlist`.
  """

  import Ecto.Query

  alias Baudrate.Federation.{DomainBlock, DomainBlockCache}
  alias Baudrate.Repo

  @doc """
  Lists blocks, newest first, with the blocking admin preloaded.
  """
  @spec list_domain_blocks() :: [DomainBlock.t()]
  def list_domain_blocks do
    from(d in DomainBlock, order_by: [desc: d.inserted_at, desc: d.id], preload: [:blocked_by])
    |> Repo.all()
  end

  @doc """
  Returns every blocked domain as a `MapSet` of downcased strings.

  This is what `DomainBlockCache` loads; it is the hot path, so it selects the
  column rather than the rows.
  """
  @spec blocked_domains() :: MapSet.t(String.t())
  def blocked_domains do
    from(d in DomainBlock, select: d.domain)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns the number of blocked domains.
  """
  @spec count_domain_blocks() :: non_neg_integer()
  def count_domain_blocks, do: Repo.aggregate(DomainBlock, :count, :id)

  @doc """
  Fetches a block by domain. The domain is normalized first, so a pasted URL
  or handle finds the same row a bare domain would.
  """
  @spec get_domain_block(String.t()) :: DomainBlock.t() | nil
  def get_domain_block(domain) when is_binary(domain) do
    normalized = DomainBlock.normalize_domain(domain)

    from(d in DomainBlock, where: d.domain == ^normalized, preload: [:blocked_by])
    |> Repo.one()
  end

  @doc """
  Returns true if the domain has a block row.

  This asks about the row, not about whether federation with the domain is
  refused — in allowlist mode a domain can be refused without being blocked.
  Use `Federation.Validator.domain_blocked?/1` for the latter.
  """
  @spec blocked?(String.t()) :: boolean()
  def blocked?(domain) when is_binary(domain), do: get_domain_block(domain) != nil

  @doc """
  Blocks a domain.

  `attrs` may carry `:reason` and `:public_comment`. Returns
  `{:error, :already_blocked}` rather than a changeset when the domain is
  already blocked, so a caller can tell "nothing happened" from "the input was
  wrong" and log an audit entry only for a block that really happened.

  The caller is responsible for the moderation log entry: this function has no
  opinion about which surface the block came from.
  """
  @spec block_domain(String.t(), Baudrate.Setup.User.t() | nil, map()) ::
          {:ok, DomainBlock.t()} | {:error, :already_blocked} | {:error, Ecto.Changeset.t()}
  def block_domain(domain, blocked_by \\ nil, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("domain", domain)
      |> Map.put("blocked_by_id", blocked_by && blocked_by.id)

    %DomainBlock{}
    |> DomainBlock.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, block} ->
        refresh_cache()
        {:ok, block}

      {:error, changeset} ->
        # The unique index is the only thing that decides this, so two admins
        # blocking the same domain at once both get a coherent answer.
        if Keyword.has_key?(changeset.errors, :domain) and
             already_blocked?(changeset) do
          {:error, :already_blocked}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Lifts a block, by domain or by row.

  Returns `{:error, :not_found}` when the domain is not blocked. Unblocking
  restores no follows (ADR 0030, decision 4) — hidden content comes back by
  itself, because hiding was never a stamp on the rows.
  """
  @spec unblock_domain(String.t() | DomainBlock.t()) ::
          {:ok, DomainBlock.t()} | {:error, :not_found}
  def unblock_domain(%DomainBlock{} = block) do
    {:ok, block} = Repo.delete(block)
    refresh_cache()
    {:ok, block}
  end

  def unblock_domain(domain) when is_binary(domain) do
    case get_domain_block(domain) do
      nil -> {:error, :not_found}
      block -> unblock_domain(block)
    end
  end

  defp already_blocked?(changeset) do
    Enum.any?(changeset.errors, fn
      {:domain, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp refresh_cache, do: DomainBlockCache.refresh()
end
