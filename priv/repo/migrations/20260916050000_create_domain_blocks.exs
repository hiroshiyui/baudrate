defmodule Baudrate.Repo.Migrations.CreateDomainBlocks do
  @moduledoc """
  Moves the instance blocklist out of the `ap_domain_blocklist` setting and
  into rows that carry who blocked the domain, when, and why (ADR 0030).

  The setting is deleted in the same migration: two authorities for the same
  decision is what the ADR exists to remove.
  """

  use Ecto.Migration

  def up do
    create table(:domain_blocks) do
      add :domain, :string, null: false
      add :reason, :text
      add :public_comment, :text
      add :blocked_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:domain_blocks, [:domain])
    create index(:domain_blocks, [:blocked_by_id])

    flush()

    # Carry existing entries over. They have no author or reason — nothing
    # recorded one — so they arrive as bare rows rather than inventing either.
    execute(fn ->
      repo().query!("""
      INSERT INTO domain_blocks (domain, inserted_at, updated_at)
      SELECT DISTINCT lower(btrim(entry)), now(), now()
      FROM settings s,
           unnest(string_to_array(s.value, ',')) AS entry
      WHERE s.key = 'ap_domain_blocklist' AND btrim(entry) <> ''
      ON CONFLICT (domain) DO NOTHING
      """)

      repo().query!("DELETE FROM settings WHERE key = 'ap_domain_blocklist'")
    end)

    # Blocking now compares `remote_actors.domain` with SQL equality, where the
    # old ETS lookup downcased its key. The column was written straight from
    # `URI.parse(ap_id).host`, so it has to be normalized or an actor stored as
    # `Example.COM` stays visible under a block on `example.com`.
    #
    # Rows that would collide under the (username, domain) unique index are
    # left as they are: two actors differing only in the case of their domain
    # are not something a backfill should silently merge.
    execute(
      """
      UPDATE remote_actors ra
      SET domain = lower(ra.domain)
      WHERE ra.domain <> lower(ra.domain)
        AND NOT EXISTS (
          SELECT 1
          FROM remote_actors other
          WHERE other.username = ra.username
            AND other.domain = lower(ra.domain)
            AND other.id <> ra.id
        )
      """,
      ""
    )
  end

  def down do
    execute(fn ->
      %{rows: rows} = repo().query!("SELECT domain FROM domain_blocks ORDER BY domain")
      value = rows |> List.flatten() |> Enum.join(", ")

      repo().query!(
        """
        INSERT INTO settings (key, value, inserted_at, updated_at)
        VALUES ('ap_domain_blocklist', $1, now(), now())
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
        """,
        [value]
      )
    end)

    drop table(:domain_blocks)
  end
end
