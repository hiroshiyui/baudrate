defmodule Baudrate.Auth.Invites do
  @moduledoc """
  Handles invite code generation, validation, and usage.
  """

  import Ecto.Query
  alias Baudrate.Repo
  alias Baudrate.Auth.InviteCode
  alias Baudrate.Setup.User

  @invite_quota_limit 5
  @invite_quota_window_days 30
  @invite_default_expiry_days 7

  @doc """
  Checks whether a user can generate an invite code.

  Returns `{:ok, remaining}` where remaining is an integer or `:unlimited`,
  or `{:error, reason}`.

  ## Checks

    1. Admin role → `{:ok, :unlimited}` (bypasses all limits)
    2. Quota remaining > 0 within rolling #{@invite_quota_window_days}-day window
  """
  @spec can_generate_invite?(User.t()) ::
          {:ok, integer() | :unlimited} | {:error, :invite_quota_exceeded}
  def can_generate_invite?(%User{} = user) do
    cond do
      user.role.name == "admin" ->
        {:ok, :unlimited}

      true ->
        remaining = invite_quota_remaining(user)

        if remaining > 0 do
          {:ok, remaining}
        else
          {:error, :invite_quota_exceeded}
        end
    end
  end

  @doc """
  Returns the number of invite codes the user can still generate in the
  current #{@invite_quota_window_days}-day rolling window (0–#{@invite_quota_limit}).

  Admin users always return #{@invite_quota_limit} (they have unlimited quota
  but this function returns the limit for display consistency).
  """
  @spec invite_quota_remaining(User.t()) :: non_neg_integer()
  def invite_quota_remaining(%User{} = user) do
    if user.role.name == "admin" do
      @invite_quota_limit
    else
      cutoff =
        DateTime.utc_now()
        |> DateTime.add(-@invite_quota_window_days * 86_400, :second)

      count =
        from(i in InviteCode,
          where: i.created_by_id == ^user.id and i.inserted_at > ^cutoff,
          select: count(i.id)
        )
        |> Repo.one()

      max(@invite_quota_limit - count, 0)
    end
  end

  @doc """
  Returns the invite quota limit constant.
  """
  def invite_quota_limit, do: @invite_quota_limit

  @doc """
  Lists invite codes created by a specific user, newest first, with `:used_by` preloaded.
  """
  def list_user_invite_codes(%User{id: user_id}) do
    from(i in InviteCode,
      where: i.created_by_id == ^user_id,
      order_by: [desc: i.inserted_at, desc: i.id],
      preload: [:used_by]
    )
    |> Repo.all()
  end

  @doc """
  Generates an invite code created by the given user.

  Requires a `%User{}` struct with role preloaded. Enforces quota for non-admin
  users and auto-sets expiry to #{@invite_default_expiry_days} days for non-admins.

  ## Options

    * `:max_uses` — max number of times the code can be used (default 1)
    * `:expires_in_days` — number of days until expiration (forced to
      #{@invite_default_expiry_days} for non-admins unless a shorter value is provided)
  """
  @spec generate_invite_code(User.t(), keyword()) ::
          {:ok, InviteCode.t()}
          | {:error, Ecto.Changeset.t() | :invite_quota_exceeded}
  def generate_invite_code(%User{} = user, opts \\ []) do
    case can_generate_invite?(user) do
      {:ok, _remaining} ->
        do_generate_invite_code(user, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates an invite code on behalf of a target user, callable only by admins.

  Bypasses the account age restriction but still enforces the rolling
  #{@invite_quota_window_days}-day quota (max #{@invite_quota_limit} codes).
  The code's `created_by_id` is set to the target user.

  Uses admin expiry rules (no forced #{@invite_default_expiry_days}-day cap).

  Returns `{:ok, invite_code}` or `{:error, reason}`.

  ## Errors

    * `{:error, :unauthorized}` — caller is not an admin
    * `{:error, :invite_quota_exceeded}` — target user's quota is exhausted
  """
  def admin_generate_invite_code_for_user(%User{} = admin, %User{} = target_user, opts \\ []) do
    if admin.role.name != "admin" do
      {:error, :unauthorized}
    else
      remaining = invite_quota_remaining(target_user)

      if remaining <= 0 do
        {:error, :invite_quota_exceeded}
      else
        do_generate_invite_code(target_user, opts)
      end
    end
  end

  defp do_generate_invite_code(%User{} = user, opts) do
    code = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    max_uses = Keyword.get(opts, :max_uses, 1)

    expires_in_days =
      if user.role.name == "admin" do
        Keyword.get(opts, :expires_in_days)
      else
        explicit = Keyword.get(opts, :expires_in_days)

        cond do
          is_nil(explicit) -> @invite_default_expiry_days
          explicit > @invite_default_expiry_days -> @invite_default_expiry_days
          true -> explicit
        end
      end

    expires_at =
      case expires_in_days do
        nil ->
          nil

        days ->
          DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.truncate(:second)
      end

    %InviteCode{}
    |> InviteCode.changeset(%{
      code: code,
      created_by_id: user.id,
      max_uses: max_uses,
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  @doc """
  Returns an invite code by ID, or nil if not found.
  """
  @spec get_invite_code(integer()) :: InviteCode.t() | nil
  def get_invite_code(id) do
    Repo.get(InviteCode, id)
  end

  @doc """
  Validates an invite code string.

  Returns `{:ok, invite}` if valid, or `{:error, reason}` if invalid.
  """
  @spec validate_invite_code(String.t() | any()) ::
          {:ok, InviteCode.t()} | {:error, :not_found | :revoked | :expired | :fully_used}
  def validate_invite_code(code) when is_binary(code) do
    case Repo.one(from(i in InviteCode, where: i.code == ^code, preload: [:created_by])) do
      nil ->
        {:error, :not_found}

      %InviteCode{revoked: true} ->
        {:error, :revoked}

      %InviteCode{expires_at: expires_at} = invite when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          {:error, :expired}
        else
          check_uses(invite)
        end

      invite ->
        check_uses(invite)
    end
  end

  def validate_invite_code(_), do: {:error, :not_found}

  defp check_uses(%InviteCode{use_count: use_count, max_uses: max_uses})
       when use_count >= max_uses do
    {:error, :fully_used}
  end

  defp check_uses(invite), do: {:ok, invite}

  @doc """
  Records the use of an invite code by a new user.
  """
  def use_invite_code(%InviteCode{} = invite, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    invite
    |> InviteCode.use_changeset(%{
      used_by_id: user_id,
      used_at: now,
      use_count: invite.use_count + 1
    })
    |> Repo.update()
  end

  @doc """
  Lists all invite codes with preloads, newest first.
  """
  def list_all_invite_codes do
    from(i in InviteCode,
      order_by: [desc: i.inserted_at, desc: i.id],
      preload: [:created_by, :used_by]
    )
    |> Repo.all()
  end

  @invites_per_page 30

  @doc """
  Lists all invite codes with pagination, newest first.

  ## Options

    * `:page` — page number (default 1)
    * `:per_page` — items per page (default #{@invites_per_page})

  Returns `%{codes: [...], total: N, page: N, per_page: N, total_pages: N}`.
  """
  def list_all_invite_codes(opts) do
    alias Baudrate.Pagination

    pagination = Pagination.paginate_opts(opts, @invites_per_page)

    from(i in InviteCode)
    |> Pagination.paginate_query(pagination,
      result_key: :codes,
      order_by: [desc: dynamic([i], i.inserted_at), desc: dynamic([i], i.id)],
      preloads: [:created_by, :used_by]
    )
  end

  @doc """
  Revokes an invite code.
  """
  @spec revoke_invite_code(InviteCode.t()) :: {:ok, InviteCode.t()} | {:error, Ecto.Changeset.t()}
  def revoke_invite_code(%InviteCode{} = invite) do
    invite
    |> InviteCode.revoke_changeset()
    |> Repo.update()
  end

  @doc """
  Bulk-revokes all active invite codes created by the given user.

  Active = not revoked, not expired, and not fully used.
  Returns `{count, nil}` with the number of revoked codes.
  """
  def revoke_invite_codes_for_user(user_id) do
    now = DateTime.utc_now()

    from(i in InviteCode,
      where: i.created_by_id == ^user_id,
      where: i.revoked == false,
      where: is_nil(i.expires_at) or i.expires_at > ^now,
      where: i.use_count < i.max_uses
    )
    |> Repo.update_all(set: [revoked: true])
  end
end
