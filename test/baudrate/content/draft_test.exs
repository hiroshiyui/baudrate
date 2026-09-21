defmodule Baudrate.Content.DraftTest do
  @moduledoc """
  The acceptance gate for server-side drafts.

  A draft is private writing that is not content: scoped to its owner on every
  read, capped by a count rather than a column, and holding images that the
  orphan sweep must not take out from under it.
  """
  use Baudrate.DataCase

  alias Baudrate.Content
  alias Baudrate.Content.{ArticleImage, Drafts}
  alias Baudrate.Repo

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    {:ok, user: create_user(), other: create_user()}
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "drafter_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  describe "ownership" do
    test "another member's draft is indistinguishable from one that never existed", %{
      user: user,
      other: other
    } do
      {:ok, draft} = Drafts.save(user.id, %{"title" => "Mine", "body" => "private"})

      # Not {:error, :unauthorized}: a refusal that can be told apart from a
      # miss tells a stranger how many drafts somebody has.
      assert Drafts.get(other.id, draft.id) == nil
      assert Drafts.get(other.id, 999_999) == nil
    end

    test "saving with another member's draft id creates a new draft instead of writing theirs",
         %{user: user, other: other} do
      {:ok, theirs} = Drafts.save(user.id, %{"title" => "Theirs", "body" => "original"})

      {:ok, mine} =
        Drafts.save(other.id, %{"title" => "Hijack", "body" => "overwritten"}, theirs.id)

      refute mine.id == theirs.id
      assert mine.user_id == other.id
      assert Repo.reload(theirs).body == "original"
    end

    test "deleting another member's draft does nothing", %{user: user, other: other} do
      {:ok, draft} = Drafts.save(user.id, %{"title" => "Mine", "body" => "still here"})

      assert :ok = Drafts.delete(other.id, draft.id)
      assert Repo.reload(draft)
    end

    test "user_id is never castable, so params cannot name another owner", %{
      user: user,
      other: other
    } do
      {:ok, draft} =
        Drafts.save(user.id, %{"title" => "T", "body" => "B", "user_id" => other.id})

      assert draft.user_id == user.id
    end

    test "listing returns only the member's own", %{user: user, other: other} do
      {:ok, _} = Drafts.save(user.id, %{"title" => "Mine", "body" => "a"})
      {:ok, _} = Drafts.save(other.id, %{"title" => "Theirs", "body" => "b"})

      assert [%{title: "Mine"}] = Drafts.list(user.id)
    end
  end

  describe "the cap" do
    test "refuses a new draft past the limit but keeps updating existing ones", %{user: user} do
      drafts =
        for n <- 1..Drafts.max_drafts() do
          {:ok, d} = Drafts.save(user.id, %{"title" => "draft #{n}", "body" => "b"})
          d
        end

      assert Drafts.quota_remaining(user.id) == 0

      assert {:error, :quota_exceeded} =
               Drafts.save(user.id, %{"title" => "one more", "body" => "b"})

      # The member at the cap can still write: the composer they have open
      # keeps saving into the row it already holds.
      first = hd(drafts)
      assert {:ok, updated} = Drafts.save(user.id, %{"body" => "still typing"}, first.id)
      assert updated.body == "still typing"
    end

    test "deleting one makes room again", %{user: user} do
      for n <- 1..Drafts.max_drafts() do
        {:ok, _} = Drafts.save(user.id, %{"title" => "d#{n}", "body" => "b"})
      end

      [%{id: id} | _] = Drafts.list(user.id)
      :ok = Drafts.delete(user.id, id)

      assert Drafts.quota_remaining(user.id) == 1
      assert {:ok, _} = Drafts.save(user.id, %{"title" => "room", "body" => "b"})
    end

    test "one member's drafts do not count against another's", %{user: user, other: other} do
      for n <- 1..Drafts.max_drafts() do
        {:ok, _} = Drafts.save(user.id, %{"title" => "d#{n}", "body" => "b"})
      end

      assert Drafts.quota_remaining(other.id) == Drafts.max_drafts()
      assert {:ok, _} = Drafts.save(other.id, %{"title" => "fine", "body" => "b"})
    end
  end

  describe "bounds" do
    test "a body over 64 KB is refused, matching Article", %{user: user} do
      too_long = String.duplicate("a", 65_537)

      assert {:error, changeset} = Drafts.save(user.id, %{"title" => "T", "body" => too_long})
      assert %{body: [_ | _]} = errors_on(changeset)
    end

    test "a visibility local articles do not accept is refused", %{user: user} do
      assert {:error, changeset} =
               Drafts.save(user.id, %{"title" => "T", "body" => "B", "visibility" => "direct"})

      assert %{visibility: [_ | _]} = errors_on(changeset)
    end

    test "an absurd number of poll options is refused", %{user: user} do
      assert {:error, changeset} =
               Drafts.save(user.id, %{
                 "title" => "T",
                 "body" => "B",
                 "poll_options" => for(n <- 1..40, do: "option #{n}")
               })

      assert %{poll_options: [_ | _]} = errors_on(changeset)
    end
  end

  describe "what a fresh composer restores" do
    test "the most recently saved draft", %{user: user} do
      {:ok, _older} = Drafts.save(user.id, %{"title" => "older", "body" => "a"})
      {:ok, newer} = Drafts.save(user.id, %{"title" => "newer", "body" => "b"})

      # `updated_at` has second resolution, so set it explicitly rather than
      # sleeping — a tie would make this test nondeterministic.
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(d in Baudrate.Content.ArticleDraft, where: d.title == "older"),
        set: [updated_at: past]
      )

      assert Drafts.latest(user.id).id == newer.id
    end

    test "nothing, when the only draft is empty", %{user: user} do
      {:ok, _} = Drafts.save(user.id, %{"title" => "", "body" => "", "visibility" => "public"})

      # An empty row is the residue of opening the composer and closing it.
      # Putting it back in front of somebody would read as a bug.
      assert Drafts.latest(user.id) == nil
    end

    test "nothing at all for a member with no drafts", %{user: user} do
      assert Drafts.latest(user.id) == nil
    end
  end

  describe "images a draft is holding" do
    setup %{user: user} do
      # A real filename: `Images.image_paths/1` rebuilds the path from it via
      # `DataPortability.Files`, which refuses anything that is not 64 hex
      # characters — so a made-up name would silently return no paths and the
      # sweep's file half would go untested.
      filename = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower) <> ".webp"

      {:ok, image} =
        %ArticleImage{}
        |> ArticleImage.changeset(%{
          filename: filename,
          storage_path: "/tmp/" <> filename,
          width: 10,
          height: 10,
          user_id: user.id
        })
        |> Repo.insert()

      {:ok, image: image}
    end

    test "are not swept as orphans", %{user: user, image: image} do
      {:ok, _draft} =
        Drafts.save(user.id, %{
          "title" => "with a picture",
          "body" => "b",
          "image_ids" => [image.id]
        })

      age_image(image, -2)

      Content.delete_orphan_article_images(DateTime.utc_now() |> DateTime.add(-86_400, :second))

      assert Repo.reload(image), "a draft's image was deleted out from under it"
    end

    test "are swept once the draft is gone", %{user: user, image: image} do
      {:ok, draft} =
        Drafts.save(user.id, %{
          "title" => "with a picture",
          "body" => "b",
          "image_ids" => [image.id]
        })

      age_image(image, -2)
      :ok = Drafts.delete(user.id, draft.id)

      Content.delete_orphan_article_images(DateTime.utc_now() |> DateTime.add(-86_400, :second))

      refute Repo.reload(image)
    end

    test "one sweep spares the held image and takes the unheld one", %{
      user: user,
      image: held
    } do
      # The select that collects file paths and the delete that removes rows
      # are two queries. If they ever disagree about what an orphan is, the
      # files of spared images are unlinked while their rows stay — so the
      # case that matters is both kinds of image in a single call.
      unheld = insert_orphan_image(user)

      {:ok, _} =
        Drafts.save(user.id, %{"title" => "T", "body" => "B", "image_ids" => [held.id]})

      age_image(held, -2)
      age_image(unheld, -2)

      Content.delete_orphan_article_images(DateTime.utc_now() |> DateTime.add(-86_400, :second))

      assert Repo.reload(held)
      refute Repo.reload(unheld)
    end

    test "held_image_ids/0 reports every draft's images", %{user: user, image: image} do
      {:ok, _} = Drafts.save(user.id, %{"title" => "T", "body" => "B", "image_ids" => [image.id]})

      assert image.id in Drafts.held_image_ids()
    end
  end

  describe "the stale purge" do
    test "removes an untouched draft and leaves a recent one", %{user: user} do
      {:ok, old} = Drafts.save(user.id, %{"title" => "abandoned", "body" => "b"})
      {:ok, recent} = Drafts.save(user.id, %{"title" => "current", "body" => "b"})

      long_ago =
        DateTime.utc_now()
        |> DateTime.add(-(Drafts.stale_after_days() + 1) * 86_400, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(from(d in Baudrate.Content.ArticleDraft, where: d.id == ^old.id),
        set: [updated_at: long_ago]
      )

      assert Drafts.purge_stale() == 1
      refute Repo.reload(old)
      assert Repo.reload(recent)
    end
  end

  describe "deleting the account" do
    test "takes the drafts with it", %{user: user} do
      {:ok, draft} = Drafts.save(user.id, %{"title" => "T", "body" => "B"})

      Repo.delete!(user)

      refute Repo.reload(draft)
    end
  end

  defp insert_orphan_image(user) do
    filename = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower) <> ".webp"

    {:ok, image} =
      %ArticleImage{}
      |> ArticleImage.changeset(%{
        filename: filename,
        storage_path: "/tmp/" <> filename,
        width: 10,
        height: 10,
        user_id: user.id
      })
      |> Repo.insert()

    image
  end

  defp age_image(image, days) do
    at =
      DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(i in ArticleImage, where: i.id == ^image.id), set: [inserted_at: at])
  end
end
