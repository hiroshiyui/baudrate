defmodule Baudrate.Federation.PublisherTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Comment
  alias Baudrate.Federation
  alias Baudrate.Federation.{KeyStore, Publisher, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "pub_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Repo.preload(user, :role)
  end

  defp create_board(slug \\ nil) do
    slug = slug || "board-#{System.unique_integer([:positive])}"

    board =
      %Baudrate.Content.Board{}
      |> Baudrate.Content.Board.changeset(%{name: "Test Board", slug: slug})
      |> Repo.insert!()

    {:ok, board} = KeyStore.ensure_board_keypair(board)
    board
  end

  defp create_article(user, board) do
    slug = "art-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Body text", slug: slug, user_id: user.id},
        [board.id]
      )

    Repo.preload(article, [:boards, :user])
  end

  describe "build_create_article/1" do
    test "builds a Create(Article) activity" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, actor_uri} = Publisher.build_create_article(article)

      assert activity["type"] == "Create"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Article"
      assert activity["object"]["name"] == "Test Article"
      assert activity["object"]["attributedTo"] == actor_uri
      assert actor_uri =~ user.username

      assert activity["@context"] == [
               "https://www.w3.org/ns/activitystreams",
               "https://w3id.org/security/v1"
             ]

      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert "#{actor_uri}/followers" in activity["cc"]
      assert activity["id"] =~ "#create-"
    end
  end

  describe "build_delete_article/1" do
    test "builds a Delete activity with Tombstone" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, actor_uri} = Publisher.build_delete_article(article)

      assert activity["type"] == "Delete"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Tombstone"
      assert activity["object"]["id"] =~ article.slug
      assert "#{actor_uri}/followers" in activity["cc"]
      assert activity["id"] =~ "#delete-"
    end

    test "Tombstone includes formerType Article" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, _actor_uri} = Publisher.build_delete_article(article)

      assert activity["object"]["formerType"] == "Article"
    end
  end

  describe "build_announce_article/2" do
    test "builds an Announce from board actor" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, board_uri} = Publisher.build_announce_article(article, board)

      assert activity["type"] == "Announce"
      assert activity["actor"] == board_uri
      assert activity["object"] =~ article.slug
      assert board_uri =~ board.slug
      assert "#{board_uri}/followers" in activity["cc"]
      assert activity["id"] =~ "#announce-"
    end
  end

  describe "build_update_article/1" do
    test "builds an Update(Article) activity" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, actor_uri} = Publisher.build_update_article(article)

      assert activity["type"] == "Update"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Article"
      assert activity["object"]["name"] == "Test Article"
      assert "#{actor_uri}/followers" in activity["cc"]
      assert activity["id"] =~ "#update-"
    end
  end

  describe "build_create_comment/2" do
    test "builds a Create(Note) activity" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Nice post!",
          body_html: "<p>Nice post!</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      {activity, actor_uri} = Publisher.build_create_comment(comment, article)

      assert activity["type"] == "Create"
      assert activity["object"]["type"] == "Note"
      assert activity["object"]["inReplyTo"] =~ article.slug
      assert actor_uri =~ user.username
      assert "#{actor_uri}/followers" in activity["cc"]
    end

    test "Note object includes to/cc addressing for Mastodon compatibility" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Addressed note",
          body_html: "<p>Addressed note</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      {activity, actor_uri} = Publisher.build_create_comment(comment, article)

      note = activity["object"]
      assert "https://www.w3.org/ns/activitystreams#Public" in note["to"]
      assert "#{actor_uri}/followers" in note["cc"]
    end

    test "Note object includes url pointing to browsable comment" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "With URL",
          body_html: "<p>With URL</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      {activity, _actor_uri} = Publisher.build_create_comment(comment, article)

      note = activity["object"]
      assert note["url"] =~ "/articles/#{article.slug}#comment-#{comment.id}"
    end
  end

  describe "build_reject_follow/2" do
    test "builds a Reject embedding the remote actor's original Follow" do
      user = create_user()
      actor_uri = Federation.actor_uri(:user, user.username)

      follower = %Baudrate.Federation.Follower{
        actor_uri: actor_uri,
        follower_uri: "https://remote.example/users/target",
        activity_id: "https://remote.example/follows/1"
      }

      {activity, ^actor_uri} = Publisher.build_reject_follow(user, follower)

      assert activity["type"] == "Reject"
      assert activity["actor"] == actor_uri
      assert activity["id"] =~ "#reject-follow-"

      assert activity["object"] == %{
               "id" => "https://remote.example/follows/1",
               "type" => "Follow",
               "actor" => "https://remote.example/users/target",
               "object" => actor_uri
             }
    end
  end

  describe "build_update_actor/2" do
    test "builds Update(Person) for user actor" do
      user = create_user()

      {activity, actor_uri} = Publisher.build_update_actor(:user, user)

      assert activity["type"] == "Update"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Person"
      assert activity["object"]["preferredUsername"] == user.username
      assert activity["id"] =~ "#update-actor-"
      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert "#{actor_uri}/followers" in activity["cc"]
    end

    test "builds Update(Group) for board actor" do
      board = create_board()

      {activity, actor_uri} = Publisher.build_update_actor(:board, board)

      assert activity["type"] == "Update"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Group"
      assert activity["object"]["preferredUsername"] == board.slug
    end

    test "builds Update(Organization) for site actor" do
      Baudrate.Federation.KeyStore.ensure_site_keypair()

      {activity, actor_uri} = Publisher.build_update_actor(:site, nil)

      assert activity["type"] == "Update"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Organization"
    end
  end

  describe "article_object/1" do
    test "Article object includes cc field with board URIs" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, _actor_uri} = Publisher.build_create_article(article)

      object = activity["object"]
      assert is_list(object["cc"])
      refute object["cc"] == []

      board_uri = Baudrate.Federation.actor_uri(:board, board.slug)
      assert board_uri in object["cc"]
    end

    test "Article object includes summary field" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, _actor_uri} = Publisher.build_create_article(article)

      object = activity["object"]
      assert is_binary(object["summary"])
      assert object["summary"] == "Body text"
    end

    test "long article body produces truncated summary ending with ellipsis" do
      user = create_user()
      board = create_board()

      slug = "art-long-#{System.unique_integer([:positive])}"
      long_body = String.duplicate("word ", 200)

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Long Article", body: long_body, slug: slug, user_id: user.id},
          [board.id]
        )

      article = Repo.preload(article, [:boards, :user])

      object = Baudrate.Federation.article_object(article)
      assert String.length(object["summary"]) <= 501
      assert String.ends_with?(object["summary"], "…")
    end

    test "Article with hashtags includes tag array with Hashtag objects" do
      user = create_user()
      board = create_board()

      slug = "art-tags-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Tagged Article",
            body: "Check out #elixir and #phoenix!",
            slug: slug,
            user_id: user.id
          },
          [board.id]
        )

      article = Repo.preload(article, [:boards, :user])

      object = Baudrate.Federation.article_object(article)
      assert is_list(object["tag"])
      assert length(object["tag"]) == 2

      names = Enum.map(object["tag"], & &1["name"])
      assert "#elixir" in names
      assert "#phoenix" in names

      tag = Enum.find(object["tag"], &(&1["name"] == "#elixir"))
      assert tag["type"] == "Hashtag"
      assert tag["href"] =~ "/tags/elixir"
    end

    test "Article without hashtags has no tag key" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      object = Baudrate.Federation.article_object(article)
      refute Map.has_key?(object, "tag")
    end

    test "hashtags in code blocks are excluded" do
      user = create_user()
      board = create_board()

      slug = "art-codeblock-#{System.unique_integer([:positive])}"

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Code Article",
            body: "Real #visible tag\n```\n#hidden_in_code\n```\nand `#inline_hidden`",
            slug: slug,
            user_id: user.id
          },
          [board.id]
        )

      article = Repo.preload(article, [:boards, :user])

      object = Baudrate.Federation.article_object(article)
      assert is_list(object["tag"])
      names = Enum.map(object["tag"], & &1["name"])
      assert "#visible" in names
      refute "#hidden_in_code" in names
      refute "#inline_hidden" in names
    end

    test "Article with images includes Document attachments" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, img} =
        Content.create_article_image(%{
          filename: "test_image.webp",
          storage_path: "/tmp/test_image.webp",
          width: 800,
          height: 600,
          article_id: article.id,
          user_id: user.id
        })

      object = Baudrate.Federation.article_object(article)
      attachments = object["attachment"]
      assert is_list(attachments)

      image_doc = Enum.find(attachments, &(&1["mediaType"] == "image/webp"))
      assert image_doc
      assert image_doc["type"] == "Document"
      assert image_doc["url"] =~ img.filename
      assert image_doc["width"] == 800
      assert image_doc["height"] == 600
    end

    test "Article without images has no attachment key" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      object = Baudrate.Federation.article_object(article)
      refute Map.has_key?(object, "attachment")
    end
  end

  defp create_remote_actor(attrs \\ %{}) do
    uid = System.unique_integer([:positive])

    default = %{
      ap_id: "https://remote.example/users/actor-#{uid}",
      username: "actor_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/actor-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(Map.merge(default, attrs))
      |> Repo.insert()

    actor
  end

  # Replying to a timeline item requires it to be reachable from the user's feed,
  # i.e. an accepted follow on the source actor.
  defp follow_remote!(user, actor) do
    {:ok, follow} =
      %Baudrate.Federation.UserFollow{}
      |> Baudrate.Federation.UserFollow.changeset(%{
        user_id: user.id,
        remote_actor_id: actor.id,
        state: "accepted",
        ap_id: "https://local.example/follows/#{System.unique_integer([:positive])}",
        accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    follow
  end

  defp create_follower(actor_uri, remote_actor) do
    Baudrate.Federation.create_follower(
      actor_uri,
      remote_actor,
      "https://remote.example/activities/follow-#{System.unique_integer([:positive])}"
    )
  end

  describe "publish_article_created/1" do
    test "creates delivery jobs for followers" do
      user = create_user()
      board = create_board()
      remote = create_remote_actor()
      user_uri = Baudrate.Federation.actor_uri(:user, user.username)
      create_follower(user_uri, remote)

      article = create_article(user, board)

      # Clear auto-triggered delivery jobs
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_created(article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "publish_article_deleted/1" do
    test "creates delivery jobs for followers" do
      user = create_user()
      board = create_board()
      remote = create_remote_actor()
      user_uri = Baudrate.Federation.actor_uri(:user, user.username)
      create_follower(user_uri, remote)

      article = create_article(user, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_deleted(article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "publish_comment_created/2" do
    test "creates delivery jobs for followers" do
      user = create_user()
      board = create_board()
      remote = create_remote_actor()
      user_uri = Baudrate.Federation.actor_uri(:user, user.username)
      create_follower(user_uri, remote)

      article = create_article(user, board)

      {:ok, comment} =
        %Content.Comment{}
        |> Content.Comment.changeset(%{
          body: "Federated comment",
          body_html: "<p>Federated comment</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_comment_created(comment, article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "publish_article_updated/1" do
    test "creates delivery jobs for followers" do
      user = create_user()
      board = create_board()
      remote = create_remote_actor()
      user_uri = Baudrate.Federation.actor_uri(:user, user.username)
      create_follower(user_uri, remote)

      article = create_article(user, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_updated(article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "build_like_article/2" do
    test "builds a Like activity for an article" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, actor_uri} = Publisher.build_like_article(user, article)

      assert activity["type"] == "Like"
      assert activity["actor"] == actor_uri
      assert activity["object"] =~ article.slug
      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert activity["id"] =~ "#like-"
    end
  end

  describe "minted activity ids" do
    # Ids used to end in System.unique_integer/1, a counter that restarts with
    # the VM. After a restart an id could repeat, matching the delivery dedup
    # index (so the new activity was skipped) or a unique ap_id column.
    @uuid ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    test "end in a random UUID and never repeat" do
      user = create_user()
      article = create_article(user, create_board())

      ids =
        for _ <- 1..3 do
          {like, _} = Publisher.build_like_article(user, article)
          {undo, _} = Publisher.build_undo_like_article(user, article)
          {create, _} = Publisher.build_create_article(article)
          [like["id"], undo["id"], create["id"]]
        end
        |> List.flatten()

      assert Enum.all?(ids, &(&1 =~ @uuid))
      assert ids == Enum.uniq(ids)
    end
  end

  describe "build_undo_like_article/2" do
    test "builds an Undo(Like) activity" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, actor_uri} = Publisher.build_undo_like_article(user, article)

      assert activity["type"] == "Undo"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Like"
      assert activity["object"]["actor"] == actor_uri
      assert activity["object"]["object"] =~ article.slug
      assert activity["id"] =~ "#undo-like-"
    end
  end

  describe "publish_article_liked/2" do
    test "creates delivery jobs for article liked" do
      user = create_user()
      board = create_board()
      remote = create_remote_actor()
      user_uri = Baudrate.Federation.actor_uri(:user, user.username)
      create_follower(user_uri, remote)

      article = create_article(user, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_liked(user.id, article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "publish_article_unliked/2" do
    test "creates delivery jobs for article unliked" do
      user = create_user()
      board = create_board()
      remote = create_remote_actor()
      user_uri = Baudrate.Federation.actor_uri(:user, user.username)
      create_follower(user_uri, remote)

      article = create_article(user, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_unliked(user.id, article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "build_flag/3" do
    test "builds a Flag activity with correct structure" do
      uid = System.unique_integer([:positive])

      {:ok, remote_actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/flag-target-#{uid}",
          username: "flag_target_#{uid}",
          domain: "remote.example",
          public_key_pem: elem(KeyStore.generate_keypair(), 0),
          inbox: "https://remote.example/users/flag-target-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      content_ap_ids = ["https://remote.example/posts/1", "https://remote.example/posts/2"]
      reason = "Spam content"

      result = Publisher.build_flag(remote_actor, content_ap_ids, reason)

      assert is_map(result)
      assert result["type"] == "Flag"
      assert result["content"] == "Spam content"

      assert result["@context"] == [
               "https://www.w3.org/ns/activitystreams",
               "https://w3id.org/security/v1"
             ]

      site_uri = Baudrate.Federation.actor_uri(:site, nil)
      assert result["actor"] == site_uri

      assert remote_actor.ap_id in result["object"]
      assert "https://remote.example/posts/1" in result["object"]
      assert "https://remote.example/posts/2" in result["object"]
    end

    test "with empty content_ap_ids, object is just the remote actor" do
      uid = System.unique_integer([:positive])

      {:ok, remote_actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/flag-empty-#{uid}",
          username: "flag_empty_#{uid}",
          domain: "remote.example",
          public_key_pem: elem(KeyStore.generate_keypair(), 0),
          inbox: "https://remote.example/users/flag-empty-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      result = Publisher.build_flag(remote_actor, [], "Reason")

      assert result["object"] == [remote_actor.ap_id]
    end
  end

  describe "build_delete_dm/3" do
    test "Tombstone includes formerType Note" do
      user = create_user()
      uid = System.unique_integer([:positive])

      {:ok, remote_actor} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/dm-actor-#{uid}",
          username: "dm_actor_#{uid}",
          domain: "remote.example",
          public_key_pem: elem(KeyStore.generate_keypair(), 0),
          inbox: "https://remote.example/users/dm-actor-#{uid}/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      {:ok, conversation} =
        %Baudrate.Messaging.Conversation{}
        |> Baudrate.Messaging.Conversation.remote_changeset(%{
          user_a_id: user.id,
          remote_actor_b_id: remote_actor.id,
          ap_context: "https://remote.example/contexts/#{uid}"
        })
        |> Repo.insert()

      {:ok, message} =
        %Baudrate.Messaging.DirectMessage{}
        |> Baudrate.Messaging.DirectMessage.changeset(%{
          body: "Test DM",
          conversation_id: conversation.id,
          sender_user_id: user.id
        })
        |> Repo.insert()

      {activity, _actor_uri} = Publisher.build_delete_dm(message, user, conversation)

      assert activity["object"]["type"] == "Tombstone"
      assert activity["object"]["formerType"] == "Note"
    end
  end

  describe "build_delete_comment/2" do
    test "builds a Delete activity with Tombstone for a comment" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "To be deleted",
          body_html: "<p>To be deleted</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      {activity, actor_uri} = Publisher.build_delete_comment(comment, article)

      assert activity["type"] == "Delete"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Tombstone"
      assert activity["object"]["formerType"] == "Note"
      # ADR 0050: a path, not a fragment — the old id dereferenced to the actor.
      assert activity["object"]["id"] == Federation.actor_uri(:comment, comment.id)
      assert "#{actor_uri}/followers" in activity["cc"]
      assert activity["id"] =~ "#delete-"
    end
  end

  describe "publish_key_rotation/2" do
    test "creates delivery jobs with Update activity for board actor" do
      board = create_board()
      remote = create_remote_actor()
      board_uri = Baudrate.Federation.actor_uri(:board, board.slug)
      create_follower(board_uri, remote)

      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_key_rotation(:board, board)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "publish_article_forwarded/2" do
    test "enqueues delivery for public ap_enabled board" do
      user = create_user()
      board = create_board()
      # Enable AP on the board
      board
      |> Ecto.Changeset.change(%{ap_enabled: true, min_role_to_view: "guest"})
      |> Repo.update!()

      board = Repo.get!(Baudrate.Content.Board, board.id)

      remote = create_remote_actor()
      board_uri = Baudrate.Federation.actor_uri(:board, board.slug)
      create_follower(board_uri, remote)

      article = create_article(user, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_forwarded(article, board)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      # 2 jobs: Create(Article) + Announce to board followers
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.inbox_url == remote.inbox))
    end

    test "skips non-public board" do
      user = create_user()
      board = create_board()
      # Board is user-only
      board
      |> Ecto.Changeset.change(%{ap_enabled: true, min_role_to_view: "user"})
      |> Repo.update!()

      board = Repo.get!(Baudrate.Content.Board, board.id)

      article = create_article(user, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_forwarded(article, board)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert jobs == []
    end

    test "skips non-ap-enabled board" do
      user = create_user()
      board = create_board()
      # Board is public but AP disabled
      board
      |> Ecto.Changeset.change(%{ap_enabled: false, min_role_to_view: "guest"})
      |> Repo.update!()

      board = Repo.get!(Baudrate.Content.Board, board.id)

      article = create_article(user, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_forwarded(article, board)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert jobs == []
    end
  end

  describe "build_create_timeline_item_reply/3" do
    test "builds a Create(Note) activity with inReplyTo pointing to timeline item AP ID" do
      user = create_user()
      remote = create_remote_actor()
      follow_remote!(user, remote)

      {:ok, timeline_item} =
        Baudrate.Federation.create_timeline_item(%{
          remote_actor_id: remote.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
          body: "Remote post",
          body_html: "<p>Remote post</p>",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, reply} =
        Baudrate.Federation.create_timeline_item_reply(timeline_item, user, "Nice post!")

      {activity, actor_uri} =
        Publisher.build_create_timeline_item_reply(reply, timeline_item, user)

      assert activity["type"] == "Create"
      assert activity["actor"] == actor_uri
      assert actor_uri =~ user.username
      assert activity["object"]["type"] == "Note"
      assert activity["object"]["inReplyTo"] == timeline_item.ap_id
      assert activity["object"]["id"] == reply.ap_id
      assert activity["object"]["content"] =~ "Nice post!"
      assert activity["object"]["attributedTo"] == actor_uri
      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert "#{actor_uri}/followers" in activity["cc"]
      assert "https://www.w3.org/ns/activitystreams#Public" in activity["object"]["to"]
      assert "#{actor_uri}/followers" in activity["object"]["cc"]
      assert activity["id"] =~ "#create-"

      assert activity["@context"] == [
               "https://www.w3.org/ns/activitystreams",
               "https://w3id.org/security/v1"
             ]
    end
  end

  describe "publish_timeline_item_reply/2" do
    test "creates delivery jobs for the remote actor inbox" do
      user = create_user()
      remote = create_remote_actor()
      follow_remote!(user, remote)

      {:ok, timeline_item} =
        Baudrate.Federation.create_timeline_item(%{
          remote_actor_id: remote.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/#{System.unique_integer([:positive])}",
          body: "Remote post",
          body_html: "<p>Remote post</p>",
          published_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, reply} =
        Baudrate.Federation.create_timeline_item_reply(timeline_item, user, "Reply text")

      # Clear auto-triggered jobs from create_timeline_item_reply
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_timeline_item_reply(reply, timeline_item)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      refute jobs == []

      inboxes = Enum.map(jobs, & &1.inbox_url)
      assert remote.inbox in inboxes
    end
  end

  describe "publish_comment_deleted/2" do
    test "creates delivery jobs for followers" do
      user = create_user()
      board = create_board()
      remote = create_remote_actor()
      user_uri = Baudrate.Federation.actor_uri(:user, user.username)
      create_follower(user_uri, remote)

      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Will be deleted",
          body_html: "<p>Will be deleted</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_comment_deleted(comment, article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "build_like_comment/3" do
    test "builds a Like activity for a comment" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      {activity, actor_uri} = Publisher.build_like_comment(user, comment)

      assert activity["type"] == "Like"
      assert activity["actor"] == actor_uri

      assert activity["object"] ==
               Federation.actor_uri(:comment, comment.id)

      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert activity["id"] =~ "#comment-like-"
    end

    test "uses provided like_ap_id when given" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      like_ap_id = "https://local.example/users/test#comment-like-42"
      {activity, _actor_uri} = Publisher.build_like_comment(user, comment, like_ap_id)

      assert activity["id"] == like_ap_id
    end
  end

  describe "build_undo_like_comment/3" do
    test "builds an Undo(Like) activity for a comment" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      {activity, actor_uri} = Publisher.build_undo_like_comment(user, comment)

      assert activity["type"] == "Undo"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Like"
      assert activity["object"]["actor"] == actor_uri

      assert activity["object"]["object"] ==
               Federation.actor_uri(:comment, comment.id)

      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert activity["id"] =~ "#undo-comment-like-"
    end
  end

  describe "build_user_announce_article/3" do
    test "builds an Announce activity from a user for an article" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      boost_ap_id = "https://local.example/users/test#announce-1"
      {activity, actor_uri} = Publisher.build_user_announce_article(user, article, boost_ap_id)

      assert activity["type"] == "Announce"
      assert activity["actor"] == actor_uri
      assert activity["id"] == boost_ap_id
      assert activity["object"] =~ article.slug
      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert "#{actor_uri}/followers" in activity["cc"]
    end

    test "generates announce ID when boost_ap_id is nil" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {activity, _actor_uri} = Publisher.build_user_announce_article(user, article)

      assert activity["id"] =~ "#announce-"
    end
  end

  describe "build_undo_user_announce_article/3" do
    test "builds an Undo(Announce) activity for an article" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      boost_ap_id = "https://local.example/users/test#announce-1"

      {activity, actor_uri} =
        Publisher.build_undo_user_announce_article(user, article, boost_ap_id)

      assert activity["type"] == "Undo"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Announce"
      assert activity["object"]["id"] == boost_ap_id
      assert activity["object"]["actor"] == actor_uri
      assert activity["object"]["object"] =~ article.slug
      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert "#{actor_uri}/followers" in activity["cc"]
      assert activity["id"] =~ "#undo-announce-"
    end
  end

  describe "build_user_announce_comment/3" do
    test "builds an Announce activity from a user for a comment" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      boost_ap_id = "https://local.example/users/test#announce-1"
      {activity, actor_uri} = Publisher.build_user_announce_comment(user, comment, boost_ap_id)

      assert activity["type"] == "Announce"
      assert activity["actor"] == actor_uri
      assert activity["id"] == boost_ap_id

      assert activity["object"] ==
               Federation.actor_uri(:comment, comment.id)

      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert "#{actor_uri}/followers" in activity["cc"]
    end

    test "generates announce ID when boost_ap_id is nil" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      {activity, _actor_uri} = Publisher.build_user_announce_comment(user, comment)

      assert activity["id"] =~ "#comment-announce-"
    end
  end

  describe "build_undo_user_announce_comment/3" do
    test "builds an Undo(Announce) activity for a comment" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      boost_ap_id = "https://local.example/users/test#announce-1"

      {activity, actor_uri} =
        Publisher.build_undo_user_announce_comment(user, comment, boost_ap_id)

      assert activity["type"] == "Undo"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Announce"
      assert activity["object"]["id"] == boost_ap_id
      assert activity["object"]["actor"] == actor_uri

      assert activity["object"]["object"] ==
               Federation.actor_uri(:comment, comment.id)

      assert "https://www.w3.org/ns/activitystreams#Public" in activity["to"]
      assert "#{actor_uri}/followers" in activity["cc"]
      assert activity["id"] =~ "#undo-comment-announce-"
    end
  end

  describe "publish_comment_liked/2" do
    test "creates delivery jobs for comment liked" do
      user = create_user()
      board = create_board()
      remote = create_remote_actor()
      user_uri = Baudrate.Federation.actor_uri(:user, user.username)
      create_follower(user_uri, remote)

      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: user.id
        })
        |> Repo.insert()

      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_comment_liked(user.id, comment)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == remote.inbox
    end
  end

  describe "publish_article_boosted/2" do
    test "delivers Announce to the booster's followers, not the article author's followers" do
      author = create_user()
      booster = create_user()
      board = create_board()

      author_remote = create_remote_actor()
      booster_remote = create_remote_actor()

      author_uri = Baudrate.Federation.actor_uri(:user, author.username)
      booster_uri = Baudrate.Federation.actor_uri(:user, booster.username)

      create_follower(author_uri, author_remote)
      create_follower(booster_uri, booster_remote)

      article = create_article(author, board)
      {:ok, _boost} = Baudrate.Content.Boosts.boost_article(booster.id, article.id)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_boosted(booster.id, article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      inbox_urls = Enum.map(jobs, & &1.inbox_url)

      assert booster_remote.inbox in inbox_urls
      refute author_remote.inbox in inbox_urls
    end

    test "delivers nothing when booster has no followers" do
      author = create_user()
      booster = create_user()
      board = create_board()

      article = create_article(author, board)
      {:ok, _boost} = Baudrate.Content.Boosts.boost_article(booster.id, article.id)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      {:ok, count} = Publisher.publish_article_boosted(booster.id, article)

      assert count == 0
    end
  end

  describe "publish_article_unboosted/3" do
    test "delivers Undo(Announce) to the booster's followers" do
      author = create_user()
      booster = create_user()
      board = create_board()

      booster_remote = create_remote_actor()
      booster_uri = Baudrate.Federation.actor_uri(:user, booster.username)
      create_follower(booster_uri, booster_remote)

      article = create_article(author, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_article_unboosted(booster.id, article)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == booster_remote.inbox

      body = Jason.decode!(hd(jobs).activity_json)
      assert body["type"] == "Undo"
      assert body["object"]["type"] == "Announce"
    end
  end

  describe "publish_comment_boosted/2" do
    test "delivers Announce to the booster's followers, not the article author's followers" do
      author = create_user()
      booster = create_user()
      board = create_board()

      author_remote = create_remote_actor()
      booster_remote = create_remote_actor()

      author_uri = Baudrate.Federation.actor_uri(:user, author.username)
      booster_uri = Baudrate.Federation.actor_uri(:user, booster.username)

      create_follower(author_uri, author_remote)
      create_follower(booster_uri, booster_remote)

      article = create_article(author, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: author.id
        })
        |> Repo.insert()

      {:ok, _boost} = Baudrate.Content.Boosts.boost_comment(booster.id, comment.id)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_comment_boosted(booster.id, comment)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      inbox_urls = Enum.map(jobs, & &1.inbox_url)

      assert booster_remote.inbox in inbox_urls
      refute author_remote.inbox in inbox_urls
    end
  end

  describe "publish_comment_unboosted/3" do
    test "delivers Undo(Announce) to the booster's followers" do
      author = create_user()
      booster = create_user()
      board = create_board()

      booster_remote = create_remote_actor()
      booster_uri = Baudrate.Federation.actor_uri(:user, booster.username)
      create_follower(booster_uri, booster_remote)

      article = create_article(author, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{
          body: "Test comment",
          body_html: "<p>Test comment</p>",
          article_id: article.id,
          user_id: author.id
        })
        |> Repo.insert()

      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      Publisher.publish_comment_unboosted(booster.id, comment)

      jobs = Repo.all(Baudrate.Federation.DeliveryJob)
      assert length(jobs) == 1
      assert hd(jobs).inbox_url == booster_remote.inbox

      body = Jason.decode!(hd(jobs).activity_json)
      assert body["type"] == "Undo"
      assert body["object"]["type"] == "Announce"
    end
  end

  # --- The board gate, and the withdrawals it must not touch ---

  defp create_private_board do
    board =
      %Baudrate.Content.Board{}
      |> Baudrate.Content.Board.changeset(%{
        name: "Staff Only",
        slug: "pub-private-#{System.unique_integer([:positive])}",
        min_role_to_view: "admin"
      })
      |> Repo.insert!()

    {:ok, board} = KeyStore.ensure_board_keypair(board)
    board
  end

  defp create_comment(article, user) do
    {:ok, comment} =
      %Comment{}
      |> Comment.changeset(%{
        body: "Test comment",
        body_html: "<p>Test comment</p>",
        article_id: article.id,
        user_id: user.id
      })
      |> Repo.insert()

    comment
  end

  defp inbox_urls do
    Baudrate.Federation.DeliveryJob |> Repo.all() |> Enum.map(& &1.inbox_url)
  end

  describe "withdrawals are never gated by the board" do
    setup do
      # The article's only board is private: the gate answers "do not
      # federate". Everything here is about what must happen anyway, because
      # a `Delete`/`Undo` carries no content — refusing to send one cannot
      # protect anything, and leaves the post published on every follower's
      # server forever.
      user = create_user()
      board = create_private_board()
      remote = create_remote_actor()
      create_follower(Baudrate.Federation.actor_uri(:user, user.username), remote)

      article = create_article(user, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      {:ok, user: user, remote: remote, article: article}
    end

    test "the gate itself is real: an Update does not go out", %{article: article} do
      assert {:ok, 0} = Publisher.publish_article_updated(article)
      assert inbox_urls() == []
    end

    # ADR 0051's sixth surface. A mention is the one place a *member* picks an
    # outbound recipient, by typing a handle — so it is governed by this gate
    # rather than being an exception to it. `mentions_test.exs` covers the
    # behaviour; this is here because the list of surfaces lives here.
    test "a mention does not carry the article out of a private board", %{
      article: article,
      user: user
    } do
      actor = create_remote_actor()

      {:ok, mentioning} =
        Baudrate.Content.update_article(
          article,
          %{body: "hi @#{actor.username}@#{actor.domain}"},
          user
        )

      Repo.delete_all(Baudrate.Federation.DeliveryJob)
      Publisher.publish_article_created(Repo.preload(mentioning, [:boards, :user]))

      assert inbox_urls() == []
      refute actor.ap_id in (Baudrate.Federation.article_object(mentioning)["cc"] || [])
    end

    test "publish_article_deleted/1 delivers the Delete(Tombstone)", %{
      article: article,
      remote: remote
    } do
      assert {:ok, 1} = Publisher.publish_article_deleted(article)
      assert inbox_urls() == [remote.inbox]

      body = Repo.all(Baudrate.Federation.DeliveryJob) |> hd() |> Map.fetch!(:activity_json)
      body = Jason.decode!(body)
      assert body["type"] == "Delete"
      assert body["object"]["type"] == "Tombstone"
    end

    test "publish_comment_deleted/2 delivers the Delete", %{
      article: article,
      user: user,
      remote: remote
    } do
      comment = create_comment(article, user)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      # `:ok`, not `{:ok, count}`: a comment rewritten by the ADR 0050 backfill
      # is withdrawn under both its ids, so there is no single job count.
      assert :ok = Publisher.publish_comment_deleted(comment, article)
      assert inbox_urls() == [remote.inbox]
    end

    test "publish_article_unliked/3 delivers the Undo(Like)", %{
      article: article,
      user: user,
      remote: remote
    } do
      assert {:ok, 1} = Publisher.publish_article_unliked(user.id, article)
      assert inbox_urls() == [remote.inbox]
    end

    test "publish_comment_unliked/3 delivers the Undo(Like)", %{
      article: article,
      user: user,
      remote: remote
    } do
      comment = create_comment(article, user)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      assert {:ok, 1} = Publisher.publish_comment_unliked(user.id, comment)
      assert inbox_urls() == [remote.inbox]
    end
  end

  describe "the boost fan-out honours the board gate" do
    test "publish_article_boosted/2 tells the booster's followers nothing about a private board" do
      # An `Announce` names `<base>/ap/articles/<slug>`, and the slug is
      # derived from the title — so boosting a private-board post told the
      # booster's remote followers that the post exists and roughly what it
      # is called. This path does not go through `enqueue_for_article/4`, so
      # it needs the gate explicitly.
      author = create_user()
      booster = create_user()
      board = create_private_board()

      booster_remote = create_remote_actor()
      create_follower(Baudrate.Federation.actor_uri(:user, booster.username), booster_remote)

      article = create_article(author, board)
      {:ok, _boost} = Baudrate.Content.Boosts.boost_article(booster.id, article.id)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      assert {:ok, 0} = Publisher.publish_article_boosted(booster.id, article)
      refute booster_remote.inbox in inbox_urls()
    end

    test "publish_comment_boosted/2 is gated the same way" do
      author = create_user()
      booster = create_user()
      board = create_private_board()

      booster_remote = create_remote_actor()
      create_follower(Baudrate.Federation.actor_uri(:user, booster.username), booster_remote)

      article = create_article(author, board)
      comment = create_comment(article, author)
      {:ok, _boost} = Baudrate.Content.Boosts.boost_comment(booster.id, comment.id)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      assert {:ok, 0} = Publisher.publish_comment_boosted(booster.id, comment)
      refute booster_remote.inbox in inbox_urls()
    end

    test "the remote author of a remote article still gets the Announce" do
      # The documented exception: a remote article already exists on the
      # fediverse with its own `ap_id`, so its author's instance must still
      # be told — only the booster's follower fan-out is withheld.
      booster = create_user()
      board = create_private_board()

      author_remote = create_remote_actor()
      booster_remote = create_remote_actor()
      create_follower(Baudrate.Federation.actor_uri(:user, booster.username), booster_remote)

      n = System.unique_integer([:positive])

      {:ok, %{article: article}} =
        Baudrate.Content.create_remote_article(
          %{
            title: "Remote post #{n}",
            body: "body",
            slug: "pub-remote-#{n}",
            ap_id: "https://remote.example/articles/#{n}",
            remote_actor_id: author_remote.id,
            visibility: "public"
          },
          [board.id]
        )

      {:ok, _boost} = Baudrate.Content.Boosts.boost_article(booster.id, article.id)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      assert {:ok, 1} = Publisher.publish_article_boosted(booster.id, article)

      urls = inbox_urls()
      assert author_remote.inbox in urls
      refute booster_remote.inbox in urls
    end

    test "publish_article_unboosted/3 is a withdrawal and still goes out" do
      author = create_user()
      booster = create_user()
      board = create_private_board()

      booster_remote = create_remote_actor()
      create_follower(Baudrate.Federation.actor_uri(:user, booster.username), booster_remote)

      article = create_article(author, board)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      assert {:ok, 1} = Publisher.publish_article_unboosted(booster.id, article)
      assert inbox_urls() == [booster_remote.inbox]

      body = Repo.all(Baudrate.Federation.DeliveryJob) |> hd() |> Map.fetch!(:activity_json)
      assert Jason.decode!(body)["type"] == "Undo"
    end

    test "publish_comment_unboosted/3 likewise" do
      author = create_user()
      booster = create_user()
      board = create_private_board()

      booster_remote = create_remote_actor()
      create_follower(Baudrate.Federation.actor_uri(:user, booster.username), booster_remote)

      article = create_article(author, board)
      comment = create_comment(article, author)
      Repo.delete_all(Baudrate.Federation.DeliveryJob)

      assert {:ok, 1} = Publisher.publish_comment_unboosted(booster.id, comment)
      assert inbox_urls() == [booster_remote.inbox]
    end
  end

  describe "build_create_article/1 addressing" do
    test "carries no private board slug in cc or audience" do
      # `article_addressing/2` overwrites `cc` on the activity and on the
      # object, but `audience` comes from the object builder — which is the
      # field the earlier partial fix missed, and it reaches every recipient.
      user = create_user()
      public_board = create_board()
      private_board = create_private_board()

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Cross-posted",
            body: "Body text",
            slug: "art-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          [public_board.id, private_board.id]
        )

      {activity, _actor_uri} = Publisher.build_create_article(article)

      public_uri = Baudrate.Federation.actor_uri(:board, public_board.slug)
      private_uri = Baudrate.Federation.actor_uri(:board, private_board.slug)

      assert public_uri in activity["cc"]
      assert activity["object"]["audience"] == [public_uri]

      refute private_uri in activity["cc"]
      refute private_uri in activity["object"]["cc"]
      refute private_uri in activity["object"]["audience"]
      refute Jason.encode!(activity) =~ private_board.slug
    end
  end
end
