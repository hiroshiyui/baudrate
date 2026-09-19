defmodule Baudrate.Repo.Migrations.AddContentWarnings do
  @moduledoc """
  Content warnings become fields instead of text (Phase 3E, ADR 0052).

  Until now an inbound `sensitive: true` object had its `summary` glued onto
  the front of the body as `[CW: …]`. That is a lossy one-way conversion: the
  warning becomes indistinguishable from the content it was meant to stand in
  front of, so nothing can render it collapsed, nothing can publish it back
  out as a warning, and the reader is shown the very thing they were being
  warned about with a label above it.

  `summary` is the warning text; `sensitive` is the flag Mastodon uses to mark
  media and text that should not be shown unprompted. Both are nullable and
  both are optional — the overwhelming majority of posts have neither.

  **Rows written before this keep their `[CW: …]` prefix.** No rewrite: the
  prefix sits inside sanitized HTML, and parsing it back out would be guessing
  at where the warning ends and the post begins. They are ordinary bodies now
  and will age out.

  No index. Nothing filters or sorts by either column; a content warning is
  read with the row it belongs to.
  """

  use Ecto.Migration

  def change do
    for table <- [:articles, :comments, :timeline_items, :timeline_item_replies] do
      alter table(table) do
        add :summary, :string, size: 512
        add :sensitive, :boolean, null: false, default: false
      end
    end
  end
end
