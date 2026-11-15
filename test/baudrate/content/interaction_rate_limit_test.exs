defmodule Baudrate.Content.InteractionRateLimitTest do
  @moduledoc """
  Adding a like, a boost or a poll vote takes a place in one per-member
  bucket (`RateLimits.check_interaction/1`), checked in the context.

  Each one commits a signed activity with a fresh id to every follower inbox
  and the remote author's server, so toggling on and off in a loop had this
  instance send a third party unbounded signed traffic. Undoing stays open
  (ADR 0029): a member must always be able to take back a like.
  """

  use Baudrate.DataCase, async: true

  alias Baudrate.Content
  alias Baudrate.Federation
  alias Baudrate.Federation.{KeyStore, RemoteActor}
  alias BaudrateWeb.RateLimiter.Sandbox

  import BaudrateWeb.ConnCase, only: [setup_user: 1]

  setup do
    author = setup_user("user")
    member = setup_user("user")
    {:ok, author: author, member: member}
  end

  # Denies the interaction bucket only, so every other limit keeps answering
  # as in any other test.
  defp deny_interactions do
    Sandbox.set_fun(fn
      "interaction:" <> _, _scale, limit -> {:deny, limit}
      _bucket, _scale, _limit -> {:allow, 1}
    end)
  end

  defp create_article(user, opts \\ []) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          "title" => "Rate limit",
          "body" => "Body",
          "slug" => "interaction-limit-#{System.unique_integer([:positive])}",
          "user_id" => user.id
        },
        [],
        opts
      )

    article
  end

  defp create_comment(user, article) do
    {:ok, comment} =
      Content.create_comment(%{
        "body" => "A comment",
        "article_id" => article.id,
        "user_id" => user.id
      })

    comment
  end

  # A timeline item is reachable only through an accepted follow of its
  # source (`Federation.timeline_item_accessible?/2`).
  defp create_timeline_item(member) do
    uid = System.unique_integer([:positive])

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/actor-#{uid}",
        username: "actor_#{uid}",
        domain: "remote.example",
        public_key_pem: elem(KeyStore.generate_keypair(), 0),
        inbox: "https://remote.example/users/actor-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {:ok, _follow} =
      %Federation.UserFollow{}
      |> Federation.UserFollow.changeset(%{
        user_id: member.id,
        remote_actor_id: actor.id,
        state: "accepted",
        ap_id: "https://local.example/follows/#{uid}",
        accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {:ok, item} =
      Federation.create_timeline_item(%{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/#{uid}",
        body: "Hello",
        body_html: "<p>Hello</p>",
        source_url: "https://remote.example/notes/#{uid}",
        visibility: "public",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    item
  end

  test "a new article like or boost is refused once the bucket is spent", %{
    author: author,
    member: member
  } do
    article = create_article(author)
    deny_interactions()

    assert {:error, :rate_limited} = Content.toggle_article_like(member.id, article.id)
    assert {:error, :rate_limited} = Content.toggle_article_boost(member.id, article.id)
    refute Content.article_liked?(member.id, article.id)
    refute Content.article_boosted?(member.id, article.id)
  end

  test "a new comment like or boost is refused once the bucket is spent", %{
    author: author,
    member: member
  } do
    comment = author |> create_article() |> then(&create_comment(author, &1))
    deny_interactions()

    assert {:error, :rate_limited} = Content.toggle_comment_like(member.id, comment.id)
    assert {:error, :rate_limited} = Content.toggle_comment_boost(member.id, comment.id)
  end

  test "undoing a like or a boost is never limited", %{author: author, member: member} do
    article = create_article(author)
    {:ok, _} = Content.toggle_article_like(member.id, article.id)
    {:ok, _} = Content.toggle_article_boost(member.id, article.id)
    deny_interactions()

    assert {:ok, :removed} = Content.toggle_article_like(member.id, article.id)
    assert {:ok, :removed} = Content.toggle_article_boost(member.id, article.id)
  end

  test "a timeline like or boost is refused once the bucket is spent", %{member: member} do
    item = create_timeline_item(member)
    deny_interactions()

    assert {:error, :rate_limited} = Federation.toggle_timeline_item_like(member, item.id)
    assert {:error, :rate_limited} = Federation.toggle_timeline_item_boost(member, item.id)
  end

  test "a poll vote is refused once the bucket is spent", %{author: author, member: member} do
    article =
      create_article(author,
        poll: %{
          mode: "single",
          options: [%{text: "A", position: 0}, %{text: "B", position: 1}]
        }
      )

    poll = article.id |> Content.get_poll_for_article() |> Content.preload_poll_options()
    [option | _] = poll.options
    deny_interactions()

    assert {:error, :rate_limited} = Content.cast_vote(poll, member, [option.id])
  end
end
