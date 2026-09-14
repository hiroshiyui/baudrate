defmodule Baudrate.Federation.InboxHandlerBlockTest do
  @moduledoc """
  A local user's block of a remote actor refuses that actor's follows, likes,
  boosts and replies on the user's content. Refused activities return `:ok`
  so the remote server does not retry. Other users' content is unaffected.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.{Auth, Content, Federation, Setup}
  alias Baudrate.Federation.{InboxHandler, KeyStore, RemoteActor}

  setup do
    Setup.seed_roles_and_permissions()

    Req.Test.stub(Baudrate.Federation.HTTPClient, fn conn ->
      Plug.Conn.send_resp(conn, 202, "Accepted")
    end)

    blocker = create_user()
    bystander = create_user()
    actor = create_remote_actor()
    {:ok, _} = Auth.block_remote_actor(blocker, actor.ap_id)

    board =
      %Content.Board{}
      |> Content.Board.changeset(%{
        name: "Blk",
        slug: "blk-#{System.unique_integer([:positive])}",
        ap_accept_policy: "open"
      })
      |> Repo.insert!()

    %{
      blocker: blocker,
      bystander: bystander,
      actor: actor,
      article: create_article(blocker, board),
      bystander_article: create_article(bystander, board)
    }
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "ibk_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(Repo.preload(user, :role))
    user
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/ibk-#{uid}",
      username: "ibk_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/ibk-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp create_article(user, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Article",
          body: "Body",
          slug: "ibk-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  defp uid, do: System.unique_integer([:positive])

  defp follow(actor, target_uri) do
    %{
      "id" => "https://remote.example/follows/#{uid()}",
      "type" => "Follow",
      "actor" => actor.ap_id,
      "object" => target_uri
    }
  end

  defp like(actor, object_uri) do
    %{
      "id" => "https://remote.example/likes/#{uid()}",
      "type" => "Like",
      "actor" => actor.ap_id,
      "object" => object_uri
    }
  end

  defp reply(actor, in_reply_to) do
    %{
      "id" => "https://remote.example/activities/create-#{uid()}",
      "type" => "Create",
      "actor" => actor.ap_id,
      "object" => %{
        "id" => "https://remote.example/notes/#{uid()}",
        "type" => "Note",
        "content" => "<p>Reply</p>",
        "attributedTo" => actor.ap_id,
        "inReplyTo" => in_reply_to,
        "to" => ["https://www.w3.org/ns/activitystreams#Public"]
      }
    }
  end

  test "a follow of the blocker is refused, on both the user and shared inbox",
       %{blocker: blocker, bystander: bystander, actor: actor} do
    blocker_uri = Federation.actor_uri(:user, blocker.username)
    bystander_uri = Federation.actor_uri(:user, bystander.username)

    assert :ok = InboxHandler.handle(follow(actor, blocker_uri), actor, {:user, blocker})
    assert :ok = InboxHandler.handle(follow(actor, blocker_uri), actor, :shared)
    refute Federation.follower_exists?(blocker_uri, actor.ap_id)

    assert :ok = InboxHandler.handle(follow(actor, bystander_uri), actor, :shared)
    assert Federation.follower_exists?(bystander_uri, actor.ap_id)
  end

  test "likes and boosts of the blocker's article are dropped",
       %{article: article, bystander_article: bystander_article, actor: actor} do
    uri = Federation.actor_uri(:article, article.slug)
    assert :ok = InboxHandler.handle(like(actor, uri), actor, :shared)
    assert Content.count_article_likes(article) == 0

    announce = %{like(actor, uri) | "type" => "Announce"}
    assert :ok = InboxHandler.handle(announce, actor, :shared)
    assert Content.count_article_boosts(article) == 0

    other_uri = Federation.actor_uri(:article, bystander_article.slug)
    assert :ok = InboxHandler.handle(like(actor, other_uri), actor, :shared)
    assert Content.count_article_likes(bystander_article) == 1
  end

  test "a like of the blocker's comment is dropped",
       %{blocker: blocker, bystander_article: article, actor: actor} do
    {:ok, comment} =
      Content.create_comment(%{body: "Mine", article_id: article.id, user_id: blocker.id})

    assert :ok = InboxHandler.handle(like(actor, comment.ap_id), actor, :shared)
    assert Content.comment_like_counts([comment.id]) |> Map.get(comment.id, 0) == 0
  end

  test "replies to the blocker's article or comment are dropped",
       %{blocker: blocker, article: article, bystander_article: bystander_article, actor: actor} do
    uri = Federation.actor_uri(:article, article.slug)
    assert :ok = InboxHandler.handle(reply(actor, uri), actor, :shared)
    assert Content.list_comments_for_article(article) == []

    {:ok, comment} =
      Content.create_comment(%{
        body: "Mine",
        article_id: bystander_article.id,
        user_id: blocker.id
      })

    assert :ok = InboxHandler.handle(reply(actor, comment.ap_id), actor, :shared)
    assert [%{id: id}] = Content.list_comments_for_article(bystander_article)
    assert id == comment.id

    bystander_uri = Federation.actor_uri(:article, bystander_article.slug)
    assert :ok = InboxHandler.handle(reply(actor, bystander_uri), actor, :shared)
    assert length(Content.list_comments_for_article(bystander_article)) == 2
  end
end
