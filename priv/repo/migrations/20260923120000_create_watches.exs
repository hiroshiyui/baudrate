defmodule Baudrate.Repo.Migrations.CreateWatches do
  @moduledoc """
  Boards and threads a member asked to be told about (6C, ADR 0070).

  A row is created only by the member's own toggle, never as a side effect
  of posting or replying. Every reference cascades, so a watch goes with the
  member, the board or the article and nothing has to purge it.
  """

  use Ecto.Migration

  def change do
    create table(:watches) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :board_id, references(:boards, on_delete: :delete_all)
      add :article_id, references(:articles, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(:watches, :watch_exactly_one_target,
             check: "(board_id IS NULL) <> (article_id IS NULL)"
           )

    create unique_index(:watches, [:user_id, :board_id],
             where: "board_id IS NOT NULL",
             name: :watches_user_board_unique
           )

    create unique_index(:watches, [:user_id, :article_id],
             where: "article_id IS NOT NULL",
             name: :watches_user_article_unique
           )

    # The hooks ask "who watches this board / thread".
    create index(:watches, [:board_id], where: "board_id IS NOT NULL")
    create index(:watches, [:article_id], where: "article_id IS NOT NULL")
  end
end
