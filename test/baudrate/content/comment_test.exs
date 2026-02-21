defmodule Baudrate.Content.CommentTest do
  use Baudrate.DataCase

  alias Baudrate.Content.Comment
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  defp create_board do
    %Baudrate.Content.Board{}
    |> Baudrate.Content.Board.changeset(%{name: "Test", slug: "test-#{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp create_article(user, board) do
    slug = "art-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(
        %{title: "Test Article", body: "Body", slug: slug, user_id: user.id},
        [board.id]
      )

    article
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])
    {public_pem, _} = Baudrate.Federation.KeyStore.generate_keypair()

    {:ok, actor} =
      %Baudrate.Federation.RemoteActor{}
      |> Baudrate.Federation.RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/actor-#{uid}",
        username: "actor_#{uid}",
        domain: "remote.example",
        public_key_pem: public_pem,
        inbox: "https://remote.example/users/actor-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    actor
  end

  describe "changeset/2 (local)" do
    test "valid local comment" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      changeset =
        Comment.changeset(%Comment{}, %{
          body: "Great post!",
          article_id: article.id,
          user_id: user.id
        })

      assert changeset.valid?
    end

    test "requires body, article_id, user_id" do
      changeset = Comment.changeset(%Comment{}, %{})
      refute changeset.valid?
      assert %{body: _, article_id: _, user_id: _} = errors_on(changeset)
    end
  end

  describe "remote_changeset/2" do
    test "valid remote comment" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      remote_actor = create_remote_actor()

      changeset =
        Comment.remote_changeset(%Comment{}, %{
          body: "Hello from remote!",
          body_html: "<p>Hello from remote!</p>",
          ap_id: "https://remote.example/notes/123",
          article_id: article.id,
          remote_actor_id: remote_actor.id
        })

      assert changeset.valid?
    end

    test "requires ap_id for remote comments" do
      changeset = Comment.remote_changeset(%Comment{}, %{body: "test"})
      refute changeset.valid?
      assert %{ap_id: _} = errors_on(changeset)
    end
  end

  describe "soft_delete_changeset/1" do
    test "sets deleted_at and clears body" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, comment} =
        %Comment{}
        |> Comment.changeset(%{body: "Original", article_id: article.id, user_id: user.id})
        |> Repo.insert()

      changeset = Comment.soft_delete_changeset(comment)
      assert changeset.valid?

      {:ok, deleted} = Repo.update(changeset)
      assert deleted.deleted_at != nil
      assert deleted.body == "[deleted]"
      assert deleted.body_html == nil
    end
  end
end
