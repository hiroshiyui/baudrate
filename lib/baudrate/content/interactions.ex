defmodule Baudrate.Content.Interactions do
  @moduledoc """
  Shared helpers for content interaction modules (likes and boosts).

  Provides article visibility checks, AP ID stamping, unique constraint
  detection, and federation task scheduling used by both `Likes` and `Boosts`.
  """

  import Ecto.Query
  alias Baudrate.Repo

  @doc """
  Returns true if the article is in at least one board the user can view.
  Articles with no board associations (board-less quick posts) are always visible.
  """
  def article_visible_to_user?(article_id, user_id) do
    user = Repo.get(Baudrate.Setup.User, user_id)
    user = user && Repo.preload(user, :role)

    board_count =
      from(ba in Baudrate.Content.BoardArticle,
        where: ba.article_id == ^article_id,
        select: count()
      )
      |> Repo.one()

    # Board-less articles (quick posts) are visible to all authenticated users
    if board_count == 0 do
      true
    else
      role_name = if user, do: user.role.name, else: "guest"

      Repo.exists?(
        from(ba in Baudrate.Content.BoardArticle,
          join: b in Baudrate.Content.Board,
          on: b.id == ba.board_id,
          where:
            ba.article_id == ^article_id and
              b.min_role_to_view in ^accessible_roles(role_name)
        )
      )
    end
  end

  @doc """
  Returns the list of role names accessible to the given role.
  Used for board visibility filtering.
  """
  def accessible_roles("admin"), do: ~w(guest user moderator admin)
  def accessible_roles("moderator"), do: ~w(guest user moderator)
  def accessible_roles("user"), do: ~w(guest user)
  def accessible_roles(_), do: ~w(guest)

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

  @doc """
  Schedules an async federation task.
  Delegates to `Baudrate.Federation.schedule_federation_task/1`.
  """
  def schedule_federation_task(fun) do
    Baudrate.Federation.schedule_federation_task(fun)
  end
end
