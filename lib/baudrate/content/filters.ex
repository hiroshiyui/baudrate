defmodule Baudrate.Content.Filters do
  @moduledoc """
  Shared query helpers for content filtering.

  Provides block/mute filters, role-based view permission helpers,
  LIKE sanitization, and CJK detection used across Content sub-modules.
  """

  import Ecto.Query
  alias Baudrate.{Auth, Repo, Setup}
  alias Baudrate.Federation.{DomainBlock, DomainBlockCache, RemoteActor}

  @doc """
  Returns `{hidden_user_ids, hidden_remote}` for the given user's blocks and
  mutes, or `{[], []}` for a guest.

  `hidden_remote` is `{ap_ids, domains}`: the remote accounts blocked or
  muted one by one, and the servers the member muted as a whole (ADR 0073).
  Callers pass it to `apply_hidden_filters/3` unopened. A domain is filtered
  as a domain — not expanded into every account known there, which for a
  large server would be tens of thousands of ids on every query.
  """
  def hidden_filters(nil), do: {[], []}

  def hidden_filters(current_user) do
    {user_ids, ap_ids} = Auth.hidden_ids(current_user)
    {user_ids, remote_hidden(ap_ids, Auth.muted_domains(current_user))}
  end

  defp remote_hidden(ap_ids, []), do: ap_ids
  defp remote_hidden(ap_ids, domains), do: {ap_ids, domains}

  @doc """
  Applies block/mute filters to a comment-like query that has
  `user_id` and `remote_actor` associations.

  The remote half is a list of AP ids, or `{ap_ids, muted_domains}` from
  `hidden_filters/1`.
  """
  def apply_hidden_filters(query, [], []), do: query

  def apply_hidden_filters(query, blocked_uids, blocked_remote) do
    {blocked_ap_ids, muted_domains} = split_remote(blocked_remote)

    query =
      if blocked_uids != [] do
        from(c in query, where: is_nil(c.user_id) or c.user_id not in ^blocked_uids)
      else
        query
      end

    if blocked_ap_ids != [] or muted_domains != [] do
      from(c in query,
        left_join: ra in assoc(c, :remote_actor),
        where:
          is_nil(c.remote_actor_id) or
            (ra.ap_id not in ^blocked_ap_ids and ra.domain not in ^muted_domains)
      )
    else
      query
    end
  end

  defp split_remote({ap_ids, domains}), do: {ap_ids, domains}
  defp split_remote(ap_ids) when is_list(ap_ids), do: {ap_ids, []}

  @doc """
  Applies hidden filters to article queries with SysOp board exemption.
  """
  def apply_article_hidden_filters(query, nil, _board), do: query

  def apply_article_hidden_filters(query, current_user, board) do
    {hidden_uids, hidden_remote} = hidden_filters(current_user)

    if hidden_uids == [] and hidden_remote == [] do
      query
    else
      is_sysop = board.slug == "sysop"
      apply_article_user_filters(query, hidden_uids, hidden_remote, is_sysop)
    end
  end

  defp apply_article_user_filters(query, hidden_uids, hidden_remote, is_sysop) do
    alias Baudrate.Setup.User, as: SetupUser
    alias Baudrate.Setup.Role

    {hidden_ap_ids, muted_domains} = split_remote(hidden_remote)

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

    if hidden_ap_ids != [] or muted_domains != [] do
      from(a in query,
        left_join: ra in assoc(a, :remote_actor),
        as: :article_ra,
        where:
          is_nil(a.remote_actor_id) or
            (ra.ap_id not in ^hidden_ap_ids and ra.domain not in ^muted_domains)
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
  Excludes every remote row a listing must not show, for either reason:

    * its addressing was not public (`exclude_remote_nonpublic/1`), or
    * its author is hidden by an instance-level block (`exclude_hidden_remote/1`).

  This is the one call a listing query makes. The two reasons are separate
  primitives because a few queries need them against a join binding rather than
  the first one, but a listing that applies only one of them leaks — so the
  default is both together.

  `test/baudrate/content/remote_visibility_test.exs` and
  `test/baudrate/federation/blocked_domain_hiding_test.exs` are the acceptance
  gates. Add every new listing query to both.
  """
  def exclude_unservable_remote(query) do
    query
    |> exclude_remote_nonpublic()
    |> exclude_hidden_remote()
  end

  @doc """
  Excludes rows whose remote author is hidden by an instance-level decision
  (ADR 0030): the actor's domain is blocked under the current federation mode.

  Applies to any query whose first binding has `remote_actor_id`. Use
  `hidden_remote_actor_ids/0` directly where the row is not the first binding,
  or where a second column (a booster) needs the same test.

  Hiding is computed at query time and never stamped on a row, so lifting a
  block makes the content visible again by itself. It is unconditional: an
  instance block is the site's decision about what it serves, so there is no
  viewer for whom the content should still be listed. Staff surfaces that must
  keep showing it (the moderation queue, report details) simply do not call
  this.
  """
  def exclude_hidden_remote(query) do
    from(x in query,
      where: is_nil(x.remote_actor_id) or x.remote_actor_id not in subquery(hidden_actor_ids())
    )
  end

  @doc """
  A query selecting the ids of every remote actor hidden by an instance-level
  decision: its domain is blocked under the current federation mode, **or** the
  actor itself is suspended (ADR 0030, decision 6).

  Both live in one predicate deliberately. They are the same decision at
  different scales, and keeping them in one place is what stops them diverging
  as listings are added.

  In blocklist mode the domain half is a semi-join against `domain_blocks`, so
  the blocked set never travels through the query as a parameter list. In
  allowlist mode the allowed domains are a setting and a small list, so they
  are passed in — an empty allowlist hides every remote actor, matching
  `DomainBlockCache.domain_blocked?/1`.
  """
  def hidden_actor_ids do
    case DomainBlockCache.config() do
      {:blocklist, _blocked} ->
        from(ra in RemoteActor,
          left_join: db in DomainBlock,
          on: db.domain == ra.domain,
          where: not is_nil(db.id) or not is_nil(ra.suspended_at),
          select: ra.id
        )

      {:allowlist, allowed} ->
        allowed = MapSet.to_list(allowed)

        from(ra in RemoteActor,
          where: ra.domain not in ^allowed or not is_nil(ra.suspended_at),
          select: ra.id
        )
    end
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
