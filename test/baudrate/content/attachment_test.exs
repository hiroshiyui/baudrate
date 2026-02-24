defmodule Baudrate.Content.AttachmentTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.Attachment

  setup do
    Baudrate.Setup.seed_roles_and_permissions()

    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "attach_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    board =
      %Content.Board{}
      |> Content.Board.changeset(%{name: "Attachment Test Board", slug: "attach-board-#{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    {:ok, %{article: article}} =
      Content.create_article(
        %{title: "Attach Article", body: "Body", slug: "attach-art-#{System.unique_integer([:positive])}", user_id: user.id},
        [board.id]
      )

    {:ok, user: user, article: article}
  end

  defp valid_attrs(article, user) do
    %{
      filename: "test-#{System.unique_integer([:positive])}.png",
      original_filename: "photo.png",
      content_type: "image/png",
      size: 1024,
      storage_path: "/tmp/uploads/test.png",
      article_id: article.id,
      user_id: user.id
    }
  end

  describe "create_attachment/1" do
    test "creates attachment with valid attrs", %{article: article, user: user} do
      assert {:ok, attachment} = Content.create_attachment(valid_attrs(article, user))
      assert attachment.content_type == "image/png"
      assert attachment.article_id == article.id
    end

    test "returns error with missing required fields" do
      assert {:error, changeset} = Content.create_attachment(%{})
      errors = errors_on(changeset)
      assert errors[:filename]
      assert errors[:original_filename]
      assert errors[:content_type]
      assert errors[:size]
      assert errors[:storage_path]
      assert errors[:article_id]
    end

    test "returns error for invalid content_type", %{article: article, user: user} do
      attrs = valid_attrs(article, user) |> Map.put(:content_type, "application/exe")
      assert {:error, changeset} = Content.create_attachment(attrs)
      assert errors_on(changeset)[:content_type]
    end

    test "returns error when size exceeds limit", %{article: article, user: user} do
      attrs = valid_attrs(article, user) |> Map.put(:size, 11 * 1024 * 1024)
      assert {:error, changeset} = Content.create_attachment(attrs)
      assert errors_on(changeset)[:size]
    end
  end

  describe "list_attachments_for_article/1" do
    test "returns attachments ordered by inserted_at", %{article: article, user: user} do
      {:ok, a1} = Content.create_attachment(valid_attrs(article, user))
      {:ok, a2} = Content.create_attachment(valid_attrs(article, user))

      result = Content.list_attachments_for_article(article)
      assert length(result) == 2
      assert List.first(result).id == a1.id
      assert List.last(result).id == a2.id
    end

    test "returns empty list for article with no attachments", %{article: article} do
      assert Content.list_attachments_for_article(article) == []
    end
  end

  describe "get_attachment!/1" do
    test "returns attachment by ID", %{article: article, user: user} do
      {:ok, attachment} = Content.create_attachment(valid_attrs(article, user))
      assert Content.get_attachment!(attachment.id).id == attachment.id
    end

    test "raises for missing ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Content.get_attachment!(0)
      end
    end
  end

  describe "Attachment constants" do
    test "max_size returns 10 MB" do
      assert Attachment.max_size() == 10 * 1024 * 1024
    end

    test "allowed_content_types returns expected list" do
      types = Attachment.allowed_content_types()
      assert "image/jpeg" in types
      assert "image/png" in types
      assert "application/pdf" in types
      assert "text/plain" in types
      assert "application/zip" in types
    end
  end
end
