defmodule Baudrate.Repo.Migrations.CreateQuoteAuthorizations do
  use Ecto.Migration

  # ADR 0082: a quote of a local article is approved by a `QuoteAuthorization`
  # stamp (FEP-044f) that the quoting server dereferences. One row per
  # (article, quoting post); the row's id is the stamp's path, so it must stay
  # the same for as long as the quote is approved.
  def change do
    create table(:quote_authorizations) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:remote_actors, on_delete: :delete_all), null: false
      add :interacting_object_ap_id, :text, null: false
      add :request_ap_id, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:quote_authorizations, [:article_id, :interacting_object_ap_id])
    create index(:quote_authorizations, [:interacting_object_ap_id])
    create index(:quote_authorizations, [:remote_actor_id])
  end
end
