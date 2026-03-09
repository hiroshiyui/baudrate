defmodule Baudrate.Repo.Migrations.BackfillUrlFields do
  use Ecto.Migration

  def up do
    # Backfill url for local articles (have ap_id like {base}/ap/articles/{slug})
    # URL = replace "/ap/articles/" with "/articles/" in ap_id
    execute """
    UPDATE articles
    SET url = regexp_replace(ap_id, '/ap/articles/', '/articles/')
    WHERE url IS NULL
      AND ap_id IS NOT NULL
      AND user_id IS NOT NULL
      AND ap_id ~ '/ap/articles/'
    """

    # Backfill url for local comments (have user_id and ap_id)
    # URL = {base_url}/articles/{article.slug}#comment-{comment.id}
    # Extract base_url from the comment's ap_id (everything before "/ap/")
    execute """
    UPDATE comments
    SET url = regexp_replace(comments.ap_id, '/ap/.*', '')
              || '/articles/' || articles.slug
              || '#comment-' || comments.id
    FROM articles
    WHERE comments.article_id = articles.id
      AND comments.url IS NULL
      AND comments.ap_id IS NOT NULL
      AND comments.user_id IS NOT NULL
      AND comments.ap_id ~ '/ap/'
    """
  end

  def down do
    execute "UPDATE articles SET url = NULL WHERE user_id IS NOT NULL"
    execute "UPDATE comments SET url = NULL WHERE user_id IS NOT NULL"
  end
end
