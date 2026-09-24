defmodule Baudrate.Repo.Migrations.AddFetchControlsToBots do
  use Ecto.Migration

  # Phase 7D: what a bot posts and how it asks for its feed.
  #
  #   * `include_patterns` / `exclude_patterns` — word and substring patterns
  #     (the admin content filters' own matcher) on an entry's title and text
  #   * `first_fetch_limit` — how many of the newest entries the first fetch
  #     posts; the rest of the backlog is recorded as seen and never posted
  #   * `etag` / `last_modified` — the validators of the last 200 response,
  #     sent back as `If-None-Match` / `If-Modified-Since`
  #
  # Existing bots have already fetched, so the limit never applies to them.
  def change do
    alter table(:bots) do
      add :include_patterns, {:array, :map}, null: false, default: []
      add :exclude_patterns, {:array, :map}, null: false, default: []
      add :first_fetch_limit, :integer, null: false, default: 5
      add :etag, :string, size: 512
      add :last_modified, :string, size: 128
    end
  end
end
