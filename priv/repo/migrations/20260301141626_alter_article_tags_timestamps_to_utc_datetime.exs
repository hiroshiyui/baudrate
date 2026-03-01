defmodule Baudrate.Repo.Migrations.AlterArticleTagsTimestampsToUtcDatetime do
  use Ecto.Migration

  def change do
    alter table(:article_tags) do
      modify :inserted_at, :utc_datetime, from: :naive_datetime
    end
  end
end
