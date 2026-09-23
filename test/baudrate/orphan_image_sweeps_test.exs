defmodule Baudrate.OrphanImageSweepsTest do
  @moduledoc """
  The orphan sweeps unlink the file they name, whatever `storage_path` says
  (ADR 0040), including the two added or fixed in 6D: direct-message images
  that were never sent, and timeline reply images, whose sweep still
  returned the stale `storage_path`.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.Content.ArticleImageStorage
  alias Baudrate.DataPortability.Files
  alias Baudrate.Federation
  alias Baudrate.Messaging
  alias Baudrate.Messaging.DmImage
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()

    png = Path.join(System.tmp_dir!(), "sweep-#{System.unique_integer([:positive])}.png")
    Image.new!(40, 40, color: [10, 120, 200]) |> Image.write!(png)
    on_exit(fn -> File.rm(png) end)

    %{png: png, user: member()}
  end

  describe "timeline reply images" do
    test "the path comes from the filename, not a stale storage_path", %{png: png, user: user} do
      {:ok, info} = ArticleImageStorage.process_upload(png)

      {:ok, image} =
        Federation.create_reply_image(%{
          filename: info.filename,
          # What the row holds after a deploy removed the release it named.
          storage_path: "/srv/releases/gone/priv/static/uploads/article_images/#{info.filename}",
          width: info.width,
          height: info.height,
          user_id: user.id
        })

      age!(Baudrate.Federation.TimelineItemReplyImage, image.id)
      {:ok, real_path} = Files.image_path("article_images", info.filename)

      assert Federation.delete_orphan_reply_images(DateTime.utc_now()) == [real_path]
      File.rm(real_path)
    end
  end

  describe "direct-message images" do
    test "an old unsent image goes with its file; a sent or recent one stays", %{
      png: png,
      user: user
    } do
      other = member()
      {:ok, conversation} = Messaging.find_or_create_conversation(user, other)

      {:ok, old} = Messaging.create_dm_image(user, png)
      {:ok, recent} = Messaging.create_dm_image(user, png)
      {:ok, sent} = Messaging.create_dm_image(user, png)
      {:ok, _} = Messaging.create_message(conversation, user, %{body: "", image_ids: [sent.id]})

      age!(DmImage, old.id)
      age!(DmImage, sent.id)
      {:ok, old_path} = Files.image_path("dm_images", old.filename)

      assert Messaging.delete_orphan_dm_images(24) == 1

      refute Repo.get(DmImage, old.id)
      refute File.exists?(old_path)
      assert Repo.get(DmImage, recent.id)
      assert Repo.get(DmImage, sent.id)
    end
  end

  defp age!(schema, id) do
    long_ago = DateTime.utc_now() |> DateTime.add(-3, :day) |> DateTime.truncate(:second)
    Repo.update_all(from(i in schema, where: i.id == ^id), set: [inserted_at: long_ago])
  end

  defp member do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "sweep#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.update_all(from(u in Setup.User, where: u.id == ^user.id), set: [status: "active"])
    user |> Repo.reload() |> Repo.preload(:role)
  end
end
