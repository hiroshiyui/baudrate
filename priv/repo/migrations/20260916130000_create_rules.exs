defmodule Baudrate.Repo.Migrations.CreateRules do
  @moduledoc """
  Turns the site rules from one markdown document into a list of records, so a
  report can cite the rule it says was broken (P1-D9).

  The `rule_violation` report category already existed and could only say
  "breaks a rule", never which — because there was nothing to point at. A
  single markdown blob has no addressable parts.

  A rule is retired rather than deleted (`retired_at`): it then disappears from
  `/rules` and from the report dialog, but a report filed months ago still
  resolves to the rule its author meant. Hard-deleting would quietly empty the
  citation on every past report that named it.
  """

  use Ecto.Migration

  def up do
    create table(:rules) do
      add :position, :integer, null: false
      add :title, :string, null: false
      add :body, :text
      add :retired_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:rules, [:position])

    alter table(:reports) do
      add :rule_id, references(:rules, on_delete: :nilify_all)
    end

    create index(:reports, [:rule_id])

    flush()

    execute(fn ->
      # Whatever an instance already wrote becomes the first rule, so nothing
      # is lost. The admin can split it up afterwards; we cannot guess where
      # one rule ends and the next begins.
      repo().query!("""
      INSERT INTO rules (position, title, body, inserted_at, updated_at)
      SELECT 1, 'Site rules', s.value, now(), now()
      FROM settings s
      WHERE s.key = 'rules' AND btrim(s.value) <> ''
      """)

      repo().query!("DELETE FROM settings WHERE key = 'rules'")
    end)
  end

  def down do
    execute(fn ->
      # Fold the rules back into one document, so rolling back leaves the text
      # readable rather than dropping it on the floor.
      repo().query!("""
      INSERT INTO settings (key, value, inserted_at, updated_at)
      SELECT 'rules',
             string_agg(
               '## ' || r.title || E'\\n\\n' || coalesce(r.body, ''),
               E'\\n\\n' ORDER BY r.position, r.id
             ),
             now(), now()
      FROM rules r
      WHERE r.retired_at IS NULL
      HAVING count(*) > 0
      ON CONFLICT (key) DO NOTHING
      """)
    end)

    alter table(:reports) do
      remove :rule_id
    end

    drop table(:rules)
  end
end
