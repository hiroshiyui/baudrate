defmodule Baudrate.Auth.Sanctions do
  @moduledoc """
  Sanctions short of a ban, and the single gate that enforces them (ADR 0029).

  ## One gate

  `ensure_can_interact/1` is the only check a context function needs before it
  lets an account create content or interact. It **replaces**
  `Baudrate.AccountMigration.ensure_not_moved/1` at every call site: a moved
  account, a silenced account, a suspended account and a banned account are
  all refused by the same function, so a new posting path cannot enforce one
  rule and forget the others.

  `test/baudrate/auth/sanctions_gate_test.exs` fails if `ensure_not_moved/1`
  is called anywhere outside this module.

  ## What a silence stops, and what it leaves alone

  Refused: articles, article edits, comments, feed replies, likes, boosts,
  forwards, poll votes, follows, direct messages, invites, and profile changes
  (display name, bio, avatar, links) — a bio is a billboard, and silencing
  someone who is then free to rewrite theirs at their target achieves nothing.

  Still allowed, deliberately: undoing an earlier like or boost, deleting
  their own content, **reporting abuse** (a silenced member must still be able
  to report), and everything about account security — password, second
  factors, sessions and data export.

  A suspension is enforced at sign-in (`Baudrate.Auth.authenticate_by_password/2`)
  rather than per interaction, and re-checked in `BaudrateWeb.AuthHooks`.
  """

  import Ecto.Query

  alias Baudrate.Auth.Sanction
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @restricting_kinds Sanction.restricting_kinds()

  @typedoc """
  Why an account may not act. `:account_moved` keeps the shape callers and
  flashes already handle (ADR 0025).
  """
  @type refusal :: :banned | :account_suspended | :account_silenced | :account_moved

  @doc """
  Returns `:ok` unless the account may not create content or interact.

  Takes a `User` (or any struct with an integer `id`), a user id, or `nil`.
  An unknown id and `nil` return `:ok`: there is no account to restrict, and
  the caller's own existence checks decide what that means.

  Refusals are returned strongest first — `:banned`, then
  `:account_suspended`, `:account_silenced`, `:account_moved` — so the message
  a member sees names the reason that actually has to be lifted first.

  ## Options

    * `:moved` — `:refuse` (the default) or `:allow`. A move is a redirect,
      not a punishment: ADR 0025 stops a moved account publishing anything,
      but deliberately lets it keep *following* accounts, so that the person
      can carry their reading list to their new home. A sanction has no such
      exception. Only the follow paths pass `moved: :allow`, and they are the
      only place the two rules differ.
  """
  @spec ensure_can_interact(User.t() | map() | integer() | nil, keyword()) ::
          :ok | {:error, refusal()}
  def ensure_can_interact(user, opts \\ [])

  def ensure_can_interact(%{id: id}, opts) when is_integer(id), do: ensure_can_interact(id, opts)

  def ensure_can_interact(user_id, opts) when is_integer(user_id) do
    refuse_moved? = Keyword.get(opts, :moved, :refuse) == :refuse

    case account_state(user_id) do
      nil ->
        :ok

      %{status: "banned"} ->
        {:error, :banned}

      state ->
        cond do
          "suspend" in state.kinds -> {:error, :account_suspended}
          "silence" in state.kinds -> {:error, :account_silenced}
          refuse_moved? and state.moved -> {:error, :account_moved}
          true -> :ok
        end
    end
  end

  def ensure_can_interact(_, _), do: :ok

  # One query: the account's status and redirect, plus the kinds of sanction
  # active on it right now. "Active" is read from the clock here rather than
  # from a flag some job maintains.
  defp account_state(user_id) do
    now = DateTime.utc_now()

    from(u in User,
      left_join: s in Sanction,
      on:
        s.user_id == u.id and s.kind in ^@restricting_kinds and is_nil(s.lifted_at) and
          (is_nil(s.expires_at) or s.expires_at > ^now),
      where: u.id == ^user_id,
      group_by: [u.id, u.status, u.moved_to],
      select: %{
        status: u.status,
        moved: not is_nil(u.moved_to),
        kinds: fragment("array_remove(array_agg(DISTINCT ?), NULL)", s.kind)
      }
    )
    |> Repo.one()
  end

  @doc """
  Returns `true` when the account may create content and interact. The
  boolean form of `ensure_can_interact/1`, for templates that hide a control
  the context would refuse anyway.
  """
  @spec can_interact?(User.t() | map() | integer() | nil, keyword()) :: boolean()
  def can_interact?(user, opts \\ []), do: ensure_can_interact(user, opts) == :ok

  @doc """
  Returns the account's active sanctions, strongest kind first and, within a
  kind, the one that ends furthest away.

  Several active rows of the same kind are allowed and harmless: the account
  is restricted while *any* of them is active, and the end shown is the
  furthest away (ADR 0029). So issuing can only extend a sanction; to shorten
  one, lift it.
  """
  @spec active_sanctions(User.t() | integer()) :: [Sanction.t()]
  def active_sanctions(%{id: id}) when is_integer(id), do: active_sanctions(id)

  def active_sanctions(user_id) when is_integer(user_id) do
    user_id
    |> active_query()
    |> Repo.all()
    |> Enum.sort_by(&{kind_rank(&1.kind), expiry_rank(&1.expires_at)})
  end

  @doc """
  Returns the active sanction of `kind` that ends furthest away, or `nil`.

  This is what a refusal message quotes: a member told "you cannot post" must
  also be told why and until when.
  """
  @spec active_sanction(User.t() | integer(), String.t()) :: Sanction.t() | nil
  def active_sanction(user, kind) when kind in @restricting_kinds do
    user
    |> active_sanctions()
    |> Enum.filter(&(&1.kind == kind))
    |> List.first()
  end

  @doc """
  Returns `true` when an active silence stands against the account.
  """
  @spec silenced?(User.t() | integer()) :: boolean()
  def silenced?(user), do: active?(user, "silence")

  @doc """
  Returns `true` when an active suspension stands against the account.
  """
  @spec suspended?(User.t() | integer()) :: boolean()
  def suspended?(user), do: active?(user, "suspend")

  defp active?(%{id: id}, kind) when is_integer(id), do: active?(id, kind)

  defp active?(user_id, kind) when is_integer(user_id) do
    user_id
    |> active_query()
    |> where([s], s.kind == ^kind)
    |> Repo.exists?()
  end

  defp active?(_, _), do: false

  @doc """
  Lists every sanction ever issued against the account, newest first, with
  the issuing and lifting moderators preloaded. Rows are never deleted, so
  this is the account's full record.
  """
  @spec list_sanctions(User.t() | integer()) :: [Sanction.t()]
  def list_sanctions(%{id: id}) when is_integer(id), do: list_sanctions(id)

  def list_sanctions(user_id) when is_integer(user_id) do
    from(s in Sanction,
      where: s.user_id == ^user_id,
      order_by: [desc: s.issued_at, desc: s.id],
      preload: [:issued_by, :lifted_by]
    )
    |> Repo.all()
  end

  @doc """
  Returns the query for the account's currently active **restricting**
  sanctions, for callers that want to compose further. Active is decided by
  the clock, never by a stored flag.

  A warning is never "active": it restricts nothing and has no duration, so
  it is history the moment it is issued. It appears in `list_sanctions/1`.
  """
  @spec active_query(integer()) :: Ecto.Query.t()
  def active_query(user_id) when is_integer(user_id) do
    now = DateTime.utc_now()

    from(s in Sanction,
      where:
        s.user_id == ^user_id and s.kind in ^@restricting_kinds and is_nil(s.lifted_at) and
          (is_nil(s.expires_at) or s.expires_at > ^now)
    )
  end

  defp kind_rank("suspend"), do: 0
  defp kind_rank("silence"), do: 1
  defp kind_rank(_), do: 2

  # An indefinite sanction (no end) outranks every dated one.
  defp expiry_rank(nil), do: {0, 0}
  defp expiry_rank(%DateTime{} = at), do: {1, -DateTime.to_unix(at)}
end
