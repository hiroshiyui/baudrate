defmodule Baudrate.Federation.TimelineItemTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Federation.TimelineItem
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Repo

  setup do
    uid = System.unique_integer([:positive])

    {:ok, actor} =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/test-#{uid}",
        username: "test_#{uid}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/test-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {:ok, actor: actor}
  end

  describe "changeset/2" do
    test "valid changeset with required fields", %{actor: actor} do
      attrs = %{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/1",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = TimelineItem.changeset(%TimelineItem{}, attrs)
      assert changeset.valid?
    end

    test "valid changeset with all fields", %{actor: actor} do
      attrs = %{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Article",
        ap_id: "https://remote.example/articles/1",
        title: "Test Article",
        body: "Some content",
        body_html: "<p>Some content</p>",
        source_url: "https://remote.example/articles/1",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = TimelineItem.changeset(%TimelineItem{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = TimelineItem.changeset(%TimelineItem{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert errors[:remote_actor_id]
      assert errors[:ap_id]
      assert errors[:published_at]
    end

    test "invalid activity_type", %{actor: actor} do
      attrs = %{
        remote_actor_id: actor.id,
        activity_type: "Like",
        object_type: "Note",
        ap_id: "https://remote.example/notes/bad",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = TimelineItem.changeset(%TimelineItem{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:activity_type]
    end

    test "invalid object_type", %{actor: actor} do
      attrs = %{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Event",
        ap_id: "https://remote.example/notes/bad2",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = TimelineItem.changeset(%TimelineItem{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:object_type]
    end

    test "body length validation", %{actor: actor} do
      long_body = String.duplicate("x", 65_537)

      attrs = %{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/long",
        body: long_body,
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = TimelineItem.changeset(%TimelineItem{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:body]
    end

    test "title length validation", %{actor: actor} do
      # The title is the remote object's `name` verbatim; unlike `content` it
      # never passes through Validator.validate_content_size/1, so this is the
      # only bound on it.
      attrs = %{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Article",
        ap_id: "https://remote.example/articles/long-title",
        title: String.duplicate("x", 256),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = TimelineItem.changeset(%TimelineItem{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:title]

      assert TimelineItem.changeset(%TimelineItem{}, %{attrs | title: String.duplicate("x", 255)}).valid?
    end

    test "unique ap_id constraint", %{actor: actor} do
      attrs = %{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/unique-test",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      {:ok, _} = %TimelineItem{} |> TimelineItem.changeset(attrs) |> Repo.insert()
      {:error, changeset} = %TimelineItem{} |> TimelineItem.changeset(attrs) |> Repo.insert()

      refute changeset.valid?
      assert errors_on(changeset)[:ap_id]
    end

    test "accepts Announce activity_type with boosted_by_actor_id", %{actor: actor} do
      {:ok, booster} =
        %RemoteActor{}
        |> RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/booster-#{System.unique_integer([:positive])}",
          username: "booster_#{System.unique_integer([:positive])}",
          domain: "remote.example",
          public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
          inbox: "https://remote.example/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      attrs = %{
        remote_actor_id: actor.id,
        boosted_by_actor_id: booster.id,
        activity_type: "Announce",
        object_type: "Note",
        ap_id: "https://remote.example/activities/announce-1",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = TimelineItem.changeset(%TimelineItem{}, attrs)
      assert changeset.valid?
    end

    test "accepts Page object_type", %{actor: actor} do
      attrs = %{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Page",
        ap_id: "https://remote.example/pages/1",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = TimelineItem.changeset(%TimelineItem{}, attrs)
      assert changeset.valid?
    end
  end
end
