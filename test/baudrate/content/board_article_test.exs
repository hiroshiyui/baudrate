defmodule Baudrate.Content.BoardArticleTest do
  use Baudrate.DataCase

  alias Baudrate.Content.BoardArticle

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "ba_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    board =
      %Baudrate.Content.Board{}
      |> Baudrate.Content.Board.changeset(%{name: "BA Board", slug: "ba-board-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Baudrate.Content.create_article(
        %{title: "BA Article", body: "Body", slug: "ba-art-#{System.unique_integer([:positive])}", user_id: user.id},
        [board.id]
      )

    {:ok, board: board, article: article}
  end

  describe "changeset/2" do
    test "valid changeset", %{board: board, article: article} do
      changeset = BoardArticle.changeset(%BoardArticle{}, %{board_id: board.id, article_id: article.id})
      assert changeset.valid?
    end

    test "missing required fields" do
      changeset = BoardArticle.changeset(%BoardArticle{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:board_id]
      assert errors[:article_id]
    end

    test "unique constraint prevents duplicate", %{board: board, article: article} do
      # The article is already linked to the board via create_article
      {:error, changeset} =
        %BoardArticle{}
        |> BoardArticle.changeset(%{board_id: board.id, article_id: article.id})
        |> Repo.insert()

      assert errors_on(changeset)[:board_id]
    end
  end
end
