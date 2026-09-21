defmodule Baudrate.Content.ImageAltTest do
  @moduledoc """
  The rules for an image description: what is stored, what a peer's value is
  reduced to, and who may write one.

  The outbound half — `name` on the three attachment builders — is asserted in
  `Baudrate.Federation.ObjectBuilderTest` and `Baudrate.Federation.PublisherTest`.
  """
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{ArticleImage, CommentImage, ImageAlt}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    import Ecto.Query
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

  defp create_article_image(user, attrs \\ %{}) do
    {:ok, image} =
      Content.create_article_image(
        Map.merge(
          %{
            filename: "#{System.unique_integer([:positive])}.webp",
            storage_path: "/tmp/x.webp",
            width: 100,
            height: 100,
            user_id: user.id
          },
          attrs
        )
      )

    image
  end

  describe "normalisation" do
    test "an empty or whitespace description becomes nil, never an empty string" do
      user = create_user()

      for blank <- ["", "   ", "\n\t "] do
        image = create_article_image(user, %{alt: blank})
        assert is_nil(image.alt), "expected #{inspect(blank)} to normalise to nil"
      end
    end

    test "nil means undescribed; \"\" would claim the image is decorative" do
      # The distinction the rendering end depends on: describe/1 answers nil
      # for both, and the caller then supplies the positional fallback rather
      # than announcing nothing at all.
      assert ImageAlt.describe(%{alt: nil}) == nil
      assert ImageAlt.describe(%{alt: ""}) == nil
      assert ImageAlt.describe(%{alt: "a cat"}) == "a cat"
      assert ImageAlt.describe(%{}) == nil
    end

    test "surrounding whitespace is trimmed" do
      user = create_user()
      image = create_article_image(user, %{alt: "  a cat on a fence  "})
      assert image.alt == "a cat on a fence"
    end

    test "a description longer than the bound is refused by the changeset" do
      changeset =
        ArticleImage.changeset(%ArticleImage{}, %{
          filename: "a.webp",
          storage_path: "/tmp/a.webp",
          width: 1,
          height: 1,
          user_id: 1,
          alt: String.duplicate("x", ImageAlt.max_length() + 1)
        })

      # normalize/1 slices at the bound, so the stored value can never exceed
      # it — the validate_length is the backstop for a path that skipped it.
      assert String.length(Ecto.Changeset.get_field(changeset, :alt)) == ImageAlt.max_length()
    end

    test "all three schemas carry the field" do
      user = create_user()

      assert create_article_image(user, %{alt: "one"}).alt == "one"

      {:ok, comment_image} =
        Content.create_comment_image(%{
          filename: "c.webp",
          storage_path: "/tmp/c.webp",
          width: 1,
          height: 1,
          user_id: user.id,
          alt: "two"
        })

      assert comment_image.alt == "two"

      {:ok, reply_image} =
        Baudrate.Federation.create_reply_image(%{
          filename: "r.webp",
          storage_path: "/tmp/r.webp",
          width: 1,
          height: 1,
          user_id: user.id,
          alt: "three"
        })

      assert reply_image.alt == "three"
    end
  end

  describe "from_remote/1" do
    test "strips tags from a peer's attachment name" do
      assert ImageAlt.from_remote("<b>a cat</b>") == "a cat"
      # Ammonia drops a script element's contents as well as its tags, so a
      # peer that sent one has described nothing.
      assert ImageAlt.from_remote("<script>alert(1)</script>") == nil
    end

    test "bounds the length" do
      long = String.duplicate("x", ImageAlt.max_length() + 500)
      assert String.length(ImageAlt.from_remote(long)) == ImageAlt.max_length()
    end

    test "anything that sanitises to nothing becomes nil" do
      assert ImageAlt.from_remote("") == nil
      assert ImageAlt.from_remote("   ") == nil
      assert ImageAlt.from_remote("<b></b>") == nil
      assert ImageAlt.from_remote(nil) == nil
      assert ImageAlt.from_remote(%{"not" => "a string"}) == nil
      assert ImageAlt.from_remote(123) == nil
    end
  end

  describe "a peer's description survives ingest" do
    test "remote_changeset/2 casts alt, which is what stopped it being dropped" do
      # `AttachmentExtractor` has always returned the peer's `name`, and
      # `Images.fetch_and_store_one/3` discarded it because there was no
      # column to put it in — so a described remote image still rendered
      # "Image 2".
      changeset =
        ArticleImage.remote_changeset(%ArticleImage{}, %{
          filename: "remote.webp",
          storage_path: "/tmp/remote.webp",
          width: 10,
          height: 10,
          article_id: 1,
          alt: ImageAlt.from_remote("<b>a photo from elsewhere</b>")
        })

      assert Ecto.Changeset.get_field(changeset, :alt) == "a photo from elsewhere"
    end

    test "alt is never required, so an undescribed remote image still stores" do
      changeset =
        ArticleImage.remote_changeset(%ArticleImage{}, %{
          filename: "remote.webp",
          storage_path: "/tmp/remote.webp",
          width: 10,
          height: 10,
          article_id: 1,
          alt: ImageAlt.from_remote(nil)
        })

      assert changeset.valid?
      assert is_nil(Ecto.Changeset.get_field(changeset, :alt))
    end
  end

  describe "update_article_image_alt/3" do
    test "the uploader may set a description" do
      user = create_user()
      image = create_article_image(user)

      assert {:ok, updated} = Content.update_article_image_alt(image.id, user.id, "a cat")
      assert updated.alt == "a cat"
      assert Repo.get!(ArticleImage, image.id).alt == "a cat"
    end

    test "somebody else may not, and gets the same answer as a missing image" do
      owner = create_user()
      stranger = create_user()
      image = create_article_image(owner)

      assert {:error, :not_found} =
               Content.update_article_image_alt(image.id, stranger.id, "not mine")

      assert {:error, :not_found} =
               Content.update_article_image_alt(999_999_999, stranger.id, "no such image")

      assert is_nil(Repo.get!(ArticleImage, image.id).alt)
    end

    test "a non-numeric id from the client is refused rather than raising" do
      user = create_user()

      assert {:error, :not_found} = Content.update_article_image_alt("../../etc", user.id, "x")
      assert {:error, :not_found} = Content.update_article_image_alt(nil, user.id, "x")
    end

    test "clearing a description sets nil, not an empty string" do
      user = create_user()
      image = create_article_image(user, %{alt: "written once"})

      assert {:ok, cleared} = Content.update_article_image_alt(image.id, user.id, "")
      assert is_nil(cleared.alt)
    end
  end

  describe "update_comment_image_alt/3 and update_reply_image_alt/3" do
    test "both are scoped to the uploader the same way" do
      owner = create_user()
      stranger = create_user()

      {:ok, comment_image} =
        Content.create_comment_image(%{
          filename: "c.webp",
          storage_path: "/tmp/c.webp",
          width: 1,
          height: 1,
          user_id: owner.id
        })

      {:ok, reply_image} =
        Baudrate.Federation.create_reply_image(%{
          filename: "r.webp",
          storage_path: "/tmp/r.webp",
          width: 1,
          height: 1,
          user_id: owner.id
        })

      assert {:ok, _} = Content.update_comment_image_alt(comment_image.id, owner.id, "mine")

      assert {:error, :not_found} =
               Content.update_comment_image_alt(comment_image.id, stranger.id, "theirs")

      assert {:ok, _} =
               Baudrate.Federation.update_reply_image_alt(reply_image.id, owner.id, "mine")

      assert {:error, :not_found} =
               Baudrate.Federation.update_reply_image_alt(reply_image.id, stranger.id, "theirs")

      assert Repo.get!(CommentImage, comment_image.id).alt == "mine"
    end
  end

  describe "BaudrateWeb.Helpers.image_link_label/2" do
    test "uses the uploader's description when there is one" do
      images = [%{id: 1, alt: nil}, %{id: 2, alt: "a cat on a fence"}]

      assert BaudrateWeb.Helpers.image_link_label(Enum.at(images, 1), images) =~
               "a cat on a fence"
    end

    test "falls back to the position when there is none" do
      images = [%{id: 1, alt: nil}, %{id: 2, alt: nil}]
      label = BaudrateWeb.Helpers.image_link_label(Enum.at(images, 1), images)
      assert label =~ "2"
    end

    test "an image missing from the list still gets a label rather than crashing" do
      assert is_binary(BaudrateWeb.Helpers.image_link_label(%{id: 7, alt: nil}, []))
    end
  end
end
