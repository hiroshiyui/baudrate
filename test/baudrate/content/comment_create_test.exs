defmodule Baudrate.Content.CommentCreateTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    import Ecto.Query
    role = Repo.one!(from r in Setup.Role, where: r.name == "user")

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

  defp create_article(user, board) do
    slug = "article-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Test Article", body: "Body", slug: slug, user_id: user.id},
        [board.id]
      )

    article
  end

  describe "create_comment/1" do
    test "creates a local comment with rendered HTML" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      assert {:ok, comment} =
               Content.create_comment(%{
                 "body" => "**Hello** world",
                 "article_id" => article.id,
                 "user_id" => user.id
               })

      assert comment.body == "**Hello** world"
      assert comment.body_html =~ "<strong>Hello</strong>"
      assert comment.user_id == user.id
      assert comment.article_id == article.id
    end

    test "creates a threaded reply" do
      user = create_user()
      board = create_board()
      article = create_article(user, board)

      {:ok, parent} =
        Content.create_comment(%{
          "body" => "Parent comment",
          "article_id" => article.id,
          "user_id" => user.id
        })

      {:ok, reply} =
        Content.create_comment(%{
          "body" => "Reply to parent",
          "article_id" => article.id,
          "user_id" => user.id,
          "parent_id" => parent.id
        })

      assert reply.parent_id == parent.id
    end

    test "validates required fields" do
      assert {:error, changeset} = Content.create_comment(%{"body" => ""})
      assert %{body: _, article_id: _, user_id: _} = errors_on(changeset)
    end
  end

  describe "change_comment/2" do
    test "returns a changeset" do
      changeset = Content.change_comment()
      assert %Ecto.Changeset{} = changeset
    end
  end
end
