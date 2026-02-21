defmodule Baudrate.Content.ArticleLikeTest do
  use Baudrate.DataCase

  alias Baudrate.Content.ArticleLike
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
    test "valid local like" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      changeset = ArticleLike.changeset(%ArticleLike{}, %{article_id: article.id, user_id: user.id})
      assert changeset.valid?
    end

    test "requires article_id and user_id" do
      changeset = ArticleLike.changeset(%ArticleLike{}, %{})
      refute changeset.valid?
      assert %{article_id: _, user_id: _} = errors_on(changeset)
    end
  end

  describe "remote_changeset/2" do
    test "valid remote like" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      remote_actor = create_remote_actor()

      changeset =
        ArticleLike.remote_changeset(%ArticleLike{}, %{
          ap_id: "https://remote.example/likes/123",
          article_id: article.id,
          remote_actor_id: remote_actor.id
        })

      assert changeset.valid?
    end

    test "enforces unique (article_id, remote_actor_id)" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)
      remote_actor = create_remote_actor()

      attrs = %{
        ap_id: "https://remote.example/likes/#{System.unique_integer([:positive])}",
        article_id: article.id,
        remote_actor_id: remote_actor.id
      }

      {:ok, _} =
        %ArticleLike{}
        |> ArticleLike.remote_changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %ArticleLike{}
        |> ArticleLike.remote_changeset(%{attrs | ap_id: "https://remote.example/likes/#{System.unique_integer([:positive])}"})
        |> Repo.insert()

      assert %{article_id: _} = errors_on(changeset)
    end
  end
end
