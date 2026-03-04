defmodule Baudrate.Content do
  @moduledoc """
  The Content context manages boards, articles, comments, and likes.

  Boards are organized hierarchically via `parent_id`. Articles can be
  cross-posted to multiple boards through the `board_articles` join table.
  Comments support threading via `parent_id`. Likes track article and comment
  favorites from both local users and remote actors.

  Content mutations that are federation-relevant (`create_article/2`,
  `soft_delete_article/1`, `forward_article_to_board/3`) automatically
  enqueue delivery of the corresponding ActivityPub activities to remote
  followers via `Federation.Publisher` and `Federation.TaskSupervisor`.

  This module is a facade — all implementations live in focused sub-modules
  under `Baudrate.Content.*`:

    * `Content.Filters` — shared query helpers (block/mute, role visibility)
    * `Content.Boards` — board CRUD, moderators, SysOp board
    * `Content.Permissions` — board access checks, granular permissions, slug generation
    * `Content.Articles` — article CRUD, cross-posting, revisions, pin/lock
    * `Content.Comments` — comment CRUD, threading, activity timestamps
    * `Content.Likes` — article and comment likes
    * `Content.Bookmarks` — article and comment bookmarks
    * `Content.Images` — article image management
    * `Content.Tags` — hashtag extraction, syncing, and querying
    * `Content.Search` — full-text search across articles, comments, and boards
    * `Content.Feed` — public feed queries, user content statistics
    * `Content.ReadTracking` — per-user read state for articles and boards
    * `Content.Polls` — poll creation, voting, and counter management
  """

  alias Baudrate.Content.{
    Articles,
    Boards,
    Bookmarks,
    Comments,
    Feed,
    Images,
    Likes,
    Permissions,
    Polls,
    ReadTracking,
    Search,
    Tags
  }

  # --- Boards ---

  defdelegate list_top_boards(), to: Boards
  defdelegate list_visible_top_boards(user), to: Boards
  defdelegate list_sub_boards(board), to: Boards
  defdelegate list_visible_sub_boards(board, user), to: Boards
  defdelegate board_ancestors(board), to: Boards
  defdelegate get_board(id), to: Boards
  defdelegate get_board!(id), to: Boards
  defdelegate list_all_boards(), to: Boards
  defdelegate create_board(attrs), to: Boards
  defdelegate update_board(board, attrs), to: Boards
  defdelegate delete_board(board), to: Boards
  defdelegate toggle_board_federation(board), to: Boards
  defdelegate get_board_by_slug(slug), to: Boards
  defdelegate get_board_by_slug!(slug), to: Boards
  defdelegate list_board_moderators(board), to: Boards
  defdelegate add_board_moderator(board_id, user_id), to: Boards
  defdelegate remove_board_moderator(board_id, user_id), to: Boards
  defdelegate seed_sysop_board(user), to: Boards

  def change_board(board \\ %Baudrate.Content.Board{}, attrs \\ %{}),
    do: Boards.change_board(board, attrs)

  # --- Permissions ---

  defdelegate can_view_board?(board, user), to: Permissions
  defdelegate can_post_in_board?(board, user), to: Permissions
  defdelegate board_moderator?(board, user), to: Permissions
  defdelegate can_moderate_article?(user, article), to: Permissions
  defdelegate can_comment_on_article?(user, article), to: Permissions
  defdelegate can_edit_article?(user, article), to: Permissions
  defdelegate can_delete_article?(user, article), to: Permissions
  defdelegate can_pin_article?(user, article), to: Permissions
  defdelegate can_lock_article?(user, article), to: Permissions
  defdelegate can_delete_comment?(user, comment, article), to: Permissions
  defdelegate can_forward_article?(user, article), to: Permissions
  defdelegate generate_slug(title), to: Permissions

  # --- Articles ---

  defdelegate list_articles_for_board(board), to: Articles
  defdelegate get_article_by_slug!(slug), to: Articles
  defdelegate create_article(attrs, board_ids, opts), to: Articles
  defdelegate add_article_to_board(article, board_id), to: Articles
  defdelegate forward_article_to_board(article, board, user), to: Articles
  defdelegate remove_article_from_board(article, board, user), to: Articles
  defdelegate create_remote_article(attrs, board_ids, opts), to: Articles
  defdelegate get_article(id), to: Articles
  defdelegate get_article_by_ap_id(ap_id), to: Articles
  defdelegate soft_delete_article(article), to: Articles
  defdelegate update_remote_article(article, attrs), to: Articles
  defdelegate create_article_revision(article, editor), to: Articles
  defdelegate list_article_revisions(article_id), to: Articles
  defdelegate get_article_revision!(id), to: Articles
  defdelegate count_article_revisions(article_id), to: Articles
  defdelegate toggle_pin_article(article), to: Articles
  defdelegate toggle_lock_article(article), to: Articles

  def paginate_articles_for_board(board, opts \\ []),
    do: Articles.paginate_articles_for_board(board, opts)

  def create_article(attrs, board_ids),
    do: Articles.create_article(attrs, board_ids, [])

  def change_article(article \\ %Baudrate.Content.Article{}, attrs \\ %{}),
    do: Articles.change_article(article, attrs)

  def change_article_for_edit(article, attrs \\ %{}),
    do: Articles.change_article_for_edit(article, attrs)

  def update_article(article, attrs),
    do: Articles.update_article(article, attrs)

  def update_article(article, attrs, editor),
    do: Articles.update_article(article, attrs, editor)

  def create_remote_article(attrs, board_ids),
    do: Articles.create_remote_article(attrs, board_ids, [])

  # --- Comments ---

  defdelegate create_comment(attrs), to: Comments
  defdelegate create_remote_comment(attrs), to: Comments
  defdelegate get_comment(id), to: Comments
  defdelegate get_comment_by_ap_id(ap_id), to: Comments
  defdelegate soft_delete_comment(comment), to: Comments
  defdelegate update_remote_comment(comment, attrs), to: Comments
  defdelegate count_comments_for_article(article), to: Comments

  def change_comment(comment \\ %Baudrate.Content.Comment{}, attrs \\ %{}),
    do: Comments.change_comment(comment, attrs)

  def list_comments_for_article(article, current_user \\ nil),
    do: Comments.list_comments_for_article(article, current_user)

  def paginate_comments_for_article(article, current_user \\ nil, opts \\ []),
    do: Comments.paginate_comments_for_article(article, current_user, opts)

  # --- Article Likes ---

  defdelegate create_remote_article_like(attrs), to: Likes
  defdelegate count_article_likes(article), to: Likes
  defdelegate like_article(user_id, article_id), to: Likes
  defdelegate unlike_article(user_id, article_id), to: Likes
  defdelegate article_liked?(user_id, article_id), to: Likes
  defdelegate toggle_article_like(user_id, article_id), to: Likes

  def delete_article_like_by_ap_id(ap_id),
    do: Likes.delete_article_like_by_ap_id(ap_id)

  def delete_article_like_by_ap_id(ap_id, remote_actor_id),
    do: Likes.delete_article_like_by_ap_id(ap_id, remote_actor_id)

  # --- Comment Likes ---

  defdelegate like_comment(user_id, comment_id), to: Likes
  defdelegate unlike_comment(user_id, comment_id), to: Likes
  defdelegate comment_liked?(user_id, comment_id), to: Likes
  defdelegate count_comment_likes(comment), to: Likes
  defdelegate toggle_comment_like(user_id, comment_id), to: Likes
  defdelegate comment_likes_by_user(user_id, comment_ids), to: Likes
  defdelegate comment_like_counts(comment_ids), to: Likes

  # --- Bookmarks ---

  defdelegate bookmark_article(user_id, article_id), to: Bookmarks
  defdelegate bookmark_comment(user_id, comment_id), to: Bookmarks
  defdelegate delete_bookmark(user_id, bookmark_id), to: Bookmarks
  defdelegate article_bookmarked?(user_id, article_id), to: Bookmarks
  defdelegate comment_bookmarked?(user_id, comment_id), to: Bookmarks
  defdelegate toggle_article_bookmark(user_id, article_id), to: Bookmarks
  defdelegate toggle_comment_bookmark(user_id, comment_id), to: Bookmarks

  def list_bookmarks(user_id, opts \\ []),
    do: Bookmarks.list_bookmarks(user_id, opts)

  # --- Article Images ---

  defdelegate create_article_image(attrs), to: Images
  defdelegate list_article_images(article_id), to: Images
  defdelegate list_orphan_article_images(user_id), to: Images
  defdelegate delete_article_image(image), to: Images
  defdelegate associate_article_images(article_id, image_ids, user_id), to: Images
  defdelegate get_article_image!(id), to: Images
  defdelegate count_article_images(article_id), to: Images
  defdelegate delete_orphan_article_images(cutoff), to: Images

  # --- Article Tags ---

  defdelegate extract_tags(text), to: Tags
  defdelegate sync_article_tags(article), to: Tags

  def articles_by_tag(tag, opts \\ []),
    do: Tags.articles_by_tag(tag, opts)

  def search_tags(prefix, opts \\ []),
    do: Tags.search_tags(prefix, opts)

  # --- Search ---

  defdelegate search_boards(query, user), to: Search

  def search_visible_boards(query_string, opts \\ []),
    do: Search.search_visible_boards(query_string, opts)

  def search_articles(query_string, opts \\ []),
    do: Search.search_articles(query_string, opts)

  def search_comments(query_string, opts \\ []),
    do: Search.search_comments(query_string, opts)

  # --- Feed Queries ---

  def list_recent_public_articles(limit \\ 20),
    do: Feed.list_recent_public_articles(limit)

  def list_recent_articles_for_public_board(board, limit \\ 20),
    do: Feed.list_recent_articles_for_public_board(board, limit)

  def list_recent_public_articles_by_user(user_id, limit \\ 20),
    do: Feed.list_recent_public_articles_by_user(user_id, limit)

  def list_recent_articles_by_user(user_id, limit \\ 10),
    do: Feed.list_recent_articles_by_user(user_id, limit)

  defdelegate count_user_content_stats(user_id), to: Feed
  defdelegate count_articles_by_user(user_id), to: Feed
  defdelegate count_comments_by_user(user_id), to: Feed

  def paginate_articles_by_user(user_id, opts \\ []),
    do: Feed.paginate_articles_by_user(user_id, opts)

  def paginate_comments_by_user(user_id, opts \\ []),
    do: Feed.paginate_comments_by_user(user_id, opts)

  # --- Read Tracking ---

  defdelegate mark_article_read(user_id, article_id), to: ReadTracking
  defdelegate mark_board_read(user_id, board_id), to: ReadTracking
  defdelegate unread_article_ids(user, article_ids, board_id), to: ReadTracking
  defdelegate unread_board_ids(user, board_ids), to: ReadTracking

  # --- Polls ---

  defdelegate get_poll_for_article(article_id), to: Polls
  defdelegate preload_poll_options(poll), to: Polls
  defdelegate get_user_poll_votes(poll_id, user_id), to: Polls
  defdelegate cast_vote(poll, user, option_ids), to: Polls
  defdelegate create_remote_poll_vote(attrs), to: Polls
  defdelegate update_remote_poll_counts(poll, data), to: Polls
  defdelegate recalc_poll_counts(poll_id), to: Polls

  # --- Federation Hooks ---

  defdelegate schedule_federation_task(fun), to: Baudrate.Federation
end
