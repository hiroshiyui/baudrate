defmodule Baudrate.Moderation do
  @moduledoc """
  The Moderation context manages content reports and moderation actions.

  Reports can target articles, comments, or remote actors. Admins and
  moderators can review, resolve, or dismiss reports through the
  moderation queue.
  """

  import Ecto.Query

  alias Baudrate.Repo
  alias Baudrate.Moderation.Report

  @doc """
  Creates a new report.
  """
  def create_report(attrs) do
    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists reports filtered by status. Defaults to "open".
  Preloads reporter, article, comment, and remote_actor.
  """
  def list_reports(opts \\ []) do
    status = Keyword.get(opts, :status, "open")

    from(r in Report,
      where: r.status == ^status,
      order_by: [desc: r.inserted_at],
      preload: [:reporter, :article, :comment, :remote_actor, :resolved_by]
    )
    |> Repo.all()
  end

  @doc """
  Fetches a report by ID with all preloads, or raises.
  """
  def get_report!(id) do
    Report
    |> Repo.get!(id)
    |> Repo.preload([:reporter, :article, :comment, :remote_actor, :resolved_by])
  end

  @doc """
  Resolves a report with a resolution note, marking who resolved it.
  """
  def resolve_report(%Report{} = report, resolver_id, note \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    report
    |> Report.changeset(%{
      status: "resolved",
      resolved_by_id: resolver_id,
      resolved_at: now,
      resolution_note: note
    })
    |> Repo.update()
  end

  @doc """
  Dismisses a report (no action taken).
  """
  def dismiss_report(%Report{} = report, resolver_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    report
    |> Report.changeset(%{
      status: "dismissed",
      resolved_by_id: resolver_id,
      resolved_at: now
    })
    |> Repo.update()
  end

  @doc """
  Returns the count of open reports.
  """
  def open_report_count do
    Repo.one(from(r in Report, where: r.status == "open", select: count(r.id))) || 0
  end
end
