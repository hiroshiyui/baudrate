defmodule Baudrate.Repo.Migrations.CreateHeldPosts do
  use Ecto.Migration

  def change do
    # A submission waiting for a moderator — not an article or a comment with
    # a flag on it (ADR 0065). Nothing chokepoints the listings, so a flag
    # would have to be excluded by hand from every one of them; a row here is
    # in none of them to begin with.
    create table(:held_posts) do
      # article | comment
      add :kind, :string, null: false

      add :title, :string
      add :body, :text, null: false
      add :summary, :string
      add :sensitive, :boolean, null: false, default: false
      add :visibility, :string, null: false, default: "public"
      add :forwardable, :boolean, null: false, default: true

      # The article's boards and the uploads it carries, as the composer sent
      # them. Re-checked when a moderator approves, never trusted from here.
      add :board_ids, {:array, :integer}, null: false, default: []
      add :image_ids, {:array, :integer}, null: false, default: []
      # mode, options and how long it stays open, counted from approval.
      add :poll, :map

      # For a comment.
      add :article_id, references(:articles, on_delete: :delete_all)
      add :parent_id, references(:comments, on_delete: :nilify_all)

      # first_posts | filter
      add :reason, :string, null: false
      add :content_filter_id, references(:content_filters, on_delete: :nilify_all)

      # pending | rejected. An approved submission is not kept: it has become
      # the article or comment, in the same transaction.
      add :status, :string, null: false, default: "pending"
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
      add :review_note, :text

      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:held_posts, [:status, :inserted_at])
    create index(:held_posts, [:user_id, :status])
    create index(:held_posts, [:article_id])
    # Retention ages rejected rows by when they were reviewed.
    create index(:held_posts, [:reviewed_at], where: "status = 'rejected'")
  end
end
