defmodule Baudrate.Repo.Migrations.BackfillLocalApIds do
  @moduledoc """
  Backfills `ap_id` for local articles, comments, article_likes, polls,
  and direct_messages that were created before AP ID stamping was added.

  Uses raw SQL for efficiency. The base URL is derived from the endpoint
  configuration at migration time.
  """

  use Ecto.Migration

  def up do
    base_url = endpoint_base_url()

    # 1. Articles: {base_url}/ap/articles/{slug}
    execute("""
    UPDATE articles
    SET ap_id = '#{base_url}/ap/articles/' || slug
    WHERE user_id IS NOT NULL
      AND ap_id IS NULL
    """)

    # 2. Comments: {base_url}/ap/users/{username}#note-{id}
    execute("""
    UPDATE comments
    SET ap_id = '#{base_url}/ap/users/' || u.username || '#note-' || comments.id::text
    FROM users u
    WHERE comments.user_id = u.id
      AND comments.ap_id IS NULL
    """)

    # 3. Article likes: {base_url}/ap/users/{username}#like-{id}
    execute("""
    UPDATE article_likes
    SET ap_id = '#{base_url}/ap/users/' || u.username || '#like-' || article_likes.id::text
    FROM users u
    WHERE article_likes.user_id = u.id
      AND article_likes.ap_id IS NULL
    """)

    # 4. Polls: {article.ap_id}#poll (depends on articles being backfilled first)
    execute("""
    UPDATE polls
    SET ap_id = a.ap_id || '#poll'
    FROM articles a
    WHERE polls.article_id = a.id
      AND a.user_id IS NOT NULL
      AND a.ap_id IS NOT NULL
      AND polls.ap_id IS NULL
    """)

    # 5. Direct messages: {base_url}/ap/users/{username}#dm-{id}
    execute("""
    UPDATE direct_messages
    SET ap_id = '#{base_url}/ap/users/' || u.username || '#dm-' || direct_messages.id::text
    FROM users u
    WHERE direct_messages.sender_user_id = u.id
      AND direct_messages.ap_id IS NULL
    """)
  end

  def down do
    base_url = endpoint_base_url()

    execute("""
    UPDATE direct_messages SET ap_id = NULL
    WHERE ap_id LIKE '#{base_url}/ap/users/%#dm-%'
    """)

    execute("""
    UPDATE polls SET ap_id = NULL
    WHERE ap_id LIKE '#{base_url}/ap/articles/%#poll'
    """)

    execute("""
    UPDATE article_likes SET ap_id = NULL
    WHERE ap_id LIKE '#{base_url}/ap/users/%#like-%'
    """)

    execute("""
    UPDATE comments SET ap_id = NULL
    WHERE ap_id LIKE '#{base_url}/ap/users/%#note-%'
    """)

    execute("""
    UPDATE articles SET ap_id = NULL
    WHERE ap_id LIKE '#{base_url}/ap/articles/%'
      AND user_id IS NOT NULL
    """)
  end

  # Derives the base URL from endpoint config without requiring the
  # endpoint to be started (which isn't available during migrations).
  defp endpoint_base_url do
    config = Application.get_env(:baudrate, BaudrateWeb.Endpoint, [])

    case config[:base_url] do
      url when is_binary(url) ->
        String.trim_trailing(url, "/")

      _ ->
        url_config = config[:url] || []
        scheme = Keyword.get(url_config, :scheme, "https")
        host = Keyword.get(url_config, :host, "localhost")
        port = Keyword.get(url_config, :port, 443)

        case {scheme, port} do
          {"https", 443} -> "#{scheme}://#{host}"
          {"http", 80} -> "#{scheme}://#{host}"
          _ -> "#{scheme}://#{host}:#{port}"
        end
    end
  end
end
