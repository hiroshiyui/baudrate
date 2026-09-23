defmodule Baudrate.Messaging.Search do
  @moduledoc """
  A member searching their own conversations (6D, ADR 0071).

  Deliberately **not** part of `Baudrate.Content.Search`: that module also
  backs the unauthenticated `/ap/search`, and a private message must not be
  one mistaken option away from a public endpoint. Here every query is
  scoped to the conversations the member takes part in, in the query itself.

  Matching is a case-insensitive substring (`ILIKE`, escaped through
  `Repo.sanitize_like/1`) served by the trigram index on
  `direct_messages.body`, so it works the same for CJK text as for English.
  Soft-deleted messages, and messages from anyone the member has blocked or
  muted, are left out. Newest first, with an `id` tiebreaker.
  """

  import Ecto.Query

  alias Baudrate.Auth
  alias Baudrate.Messaging.{Conversation, DirectMessage}
  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @per_page 20
  @min_length 2

  @doc "The shortest query, in characters after trimming, that is searched."
  def min_length, do: @min_length

  @doc """
  Searches `user`'s conversations for `query`.

  Returns `%{messages: [...], total:, page:, per_page:, total_pages:}` with
  each message's conversation and sender preloaded; a query shorter than
  #{@min_length} characters returns no messages.
  """
  def search_messages(%User{} = user, query, opts \\ []) do
    term = String.trim(query || "")
    pagination = Baudrate.Pagination.paginate_opts(opts, @per_page, max_per_page: @per_page)

    if String.length(term) < @min_length do
      {page, per_page, _} = pagination
      %{messages: [], total: 0, page: page, per_page: per_page, total_pages: 1}
    else
      user
      |> base_query(term)
      |> Baudrate.Pagination.paginate_query(pagination,
        result_key: :messages,
        order_by: [desc: dynamic([dm], dm.inserted_at), desc: dynamic([dm], dm.id)],
        preloads: [
          :sender_user,
          :sender_remote_actor,
          conversation: [:user_a, :user_b, :remote_actor_b]
        ]
      )
    end
  end

  defp base_query(%User{id: user_id} = user, term) do
    pattern = "%" <> Repo.sanitize_like(term) <> "%"
    {hidden_user_ids, hidden_ap_ids} = Auth.hidden_ids(user)

    from(dm in DirectMessage,
      join: c in Conversation,
      on: c.id == dm.conversation_id,
      left_join: ra in assoc(dm, :sender_remote_actor),
      where: c.user_a_id == ^user_id or c.user_b_id == ^user_id,
      where: is_nil(dm.deleted_at),
      where: ilike(dm.body, ^pattern),
      where: is_nil(dm.sender_user_id) or dm.sender_user_id not in ^hidden_user_ids,
      where: is_nil(ra.id) or ra.ap_id not in ^hidden_ap_ids
    )
  end
end
