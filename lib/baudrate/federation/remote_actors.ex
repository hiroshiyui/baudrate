defmodule Baudrate.Federation.RemoteActors do
  @moduledoc """
  Instance-wide suspension of a single remote actor (ADR 0030, decision 6).

  A domain block is often too blunt: a report about one account on a large
  instance should not have to take out every innocent account on it. Suspending
  one actor is the same mechanism at a smaller scale — its activities are
  refused at the inbox and its content is hidden everywhere a domain block
  would hide it, through the same predicate
  (`Content.Filters.hidden_actor_ids/0`), and it is lifted by clearing the
  stamp. Nothing is deleted either way.
  """

  import Ecto.Query

  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Repo

  @doc """
  Lists remote actors on a domain, suspended ones first, then by username.
  """
  @spec list_actors_for_domain(String.t()) :: [RemoteActor.t()]
  def list_actors_for_domain(domain) when is_binary(domain) do
    domain = String.downcase(domain)

    from(ra in RemoteActor,
      where: ra.domain == ^domain,
      order_by: [desc_nulls_last: ra.suspended_at, asc: ra.username],
      preload: [:suspended_by]
    )
    |> Repo.all()
  end

  @doc """
  Lists every suspended remote actor, most recently suspended first.
  """
  @spec list_suspended() :: [RemoteActor.t()]
  def list_suspended do
    from(ra in RemoteActor,
      where: not is_nil(ra.suspended_at),
      order_by: [desc: ra.suspended_at, desc: ra.id],
      preload: [:suspended_by]
    )
    |> Repo.all()
  end

  @doc "Fetches a remote actor by id, with the suspending admin preloaded."
  @spec get_remote_actor(integer()) :: RemoteActor.t() | nil
  def get_remote_actor(id) when is_integer(id) do
    Repo.one(from ra in RemoteActor, where: ra.id == ^id, preload: [:suspended_by])
  end

  @doc """
  Returns true if this actor is suspended instance-wide.
  """
  @spec suspended?(RemoteActor.t() | nil) :: boolean()
  def suspended?(%RemoteActor{suspended_at: nil}), do: false
  def suspended?(%RemoteActor{suspended_at: _}), do: true
  def suspended?(_), do: false

  @doc """
  Suspends a remote actor instance-wide.

  The caller records the moderation log entry. Returns `{:error, :already_suspended}`
  rather than re-stamping, so the original decision keeps its date and author.
  """
  @spec suspend(RemoteActor.t(), Baudrate.Setup.User.t() | nil, String.t()) ::
          {:ok, RemoteActor.t()} | {:error, :already_suspended} | {:error, Ecto.Changeset.t()}
  def suspend(%RemoteActor{} = actor, suspended_by, reason) do
    if suspended?(actor) do
      {:error, :already_suspended}
    else
      actor
      |> RemoteActor.suspension_changeset(%{
        suspended_at: DateTime.utc_now() |> DateTime.truncate(:second),
        suspend_reason: reason,
        suspended_by_id: suspended_by && suspended_by.id
      })
      |> Repo.update()
    end
  end

  @doc """
  Lifts a suspension. The actor's content becomes visible again by itself,
  because hiding was never stamped on the content.
  """
  @spec unsuspend(RemoteActor.t()) ::
          {:ok, RemoteActor.t()} | {:error, :not_suspended} | {:error, Ecto.Changeset.t()}
  def unsuspend(%RemoteActor{} = actor) do
    if suspended?(actor) do
      actor
      |> RemoteActor.suspension_changeset(%{
        suspended_at: nil,
        suspend_reason: nil,
        suspended_by_id: nil
      })
      |> Repo.update()
    else
      {:error, :not_suspended}
    end
  end
end
