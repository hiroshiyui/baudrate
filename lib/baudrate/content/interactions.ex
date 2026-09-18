defmodule Baudrate.Content.Interactions do
  @moduledoc """
  Shared helpers for content interaction modules (likes and boosts).

  Provides article visibility checks, AP ID stamping, unique constraint
  detection, and federation task scheduling used by both `Likes` and `Boosts`.
  """

  import Ecto.Query
  alias Baudrate.Repo

  @doc """
  Returns true if the user may reach this article at all.

  The one definition of "may this account touch this article", used by every
  interaction that resolves an article from a client-supplied id — like, boost,
  bookmark, and both forward paths — and by
  `BaudrateWeb.ArticleHelpers.user_can_view_article?/2`, which renders the page
  and now delegates here.

  Three refusals, in order:

    * **A remote row that was never public.** A remote article ingested as
      `followers_only` or `direct` keeps that visibility (ADR 0030 deliberately
      loses visibility rather than data), and it is refused to **everyone,
      including admins** — re-publishing someone else's followers-only post is
      not a trust question.
    * **A remote author whose domain is blocked or who is suspended.** Hiding a
      domain from listings while its content stays interactable would be no
      block at all.
    * **Board visibility**, by the viewer's role level. An article with no
      boards (a quick post) passes.

  It used to check only the third, with its own hand-written copy of the role
  hierarchy, while the page-rendering helper in the web layer checked all
  three. So a followers-only remote article in a guest-readable board was
  refused by `/articles/:slug` and accepted by like, boost, bookmark and
  forward — and an admin could forward it into a public board, which
  re-publishes it to the fediverse. Keeping the definition here rather than in
  the web layer is what ADR 0016 asks for: the context decides, and the
  LiveView asks the context.
  """
  @spec article_visible_to_user?(integer(), integer() | nil) :: boolean()
  def article_visible_to_user?(article_id, user_id) do
    case Repo.get(Baudrate.Content.Article, article_id) do
      # An id that resolves to nothing used to count as visible: the board
      # count came back 0, which is also how a legitimate quick post looks.
      nil -> false
      article -> remote_servable?(article) and boards_visible_to?(article_id, user_id)
    end
  end

  @doc """
  Whether a remote article may be shown or touched here at all, ignoring
  boards: `false` for a row ingested as `followers_only`/`direct`, and `false`
  when its author's domain is blocked or the actor is suspended. Always `true`
  for local articles.

  The one definition of the two remote refusals. `BaudrateWeb.ArticleHelpers`
  calls this and then applies its own board check against already-preloaded
  boards, so rendering the article page costs no extra query; the interaction
  paths here have only an id, so they query.
  """
  @spec remote_servable?(map()) :: boolean()
  def remote_servable?(article) do
    not remote_nonpublic?(article) and not remote_author_hidden?(article)
  end

  # A remote row addressed to followers or to one person is not a public page.
  defp remote_nonpublic?(%{remote_actor_id: rid, visibility: vis})
       when not is_nil(rid) and vis not in ["public", "unlisted"],
       do: true

  defp remote_nonpublic?(_article), do: false

  # Prefers a preloaded actor; falls back to the id, so a caller that did not
  # preload gets the right answer rather than a permissive one.
  defp remote_author_hidden?(%{remote_actor: %Baudrate.Federation.RemoteActor{} = actor}),
    do: Baudrate.Federation.DomainBlocks.actor_hidden?(actor)

  defp remote_author_hidden?(%{remote_actor_id: rid}) when not is_nil(rid),
    do: Baudrate.Federation.DomainBlocks.actor_hidden?(rid)

  defp remote_author_hidden?(_article), do: false

  defp boards_visible_to?(article_id, user_id) do
    user = user_id && Repo.get(Baudrate.Setup.User, user_id)
    user = user && Repo.preload(user, :role)
    role_name = if user, do: user.role.name, else: "guest"

    board_count =
      from(ba in Baudrate.Content.BoardArticle,
        where: ba.article_id == ^article_id,
        select: count()
      )
      |> Repo.one()

    # Board-less articles (quick posts) are visible to all authenticated users.
    if board_count == 0 do
      true
    else
      # `Setup.roles_at_or_below/1`, not a local copy: the role hierarchy was
      # written out by hand here, a third time after `@role_levels` and
      # `roles_at_or_below/1`, so a change to the ordering would have had to be
      # made in three places to take effect everywhere.
      Repo.exists?(
        from(ba in Baudrate.Content.BoardArticle,
          join: b in Baudrate.Content.Board,
          on: b.id == ba.board_id,
          where:
            ba.article_id == ^article_id and
              b.min_role_to_view in ^Baudrate.Setup.roles_at_or_below(role_name)
        )
      )
    end
  end

  @doc """
  Returns true if a changeset has a unique constraint error.
  Used for TOCTOU race condition handling in toggle operations.
  """
  def has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_msg, meta}} -> Keyword.get(meta, :constraint) == :unique
      _ -> false
    end)
  end

  @doc """
  Stamps an AP ID on a newly created interaction record.

  The `fragment` parameter is the AP ID type suffix (e.g., `"like"`, `"announce"`,
  `"comment-like"`, `"comment-announce"`).

  Only stamps records where `ap_id` is nil and `user_id` is an integer.
  Returns the record unchanged if already stamped or if it's a remote interaction.
  """
  def stamp_ap_id(%{ap_id: nil, user_id: user_id} = record, fragment)
      when is_integer(user_id) do
    case Repo.get(Baudrate.Setup.User, user_id) do
      nil ->
        record

      user ->
        ap_id =
          Baudrate.Federation.actor_uri(:user, user.username) <> "##{fragment}-#{record.id}"

        record
        |> Ecto.Changeset.change(ap_id: ap_id)
        |> Repo.update!()
    end
  end

  def stamp_ap_id(record, _fragment), do: record
end
