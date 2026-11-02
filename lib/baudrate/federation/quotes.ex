defmodule Baudrate.Federation.Quotes do
  @moduledoc """
  Quote posts of local articles (FEP-044f, ADR 0082).

  Mastodon (4.5 and later) and other servers quote a post only when its
  object says who may quote it, and only after its author's server approves
  each quote. Three parts:

    1. **The policy.** A quotable article carries `interactionPolicy.canQuote`
       with `automaticApproval: [as:Public]` (`policy/0`). An object without
       one is read as "nobody may quote".
    2. **The answer.** A quote arrives as a `QuoteRequest` to the author's
       inbox: `object` is our article, `instrument` the quoting post.
       `authorize/4` stores a stamp and sends `Accept` with `result` naming
       it, in one transaction (ADR 0034). The Accept is signed by the
       article's author, because the quoting server accepts it only from the
       quoted post's author.
    3. **The stamp.** A `QuoteAuthorization` at
       `/ap/quote_authorizations/:id` (a path, ADR 0050). Third servers fetch
       it to check the quote; it is served only while the article is still
       quotable (`servable/1`), so withdrawing an article or its board's
       federation withdraws every stamp with it.

  The gate is the outbound one (`Delivery.article_boards_federated?/1`,
  ADR 0043): an article that may not leave cannot be quoted, and its object
  carries no policy.
  """

  import Ecto.Query

  alias Baudrate.Content.Article
  alias Baudrate.Federation
  alias Baudrate.Federation.{Context, Delivery, DomainBlocks, QuoteAuthorization, Validator}
  alias Baudrate.Repo

  @as_public "https://www.w3.org/ns/activitystreams#Public"
  @max_bigint 9_223_372_036_854_775_807

  @doc """
  The `interactionPolicy` a quotable article carries: anyone may quote it,
  and approval is automatic.
  """
  @spec policy() :: map()
  def policy, do: %{"canQuote" => %{"automaticApproval" => [@as_public]}}

  @doc """
  Whether remote posts may quote this article: a local, undeleted article
  that may federate, by an author who has not deleted their account.
  """
  @spec quotable?(Article.t() | term()) :: boolean()
  def quotable?(%Article{remote_actor_id: nil, deleted_at: nil} = article) do
    article = Repo.preload(article, [:boards, :user])

    Delivery.article_boards_federated?(article) and
      match?(%{status: status} when status != "deleted", article.user)
  end

  def quotable?(_), do: false

  @doc """
  Checks that `instrument_uri` can be the quoting post of a `QuoteRequest`
  signed by `remote_actor`: an https URI on the signer's own host (ADR 0046).
  A server may ask approval only for its own posts.
  """
  @spec valid_instrument?(term(), %{ap_id: String.t()}) :: boolean()
  def valid_instrument?(instrument_uri, remote_actor) when is_binary(instrument_uri) do
    String.starts_with?(instrument_uri, "https://") and
      Validator.validate_object_origin(%{"id" => instrument_uri}, remote_actor) == :ok
  end

  def valid_instrument?(_, _), do: false

  @doc """
  Approves a quote: stores the stamp and enqueues the `Accept`, in one
  transaction. A repeated request for the same quoting post reuses its stamp,
  so the stamp's URI never changes under a quote that already cites it.

  The caller has already decided the article is `quotable?/1` and the
  instrument `valid_instrument?/2`.
  """
  @spec authorize(Article.t(), map(), String.t(), map()) ::
          {:ok, QuoteAuthorization.t()} | {:error, term()}
  def authorize(%Article{} = article, request, instrument_uri, remote_actor) do
    article = Repo.preload(article, :user)
    author_uri = Federation.actor_uri(:user, article.user.username)

    Federation.federate(
      fn -> upsert_stamp(article, request, instrument_uri, remote_actor) end,
      fn stamp ->
        Delivery.enqueue(accept(request, author_uri, stamp), author_uri, [remote_actor.inbox])
      end
    )
  end

  @doc """
  Refuses a quote with `Reject(QuoteRequest)`, so the quoting server stops
  waiting. Signed by the article's author.
  """
  @spec refuse(Article.t(), map(), map()) :: :ok
  def refuse(%Article{} = article, request, remote_actor) do
    article = Repo.preload(article, :user)
    author_uri = Federation.actor_uri(:user, article.user.username)

    # Nothing is stored, so there is no change to commit it with; one enqueue
    # is one statement, as for `Reject(Follow)`.
    Delivery.enqueue_reject(embedded(request), author_uri, remote_actor)
    :ok
  end

  defp upsert_stamp(article, request, instrument_uri, remote_actor) do
    attrs = %{
      article_id: article.id,
      remote_actor_id: remote_actor.id,
      interacting_object_ap_id: instrument_uri,
      request_ap_id: request["id"]
    }

    %QuoteAuthorization{}
    |> QuoteAuthorization.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:remote_actor_id, :request_ap_id, :updated_at]},
      conflict_target: [:article_id, :interacting_object_ap_id],
      returning: true
    )
  end

  defp accept(request, author_uri, stamp) do
    %{
      "@context" => Context.activity(),
      "id" => "#{author_uri}#accepts/quote_requests/#{Ecto.UUID.generate()}",
      "type" => "Accept",
      "actor" => author_uri,
      "to" => [request["actor"]],
      "object" => embedded(request),
      "result" => stamp_uri(stamp)
    }
  end

  # The request travels inside our activity, under our context.
  defp embedded(request), do: Map.delete(request, "@context")

  @doc "The stamp's URI: `/ap/quote_authorizations/:id`."
  @spec stamp_uri(QuoteAuthorization.t()) :: String.t()
  def stamp_uri(%QuoteAuthorization{id: id}), do: Federation.actor_uri(:quote_authorization, id)

  @doc """
  The stamp with this id, if it may be served: its article is still
  `quotable?/1` and the quoting actor is not hidden by a domain block or a
  suspension (ADR 0030). `nil` otherwise.
  """
  @spec servable(term()) :: QuoteAuthorization.t() | nil
  def servable(id) when is_integer(id) and id > 0 and id <= @max_bigint do
    with %QuoteAuthorization{} = stamp <-
           Repo.get(QuoteAuthorization, id) |> Repo.preload(article: [:boards, :user]),
         true <- quotable?(stamp.article),
         false <- DomainBlocks.actor_hidden?(stamp.remote_actor_id) do
      stamp
    else
      _ -> nil
    end
  end

  # An id from the URL that no bigint column can hold would raise in the
  # query: it answers 404 like any other unknown stamp.
  def servable(_id), do: nil

  @doc """
  The `QuoteAuthorization` object for a stamp. Its three references must
  equal what the quoting server already holds: the quoting post, our
  article's id and its author (Mastodon checks all three).
  """
  @spec stamp_object(QuoteAuthorization.t()) :: map()
  def stamp_object(%QuoteAuthorization{} = stamp) do
    %{article: article} = stamp = Repo.preload(stamp, article: :user)

    %{
      "@context" => Context.object(),
      "id" => stamp_uri(stamp),
      "type" => "QuoteAuthorization",
      "attributedTo" => Federation.actor_uri(:user, article.user.username),
      "interactingObject" => stamp.interacting_object_ap_id,
      "interactionTarget" => article.ap_id || Federation.actor_uri(:article, article.slug)
    }
  end

  @doc """
  Drops the stamps for a quoting post its own server deleted. Only a signer on
  the post's host may (ADR 0046). Returns the number removed.
  """
  @spec revoke_for_object(String.t(), %{ap_id: String.t()}) :: non_neg_integer()
  def revoke_for_object(object_uri, remote_actor) when is_binary(object_uri) do
    if Validator.same_host?(object_uri, remote_actor.ap_id) do
      {count, _} =
        Repo.delete_all(
          from(q in QuoteAuthorization, where: q.interacting_object_ap_id == ^object_uri)
        )

      count
    else
      0
    end
  end
end
