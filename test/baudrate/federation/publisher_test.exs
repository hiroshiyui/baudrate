defmodule Baudrate.Federation.PublisherTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Comment
  alias Baudrate.Federation.{KeyStore, Publisher}

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
      assert activity["id"] =~ "#delete-"
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
    end
  end
end
