defmodule Baudrate.Auth.BlockEnforcementTest do
  @moduledoc """
  A block is enforced at the context boundary: it removes follows in both
  directions and refuses new interactions between the two accounts, whoever
  blocked whom. Undoing an earlier like or boost stays allowed, and content
  stays readable (a block controls interaction, not visibility).
  """

  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.{Auth, Content, Federation, Messaging, Repo, Setup}
  alias Baudrate.Federation.{DeliveryJob, Follower, KeyStore, RemoteActor}

  setup do
    Setup.seed_roles_and_permissions()
    author = create_user()
    other = create_user()

    board =
      %Content.Board{}
      |> Content.Board.changeset(%{
        name: "Blk",
        slug: "blk-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Post",
          body: "Body",
          slug: "blk-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        [board.id]
      )

    %{author: author, other: other, board: board, article: article}
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "blk_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/blk-#{uid}",
      username: "blk_actor_#{uid}",
      domain: "remote.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://remote.example/users/blk-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  describe "local user blocks" do
    test "blocking removes follows in both directions", %{author: author, other: other} do
      {:ok, _} = Federation.create_local_follow(author, other)
      {:ok, _} = Federation.create_local_follow(other, author)

      {:ok, _} = Auth.block_user(author, other)

      refute Federation.local_follows?(author.id, other.id)
      refute Federation.local_follows?(other.id, author.id)
    end

    test "neither side can follow the other", %{author: author, other: other} do
      {:ok, _} = Auth.block_user(author, other)

      assert {:error, :blocked} = Federation.create_local_follow(other, author)
      assert {:error, :blocked} = Federation.create_local_follow(author, other)
    end

    test "the blocked user cannot comment on or reply to the blocker",
         %{author: author, other: other, article: article} do
      bystander = create_user()

      {:ok, _} = Auth.block_user(author, other)

      assert {:error, :blocked} =
               Content.create_comment(%{body: "Hi", article_id: article.id, user_id: other.id})

      {:ok, %{article: bystander_article}} =
        Content.create_article(
          %{
            title: "Elsewhere",
            body: "Body",
            slug: "blk-#{System.unique_integer([:positive])}",
            user_id: bystander.id
          },
          []
        )

      {:ok, author_comment} =
        Content.create_comment(%{
          body: "On a third article",
          article_id: bystander_article.id,
          user_id: author.id
        })

      assert {:error, :blocked} =
               Content.create_comment(%{
                 body: "Reply",
                 article_id: bystander_article.id,
                 parent_id: author_comment.id,
                 user_id: other.id
               })

      # Commenting on someone else's content still works.
      assert {:ok, _} =
               Content.create_comment(%{
                 body: "Fine",
                 article_id: bystander_article.id,
                 user_id: other.id
               })

      # The block applies in both directions.
      {:ok, %{article: other_article}} =
        Content.create_article(
          %{
            title: "Theirs",
            body: "Body",
            slug: "blk-#{System.unique_integer([:positive])}",
            user_id: other.id
          },
          []
        )

      assert {:error, :blocked} =
               Content.create_comment(%{
                 body: "Hi",
                 article_id: other_article.id,
                 user_id: author.id
               })
    end

    test "the blocked user cannot like or boost, but can undo an earlier like",
         %{author: author, other: other, article: article} do
      {:ok, comment} =
        Content.create_comment(%{body: "Mine", article_id: article.id, user_id: author.id})

      {:ok, _like} = Content.toggle_article_like(other.id, article.id)
      {:ok, _} = Auth.block_user(author, other)

      assert {:error, :blocked} = Content.toggle_article_boost(other.id, article.id)
      assert {:error, :blocked} = Content.toggle_comment_like(other.id, comment.id)
      assert {:error, :blocked} = Content.toggle_comment_boost(other.id, comment.id)

      assert {:ok, :removed} = Content.toggle_article_like(other.id, article.id)
      assert {:error, :blocked} = Content.toggle_article_like(other.id, article.id)
    end

    test "the blocked user cannot forward the blocker's content",
         %{author: author, other: other, article: article} do
      {:ok, comment} =
        Content.create_comment(%{body: "Mine", article_id: article.id, user_id: author.id})

      target =
        %Content.Board{}
        |> Content.Board.changeset(%{
          name: "Blk2",
          slug: "blk2-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, _} = Auth.block_user(author, other)

      assert {:error, :unauthorized} = Content.forward_article_to_board(article, target, other)
      assert {:error, :unauthorized} = Content.forward_comment_to_board(comment, target, other)
    end

    test "DMs are refused both ways", %{author: author, other: other} do
      {:ok, _} = Auth.block_user(author, other)

      refute Messaging.can_send_dm?(other, author)
      refute Messaging.can_send_dm?(author, other)
    end

    test "unblocking restores interaction", %{author: author, other: other, article: article} do
      {:ok, _} = Auth.block_user(author, other)
      Auth.unblock_user(author, other)

      assert {:ok, _} = Content.toggle_article_like(other.id, article.id)
      assert {:ok, _} = Federation.create_local_follow(other, author)
    end
  end

  describe "remote actor blocks" do
    setup %{author: author} do
      {:ok, author} = KeyStore.ensure_user_keypair(author)
      %{author: author, actor: create_remote_actor()}
    end

    test "blocking undoes the user's follow and rejects the actor's follow",
         %{author: author, actor: actor} do
      {:ok, follow} = Federation.create_user_follow(author, actor)
      {:ok, _} = Federation.accept_user_follow(follow.ap_id)

      author_uri = Federation.actor_uri(:user, author.username)

      {:ok, _} =
        Federation.create_follower(author_uri, actor, "https://remote.example/follows/1")

      {:ok, _} = Auth.block_remote_actor(author, actor.ap_id)

      refute Federation.user_follows?(author.id, actor.id)
      refute Repo.exists?(from(f in Follower, where: f.remote_actor_id == ^actor.id))

      activities =
        from(j in DeliveryJob, where: j.inbox_url == ^actor.inbox, select: j.activity_json)
        |> Repo.all()
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(
               activities,
               &match?(%{"type" => "Undo", "object" => %{"type" => "Follow"}}, &1)
             )

      assert Enum.any?(
               activities,
               &match?(
                 %{
                   "type" => "Reject",
                   "object" => %{"id" => "https://remote.example/follows/1", "type" => "Follow"}
                 },
                 &1
               )
             )

      refute Enum.any?(activities, &(&1["type"] == "Block"))
    end

    test "blocking an unknown actor only records the block", %{author: author} do
      assert {:ok, _} = Auth.block_remote_actor(author, "https://unknown.example/users/x")
      assert Auth.blocked?(author, "https://unknown.example/users/x")
    end

    test "the user cannot follow, like, boost or reply to the blocked actor",
         %{author: author, actor: actor} do
      {:ok, follow} = Federation.create_user_follow(author, actor)
      {:ok, _} = Federation.accept_user_follow(follow.ap_id)
      uid = System.unique_integer([:positive])

      {:ok, item} =
        Federation.create_timeline_item(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/#{uid}",
          body: "Hello",
          body_html: "<p>Hello</p>",
          source_url: "https://remote.example/notes/#{uid}",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _} = Federation.toggle_timeline_item_like(author, item.id)

      Repo.insert!(%Baudrate.Auth.UserBlock{user_id: author.id, blocked_actor_ap_id: actor.ap_id})

      assert {:error, :blocked} = Federation.toggle_timeline_item_boost(author, item.id)
      assert {:error, :blocked} = Federation.create_timeline_item_reply(item, author, "Hi")
      assert {:ok, :removed} = Federation.toggle_timeline_item_like(author, item.id)
      assert {:error, :blocked} = Federation.toggle_timeline_item_like(author, item.id)

      Federation.delete_user_follow(author, actor)
      assert {:error, :blocked} = Federation.create_user_follow(author, actor)
    end

    test "the user cannot comment under the blocked actor's comment",
         %{author: author, actor: actor, article: article} do
      {:ok, remote_comment} =
        Content.create_remote_comment(%{
          body: "Remote",
          body_html: "<p>Remote</p>",
          ap_id: "https://remote.example/notes/c-#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: actor.id
        })

      {:ok, _} = Auth.block_remote_actor(author, actor.ap_id)

      assert {:error, :blocked} =
               Content.create_comment(%{
                 body: "Reply",
                 article_id: article.id,
                 parent_id: remote_comment.id,
                 user_id: author.id
               })

      assert {:error, :blocked} = Content.toggle_comment_like(author.id, remote_comment.id)
    end
  end
end
