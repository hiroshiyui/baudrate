defmodule Mix.Tasks.BackfillApIds do
  @moduledoc """
  Backfills missing `ap_id` fields on local articles, polls, and comments.

  Thin wrapper around `Baudrate.Release.backfill_ap_ids/1` for dev / test.
  In production (an OTP release) Mix tasks aren't available — invoke the
  Release task instead:

      bin/baudrate eval "Baudrate.Release.backfill_ap_ids()"
      bin/baudrate eval "Baudrate.Release.backfill_ap_ids(dry_run: true)"

  Locally:

      mix backfill_ap_ids
      mix backfill_ap_ids --dry-run

  See `Baudrate.Release.backfill_ap_ids/1` for the underlying behaviour.
  """

  use Mix.Task

  @shortdoc "Backfill missing ap_id fields on local articles, polls, and comments"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    dry_run = "--dry-run" in args

    result = Baudrate.Release.backfill_ap_ids(dry_run: dry_run)

    {a_total, a_stamped} = result.articles
    {p_total, p_stamped} = result.polls
    {c_total, c_stamped} = result.comments

    Mix.shell().info("\nSummary:")
    Mix.shell().info("  Articles: #{a_stamped}/#{a_total} stamped")
    Mix.shell().info("  Polls:    #{p_stamped}/#{p_total} stamped")
    Mix.shell().info("  Comments: #{c_stamped}/#{c_total} stamped")
  end
end
