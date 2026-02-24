defmodule Baudrate.Content.ArticleImageTest do
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{ArticleImage, ArticleImageStorage, Board}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    # Create test image on disk
    tmp_dir =
      Path.join(System.tmp_dir!(), "article_img_ctx_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    {:ok, img} = Image.new(200, 200, color: [255, 100, 50])
    img_path = Path.join(tmp_dir, "test.png")
    Image.write!(img, img_path)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{img_path: img_path}
  end

  defp create_user(role_name) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

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

  defp create_board(attrs) do
    %Board{}
    |> Board.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_image(user, article_id \\ nil, img_path) do
    {:ok, file_info} = ArticleImageStorage.process_upload(img_path)
    attrs = Map.merge(file_info, %{user_id: user.id, article_id: article_id})
    {:ok, image} = Content.create_article_image(attrs)
    image
  end

  describe "create_article_image/1" do
    test "creates an article image record", %{img_path: img_path} do
      user = create_user("user")
      {:ok, file_info} = ArticleImageStorage.process_upload(img_path)
      attrs = Map.merge(file_info, %{user_id: user.id})

      assert {:ok, image} = Content.create_article_image(attrs)
      assert image.filename == file_info.filename
      assert image.width == file_info.width
      assert image.height == file_info.height
      assert is_nil(image.article_id)

      ArticleImageStorage.delete_image(image)
    end
  end

  describe "list_article_images/1" do
    test "returns images for an article", %{img_path: img_path} do
      user = create_user("user")
      board = create_board(%{name: "Img Board", slug: "img-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Img Article", body: "body", slug: "img-art", user_id: user.id},
          [board.id]
        )

      img1 = create_image(user, article.id, img_path)
      img2 = create_image(user, article.id, img_path)

      images = Content.list_article_images(article.id)
      assert length(images) == 2
      ids = Enum.map(images, & &1.id)
      assert img1.id in ids
      assert img2.id in ids

      Enum.each(images, &ArticleImageStorage.delete_image/1)
    end

    test "returns empty list for article with no images" do
      assert Content.list_article_images(-1) == []
    end
  end

  describe "list_orphan_article_images/1" do
    test "returns only images without article_id for user", %{img_path: img_path} do
      user = create_user("user")
      board = create_board(%{name: "Orphan Board", slug: "orphan-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Orphan Art", body: "body", slug: "orphan-art", user_id: user.id},
          [board.id]
        )

      orphan = create_image(user, nil, img_path)
      _associated = create_image(user, article.id, img_path)

      orphans = Content.list_orphan_article_images(user.id)
      assert length(orphans) == 1
      assert hd(orphans).id == orphan.id

      ArticleImageStorage.delete_image(orphan)
    end
  end

  describe "delete_article_image/1" do
    test "deletes record and file", %{img_path: img_path} do
      user = create_user("user")
      image = create_image(user, nil, img_path)

      assert File.exists?(image.storage_path)
      assert {:ok, _} = Content.delete_article_image(image)
      refute File.exists?(image.storage_path)
      assert_raise Ecto.NoResultsError, fn -> Content.get_article_image!(image.id) end
    end
  end

  describe "associate_article_images/3" do
    test "associates orphan images with an article", %{img_path: img_path} do
      user = create_user("user")
      board = create_board(%{name: "Assoc Board", slug: "assoc-board"})

      img1 = create_image(user, nil, img_path)
      img2 = create_image(user, nil, img_path)

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Assoc Art", body: "body", slug: "assoc-art", user_id: user.id},
          [board.id]
        )

      {2, _} = Content.associate_article_images(article.id, [img1.id, img2.id], user.id)

      images = Content.list_article_images(article.id)
      assert length(images) == 2

      Enum.each(images, &ArticleImageStorage.delete_image/1)
    end

    test "only associates images owned by the user", %{img_path: img_path} do
      user1 = create_user("user")
      user2 = create_user("user")
      board = create_board(%{name: "Own Board", slug: "own-board"})

      img = create_image(user1, nil, img_path)

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Own Art", body: "body", slug: "own-art", user_id: user2.id},
          [board.id]
        )

      # user2 tries to associate user1's image
      {0, _} = Content.associate_article_images(article.id, [img.id], user2.id)

      assert Content.list_article_images(article.id) == []

      ArticleImageStorage.delete_image(img)
    end
  end

  describe "create_article with image_ids option" do
    test "associates images during article creation", %{img_path: img_path} do
      user = create_user("user")
      board = create_board(%{name: "Create Img Board", slug: "create-img-board"})

      img = create_image(user, nil, img_path)

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "With Images", body: "body", slug: "with-images", user_id: user.id},
          [board.id],
          image_ids: [img.id]
        )

      images = Content.list_article_images(article.id)
      assert length(images) == 1
      assert hd(images).id == img.id

      Enum.each(images, &ArticleImageStorage.delete_image/1)
    end
  end

  describe "delete_orphan_article_images/1" do
    test "deletes orphan images older than cutoff", %{img_path: img_path} do
      user = create_user("user")
      image = create_image(user, nil, img_path)

      # Set inserted_at to 25 hours ago
      old_time = DateTime.utc_now() |> DateTime.add(-25, :hour) |> DateTime.truncate(:second)

      from(ai in ArticleImage, where: ai.id == ^image.id)
      |> Repo.update_all(set: [inserted_at: old_time])

      cutoff = DateTime.utc_now() |> DateTime.add(-24, :hour)
      paths = Content.delete_orphan_article_images(cutoff)

      assert image.storage_path in paths

      # Clean up file
      for path <- paths, do: File.rm(path)
    end

    test "does not delete recent orphan images", %{img_path: img_path} do
      user = create_user("user")
      image = create_image(user, nil, img_path)

      cutoff = DateTime.utc_now() |> DateTime.add(-24, :hour)
      paths = Content.delete_orphan_article_images(cutoff)

      refute image.storage_path in paths

      ArticleImageStorage.delete_image(image)
    end

    test "does not delete associated images", %{img_path: img_path} do
      user = create_user("user")
      board = create_board(%{name: "No Del Board", slug: "no-del-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "No Del Art", body: "body", slug: "no-del-art", user_id: user.id},
          [board.id]
        )

      image = create_image(user, article.id, img_path)

      old_time = DateTime.utc_now() |> DateTime.add(-25, :hour) |> DateTime.truncate(:second)

      from(ai in ArticleImage, where: ai.id == ^image.id)
      |> Repo.update_all(set: [inserted_at: old_time])

      cutoff = DateTime.utc_now() |> DateTime.add(-24, :hour)
      paths = Content.delete_orphan_article_images(cutoff)

      refute image.storage_path in paths

      ArticleImageStorage.delete_image(image)
    end
  end

  describe "count_article_images/1" do
    test "returns count of images for article", %{img_path: img_path} do
      user = create_user("user")
      board = create_board(%{name: "Count Board", slug: "count-img-board"})

      {:ok, %{article: article}} =
        Content.create_article(
          %{title: "Count Art", body: "body", slug: "count-img-art", user_id: user.id},
          [board.id]
        )

      assert Content.count_article_images(article.id) == 0

      img1 = create_image(user, article.id, img_path)
      img2 = create_image(user, article.id, img_path)

      assert Content.count_article_images(article.id) == 2

      Enum.each([img1, img2], &ArticleImageStorage.delete_image/1)
    end
  end
end
