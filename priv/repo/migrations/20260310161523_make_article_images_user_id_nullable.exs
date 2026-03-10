defmodule Baudrate.Repo.Migrations.MakeArticleImagesUserIdNullable do
  use Ecto.Migration

  def up do
    # Make user_id nullable for remote article images (no local user)
    execute "ALTER TABLE article_images ALTER COLUMN user_id DROP NOT NULL"
  end

  def down do
    execute "ALTER TABLE article_images ALTER COLUMN user_id SET NOT NULL"
  end
end
