defmodule Baudrate.Repo.Migrations.AddContentWarningToArticleRevisions do
  use Ecto.Migration

  @moduledoc """
  Article revisions snapshotted the title and body only, so removing a content
  warning left no trace in the history.

  Rows written before this migration keep NULL / false: the value is unknown,
  not known to be absent, and backfilling a guess would be worse than saying so.
  """

  def change do
    alter table(:article_revisions) do
      add :summary, :string
      add :sensitive, :boolean, null: false, default: false
    end
  end
end
