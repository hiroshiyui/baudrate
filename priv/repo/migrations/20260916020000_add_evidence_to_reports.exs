defmodule Baudrate.Repo.Migrations.AddEvidenceToReports do
  use Ecto.Migration

  # Content a moderator removes stays readable to staff in the report for 90
  # days, then is purged (P1-D6). The copy is taken when the content is
  # deleted, so the report still explains itself after the content is gone.
  def change do
    alter table(:reports) do
      add :evidence_body, :text
      add :evidence_taken_at, :utc_datetime
    end
  end
end
