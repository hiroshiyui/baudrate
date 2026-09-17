defmodule Baudrate.Repo.Migrations.AddKeyIdToRecoveryCodes do
  use Ecto.Migration

  # A recovery code is stored as a keyed hash, so it cannot be re-encrypted
  # under a new key the way the other secrets can — only the member's own code
  # could produce the new hash (ADR 0038). Recording which key hashed a row
  # lets codes issued under a retired key keep working, and lets the rotation
  # task say how many rows still depend on it.
  #
  # The default stamps every existing row as the `secret_key_base` derivation,
  # which is what they are. It stays: the column is advisory — verification
  # tries every configured key and never filters on it — so a row that somehow
  # misses a stamp still verifies, and only makes the report over-count. The
  # other direction, a NOT NULL violation, would mean a member who cannot get
  # recovery codes at all.
  def change do
    alter table(:recovery_codes) do
      add :key_id, :string, size: 32, null: false, default: "legacy"
    end
  end
end
