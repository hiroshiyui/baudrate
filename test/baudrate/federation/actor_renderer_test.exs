defmodule Baudrate.Federation.ActorRendererTest do
  @moduledoc """
  These maps are the instance's public identity on the fediverse. The
  invariants that matter to interoperability — `preferredUsername` matching the
  WebFinger subject, `Group` vs `Person` typing, a resolvable `publicKey` — are
  the ones remote software rejects the actor over, usually with a 422 and no
  useful error, so they are pinned here rather than left to integration tests.
  """
  use Baudrate.DataCase, async: false

  import Ecto.Query

  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.ActorRenderer
  alias Baudrate.Federation.KeyStore
  alias Baudrate.Repo
  alias Baudrate.Setup

  @as_context "https://www.w3.org/ns/activitystreams"

  setup do
    unless Repo.exists?(from(r in Setup.Role, where: r.name == "admin")) do
      Setup.seed_roles_and_permissions()
    end

    :ok
  end

  defp create_user(role_name) do
    role = Repo.one!(from(r in Setup.Role, where: r.name == ^role_name))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "actor_render_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Repo.preload(user, :role)
  end

  defp create_board(attrs) do
    %Board{}
    |> Board.changeset(
      Map.merge(
        %{
          name: "Board #{System.unique_integer([:positive])}",
          slug: "board-#{System.unique_integer([:positive])}",
          ap_enabled: true,
          min_role_to_view: "guest"
        },
        attrs
      )
    )
    |> Repo.insert!()
    |> then(fn board ->
      {:ok, board} = KeyStore.ensure_board_keypair(board)
      board
    end)
  end

  describe "user_actor/1" do
    test "publishes alsoKnownAs and movedTo only when set (ADR 0025)" do
      user = create_user("user")
      plain = ActorRenderer.user_actor(user)
      refute Map.has_key?(plain, "alsoKnownAs")
      refute Map.has_key?(plain, "movedTo")

      moved = %{
        user
        | also_known_as: ["https://old.example/users/me"],
          moved_to: "https://new.example/users/me"
      }

      actor = ActorRenderer.user_actor(moved)
      assert actor["alsoKnownAs"] == ["https://old.example/users/me"]
      assert actor["movedTo"] == "https://new.example/users/me"
    end

    test "renders a Person whose identity fields agree with each other" do
      user = create_user("user")
      actor = ActorRenderer.user_actor(user)

      assert actor["type"] == "Person"
      assert @as_context in actor["@context"]

      # Mastodon derives its WebFinger query from preferredUsername and rejects
      # the actor outright when the subject disagrees.
      assert actor["preferredUsername"] == user.username

      uri = Federation.actor_uri(:user, user.username)
      assert actor["id"] == uri
      assert actor["inbox"] == "#{uri}/inbox"
      assert actor["outbox"] == "#{uri}/outbox"
      assert actor["followers"] == "#{uri}/followers"
      assert actor["following"] == "#{uri}/following"
      assert actor["endpoints"]["sharedInbox"] == "#{Federation.base_url()}/ap/inbox"

      assert actor["publicKey"]["id"] == "#{uri}#main-key"
      assert actor["publicKey"]["owner"] == uri
      assert actor["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "leaves publicKeyPem nil when the caller did not ensure a keypair" do
      # ActorRenderer is a pure renderer: `ActivityPubController.user_actor/2`
      # and `board_actor/2` both call `KeyStore.ensure_*_keypair/1` in their
      # `with` chain before rendering. This pins that coupling — a caller that
      # skips it serves an actor remote instances will reject.
      role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

      {:ok, keyless} =
        %Setup.User{}
        |> Setup.User.registration_changeset(%{
          "username" => "keyless_#{System.unique_integer([:positive])}",
          "password" => "Password123!x",
          "password_confirmation" => "Password123!x",
          "role_id" => role.id
        })
        |> Repo.insert()

      assert ActorRenderer.user_actor(keyless)["publicKey"]["publicKeyPem"] == nil
    end

    test "omits optional fields entirely rather than emitting nulls" do
      user = create_user("user")
      actor = ActorRenderer.user_actor(user)

      refute Map.has_key?(actor, "name")
      refute Map.has_key?(actor, "summary")
      refute Map.has_key?(actor, "icon")
      refute Map.has_key?(actor, "attachment")
    end

    test "includes display name, bio, and profile fields when set" do
      user = create_user("user")

      {:ok, user} =
        user
        |> Ecto.Changeset.change(%{
          display_name: "Alice",
          bio: "Hello #elixir\nsecond line",
          profile_fields: [%{"name" => "Site", "value" => "example.com"}]
        })
        |> Repo.update()

      actor = ActorRenderer.user_actor(user)

      assert actor["name"] == "Alice"
      # Newlines become <br> and hashtags are linkified, so the bio survives a
      # round trip through a remote renderer that only accepts HTML.
      assert actor["summary"] =~ "<br>"
      assert actor["summary"] =~ "/tags/elixir"

      assert [%{"type" => "PropertyValue", "name" => "Site", "value" => "example.com"}] =
               actor["attachment"]
    end

    test "escapes HTML in the bio and in profile field values" do
      user = create_user("user")

      {:ok, user} =
        user
        |> Ecto.Changeset.change(%{
          bio: "<script>alert(1)</script>",
          profile_fields: [%{"name" => "X", "value" => "<img src=x onerror=alert(1)>"}]
        })
        |> Repo.update()

      actor = ActorRenderer.user_actor(user)

      refute actor["summary"] =~ "<script>"
      assert actor["summary"] =~ "&lt;script&gt;"

      [%{"value" => value}] = actor["attachment"]
      refute value =~ "<img"
      assert value =~ "&lt;img"
    end

    test "drops profile fields with a blank name or value" do
      user = create_user("user")

      {:ok, user} =
        user
        |> Ecto.Changeset.change(%{
          profile_fields: [
            %{"name" => "", "value" => "orphaned"},
            %{"name" => "Empty", "value" => ""},
            %{"name" => "Kept", "value" => "yes"}
          ]
        })
        |> Repo.update()

      assert [%{"name" => "Kept"}] = ActorRenderer.user_actor(user)["attachment"]
    end
  end

  describe "board_actor/1" do
    test "renders a Group whose preferredUsername is the bare slug" do
      board = create_board(%{name: "Announcements"})
      actor = ActorRenderer.board_actor(board)

      assert actor["type"] == "Group"
      # Bare slug, no `!` prefix — Mastodon derives the WebFinger query from
      # this and 422s on a subject mismatch.
      assert actor["preferredUsername"] == board.slug
      refute String.starts_with?(actor["preferredUsername"], "!")

      assert actor["name"] == "Announcements"
      assert actor["id"] == Federation.actor_uri(:board, board.slug)
      assert actor["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "advertises only federated relatives" do
      parent = create_board(%{})
      child = create_board(%{parent_id: parent.id})
      private_child = create_board(%{parent_id: parent.id, min_role_to_view: "user"})
      _unfederated_child = create_board(%{parent_id: parent.id, ap_enabled: false})

      parent_actor = ActorRenderer.board_actor(parent)
      sub_boards = parent_actor["baudrate:subBoards"]

      assert Federation.actor_uri(:board, child.slug) in sub_boards
      # A board that is not federated has no actor to point at, and listing one
      # would advertise the existence of a non-public board.
      refute Federation.actor_uri(:board, private_child.slug) in sub_boards
      assert length(sub_boards) == 1

      assert ActorRenderer.board_actor(child)["baudrate:parentBoard"] ==
               Federation.actor_uri(:board, parent.slug)
    end

    test "omits the relation keys when there is nothing to advertise" do
      board = create_board(%{})
      actor = ActorRenderer.board_actor(board)

      refute Map.has_key?(actor, "baudrate:subBoards")
      refute Map.has_key?(actor, "baudrate:parentBoard")
    end

    test "does not name a non-federated parent" do
      parent = create_board(%{ap_enabled: false})
      child = create_board(%{parent_id: parent.id})

      refute Map.has_key?(ActorRenderer.board_actor(child), "baudrate:parentBoard")
    end
  end

  describe "site_actor/0" do
    test "renders an Organization discoverable as acct:site@host" do
      actor = ActorRenderer.site_actor()

      assert actor["type"] == "Organization"
      assert actor["preferredUsername"] == "site"
      assert actor["id"] == Federation.actor_uri(:site, nil)
      assert actor["url"] == Federation.base_url()
      assert actor["publicKey"]["publicKeyPem"] =~ "BEGIN PUBLIC KEY"
    end

    test "uses the configured site name and falls back to Baudrate" do
      assert ActorRenderer.site_actor()["name"] == "Baudrate"

      {:ok, _} = Setup.set_setting("site_name", "My BBS")
      assert ActorRenderer.site_actor()["name"] == "My BBS"
    end
  end

  describe "render_bio_html/1" do
    test "returns nil for nothing to render" do
      assert ActorRenderer.render_bio_html(nil) == nil
      assert ActorRenderer.render_bio_html("") == nil
    end

    test "escapes before linkifying, so a hashtag link is never injectable" do
      html = ActorRenderer.render_bio_html("<b>#tag</b>")
      refute html =~ "<b>"
      assert html =~ "/tags/tag"
    end
  end
end
