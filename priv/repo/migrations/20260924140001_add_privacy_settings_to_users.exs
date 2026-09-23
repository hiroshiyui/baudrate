defmodule Baudrate.Repo.Migrations.AddPrivacySettingsToUsers do
  use Ecto.Migration

  # Three settings a member controls on /profile/privacy (ADR 0073).
  def change do
    alter table(:users) do
      # Words or text that collapse other people's posts in this member's
      # own views: [%{"kind" => "word" | "substring", "pattern" => ...}].
      add :muted_keywords, {:array, :map}, null: false, default: []
      # A new follower waits for the member's approval.
      add :manually_approves_followers, :boolean, null: false, default: false
      # Off: noindex, out of the sitemap and the member search.
      add :discoverable, :boolean, null: false, default: true
    end
  end
end
