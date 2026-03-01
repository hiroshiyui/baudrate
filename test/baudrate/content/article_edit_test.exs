defmodule Baudrate.Content.ArticleEditTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{Article, Board}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user(role_name) do
    import Ecto.Query
    role = Repo.one!(from r in Setup.Role, where: r.name == ^role_name)

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "user_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_board do
    slug = "board-#{System.unique_integer([:positive])}"

    %Board{}
    |> Board.changeset(%{name: "Board", slug: slug})
    |> Repo.insert!()
  end

  describe "update_article/2" do
    test "updates title and body" do
      user = create_user("user")
      board = create_board()

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Original", body: "Original body", slug: "update-test", user_id: user.id},
          [board.id]
        )

      assert {:ok, updated} =
               Content.update_article(article, %{title: "Updated", body: "New body"})

      assert updated.title == "Updated"
      assert updated.body == "New body"
      assert updated.slug == "update-test"
    end

    test "rejects empty title" do
      user = create_user("user")
      board = create_board()

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Valid", body: "body", slug: "valid-slug", user_id: user.id},
          [board.id]
        )

      assert {:error, changeset} = Content.update_article(article, %{title: ""})
      assert %{title: _} = errors_on(changeset)
    end
  end

  describe "change_article_for_edit/2" do
    test "returns changeset for existing article" do
      changeset = Content.change_article_for_edit(%Article{title: "Test", body: "Body"})
      assert %Ecto.Changeset{} = changeset
    end
  end

end
