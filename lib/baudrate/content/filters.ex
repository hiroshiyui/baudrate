defmodule Baudrate.Content.Filters do
  @moduledoc """
  Shared query helpers for content filtering.

  Provides block/mute filters, role-based view permission helpers,
  LIKE sanitization, and CJK detection used across Content sub-modules.
  """

  import Ecto.Query
  alias Baudrate.{Auth, Repo, Setup}

  @doc """
  Returns `{hidden_user_ids, hidden_ap_ids}` for the given user's
  block/mute lists. Returns `{[], []}` for guests.
  """
  def hidden_filters(nil), do: {[], []}
  def hidden_filters(current_user), do: Auth.hidden_ids(current_user)

  @doc """
  Applies block/mute filters to a comment-like query that has
  `user_id` and `remote_actor` associations.
  """
  def apply_hidden_filters(query, [], []), do: query

  def apply_hidden_filters(query, blocked_uids, blocked_ap_ids) do
    query =
      if blocked_uids != [] do
        from(c in query, where: is_nil(c.user_id) or c.user_id not in ^blocked_uids)
      else
        query
      end

    if blocked_ap_ids != [] do
      from(c in query,
        left_join: ra in assoc(c, :remote_actor),
        where: is_nil(c.remote_actor_id) or ra.ap_id not in ^blocked_ap_ids
      )
    else
      query
    end
  end

  @doc """
  Applies hidden filters to article queries with SysOp board exemption.
  """
  def apply_article_hidden_filters(query, nil, _board), do: query

  def apply_article_hidden_filters(query, current_user, board) do
    {hidden_uids, hidden_ap_ids} = hidden_filters(current_user)

    if hidden_uids == [] and hidden_ap_ids == [] do
      query
    else
      is_sysop = board.slug == "sysop"
      apply_article_user_filters(query, hidden_uids, hidden_ap_ids, is_sysop)
    end
  end

  defp apply_article_user_filters(query, hidden_uids, hidden_ap_ids, is_sysop) do
    alias Baudrate.Setup.User, as: SetupUser
    alias Baudrate.Setup.Role

    query =
      if hidden_uids != [] do
        if is_sysop do
          # In SysOp board: exempt admin-role users from hiding
          from(a in query,
            left_join: u in SetupUser,
            on: u.id == a.user_id,
            left_join: r in Role,
            on: r.id == u.role_id,
            where:
              is_nil(a.user_id) or
                a.user_id not in ^hidden_uids or
                r.name == "admin"
          )
        else
          from(a in query, where: is_nil(a.user_id) or a.user_id not in ^hidden_uids)
        end
      else
        query
      end

    if hidden_ap_ids != [] do
      from(a in query,
        left_join: ra in assoc(a, :remote_actor),
        as: :article_ra,
        where: is_nil(a.remote_actor_id) or ra.ap_id not in ^hidden_ap_ids
      )
    else
      query
    end
  end

  @doc """
  Excludes remote rows whose `visibility` is not `public` or `unlisted`.

  Applies to any query whose first binding has `remote_actor_id` and
  `visibility` — articles and comments both qualify. Local rows are never
  affected: their changesets only ever accept `public` or `unlisted`.

  Ingest deliberately keeps whatever addressing a peer sent (a mis-addressed
  object loses visibility here rather than being dropped), so this is the only
  thing standing between a `followers_only` or `direct` remote object and a
  public listing. It is unconditional: the row-level gate
  (`ArticleHelpers.user_can_view_article?/2`) refuses these to everyone
  including admins, so there is no viewer for whom listing them is correct.
  """
  def exclude_remote_nonpublic(query) do
    from(x in query,
      where: is_nil(x.remote_actor_id) or x.visibility in ["public", "unlisted"]
    )
  end

  @doc """
  Returns the role names that the given user is allowed to view.
  """
  def allowed_view_roles(nil), do: ["guest"]

  def allowed_view_roles(%{role: %{name: role_name}}) do
    Setup.roles_at_or_below(role_name)
  end

  @doc """
  Escapes LIKE special characters in user input.
  """
  def sanitize_like(str), do: Repo.sanitize_like(str)

  @doc """
  Returns true if the string contains CJK characters.
  """
  def contains_cjk?(str) do
    String.match?(str, ~r/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/u)
  end
end
