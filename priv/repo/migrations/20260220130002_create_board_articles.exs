defmodule Baudrate.Repo.Migrations.CreateBoardArticles do
  use Ecto.Migration

  def change do
    create table(:board_articles) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :article_id, references(:articles, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_articles, [:board_id, :article_id])
    create index(:board_articles, [:article_id])
  end
end
