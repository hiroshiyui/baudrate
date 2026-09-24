defmodule Baudrate.Dashboard do
  @moduledoc """
  The counts behind `/admin` (Phase 7A, ADR 0074): the state of the site on
  one page, so running it does not need a shell.

  Everything here is a count. The page links to the queue each number comes
  from rather than listing its rows, so this module names no account, board
  or remote domain, and it ranks nothing (ADR 0054) — it measures the site,
  not what members wrote.

  The health checks are not repeated here: the page reads
  `Baudrate.Health.report/1` itself, which is what keeps it and the loopback
  report (ADR 0035) from disagreeing.
  """

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Federation.{DeliveryStats, DomainBlocks, RemoteActor}
  alias Baudrate.Moderation
  alias Baudrate.Moderation.HeldPosts
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @doc """
  Members, by `Auth.counted_members_query/0` — the same accounts NodeInfo
  counts: the total, those active in the last 30 days (`last_active_on`),
  and those who joined in the last 7 and 30 days.
  """
  @spec members(Date.t()) :: %{
          total: non_neg_integer(),
          active_month: non_neg_integer(),
          new_week: non_neg_integer(),
          new_month: non_neg_integer()
        }
  def members(today \\ Date.utc_today()) do
    members = Auth.counted_members_query()
    week_start = today |> Date.add(-7) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    month_start = today |> Date.add(-30) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    %{
      total: count(members),
      active_month: count(where(members, [u], u.last_active_on >= ^Date.add(today, -30))),
      new_week: count(where(members, [u], u.inserted_at >= ^week_start)),
      new_month: count(where(members, [u], u.inserted_at >= ^month_start))
    }
  end

  @doc """
  What is waiting for `reviewer`: open reports, posts held for review (only
  those `reviewer` could approve, like `/moderation/held`), and registrations
  waiting to be let in.
  """
  @spec moderation(map()) :: %{
          open_reports: non_neg_integer(),
          held_posts: non_neg_integer(),
          pending_registrations: non_neg_integer()
        }
  def moderation(reviewer) do
    %{
      open_reports: Moderation.open_report_count(),
      held_posts: HeldPosts.count_pending(reviewer),
      pending_registrations: count(from(u in User, where: u.status == "pending" and not u.is_bot))
    }
  end

  @doc """
  The federation figures the health report does not carry: deliveries that
  have failed and are waiting for a retry, blocked domains, and remote
  accounts suspended here.
  """
  @spec federation() :: %{
          failed_deliveries: non_neg_integer(),
          blocked_domains: non_neg_integer(),
          suspended_actors: non_neg_integer()
        }
  def federation do
    %{
      failed_deliveries: Map.get(DeliveryStats.status_counts(), "failed", 0),
      blocked_domains: DomainBlocks.count_domain_blocks(),
      suspended_actors: count(from(a in RemoteActor, where: not is_nil(a.suspended_at)))
    }
  end

  defp count(query), do: Repo.aggregate(query, :count) || 0
end
