defmodule Baudrate.Federation.PublisherTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Comment
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

    # Wait for async federation task to finish or fail
    Process.sleep(50)

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
      assert activity["@context"] == "https://www.w3.org/ns/activitystreams"
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
  end

  describe "build_block/2" do
    test "builds a Block activity" do
      user = create_user()
      target_ap_id = "https://remote.example/users/target"

      {activity, actor_uri} = Publisher.build_block(user, target_ap_id)

      assert activity["type"] == "Block"
      assert activity["actor"] == actor_uri
      assert activity["object"] == target_ap_id
      assert activity["@context"] == "https://www.w3.org/ns/activitystreams"
      assert activity["id"] =~ "#block-"
    end
  end

  describe "build_undo_block/2" do
    test "builds an Undo(Block) activity" do
      user = create_user()
      target_ap_id = "https://remote.example/users/target"

      {activity, actor_uri} = Publisher.build_undo_block(user, target_ap_id)

      assert activity["type"] == "Undo"
      assert activity["actor"] == actor_uri
      assert activity["object"]["type"] == "Block"
      assert activity["object"]["actor"] == actor_uri
      assert activity["object"]["object"] == target_ap_id
      assert activity["id"] =~ "#undo-block-"
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
      assert length(object["cc"]) > 0

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

      Process.sleep(50)
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

      Process.sleep(50)
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

      Process.sleep(50)
      article = Repo.preload(article, [:boards, :user])

      object = Baudrate.Federation.article_object(article)
      assert is_list(object["tag"])
      names = Enum.map(object["tag"], & &1["name"])
      assert "#visible" in names
      refute "#hidden_in_code" in names
      refute "#inline_hidden" in names
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
end
