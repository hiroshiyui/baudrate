defmodule Baudrate.Federation.InboxHandlerPollTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation
  alias Baudrate.Federation.{InboxHandler, KeyStore, RemoteActor}

  setup do
    Baudrate.Setup.seed_roles_and_permissions()
    :ok
  end

  defp create_user do
    role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Baudrate.Setup.User{}
      |> Baudrate.Setup.User.registration_changeset(%{
        "username" => "inbox_poll_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Repo.preload(user, :role)
  end

  defp create_board do
    slug = "inbox-poll-#{System.unique_integer([:positive])}"

    board =
      %Board{}
      |> Board.changeset(%{
        name: "Inbox Poll Board",
        slug: slug,
        ap_enabled: true,
        min_role_to_view: "guest",
        ap_accept_policy: "open"
      })
      |> Repo.insert!()

    {:ok, board} = KeyStore.ensure_board_keypair(board)
    board
  end

  defp create_remote_actor do
    unique = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/actor_#{unique}",
      username: "actor_#{unique}",
      domain: "remote.example",
      display_name: "Remote Actor #{unique}",
      inbox: "https://remote.example/users/actor_#{unique}/inbox",
      shared_inbox: "https://remote.example/inbox",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A\n-----END PUBLIC KEY-----",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  describe "Create(Question) — inbound poll" do
    test "creates article with poll from Question object" do
      board = create_board()
      remote_actor = create_remote_actor()
      ap_id = "https://remote.example/articles/poll-#{System.unique_integer([:positive])}"
      board_uri = Federation.actor_uri(:board, board.slug)

      activity = %{
        "type" => "Create",
        "id" => "#{ap_id}#create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Question",
          "id" => ap_id,
          "name" => "What do you prefer?",
          "content" => "<p>Choose one</p>",
          "attributedTo" => remote_actor.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [board_uri],
          "audience" => [board_uri],
          "oneOf" => [
            %{"type" => "Note", "name" => "Cats", "replies" => %{"totalItems" => 5}},
            %{"type" => "Note", "name" => "Dogs", "replies" => %{"totalItems" => 3}}
          ],
          "votersCount" => 8,
          "endTime" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 86400, :second))
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      article = Content.get_article_by_ap_id(ap_id)
      assert article != nil
      assert article.title == "What do you prefer?"

      poll = Content.get_poll_for_article(article.id)
      assert poll != nil
      assert poll.mode == "single"
      assert poll.voters_count == 8
      assert poll.closes_at != nil
      assert length(poll.options) == 2

      cats = Enum.find(poll.options, &(&1.text == "Cats"))
      assert cats.votes_count == 5
    end
  end

  describe "vote Notes — inbound poll votes" do
    test "records vote from remote actor" do
      user = create_user()
      board = create_board()
      remote_actor = create_remote_actor()

      slug = "vote-target-#{System.unique_integer([:positive])}"

      {:ok, %{article: article, poll: _poll}} =
        Content.create_article(
          %{title: "Vote Target", body: "Body", slug: slug, user_id: user.id},
          [board.id],
          poll: %{
            mode: "single",
            options: [
              %{text: "Option 1", position: 0},
              %{text: "Option 2", position: 1}
            ]
          }
        )

      article_uri = Federation.actor_uri(:article, article.slug)

      activity = %{
        "type" => "Create",
        "id" => "#{remote_actor.ap_id}#vote-#{System.unique_integer([:positive])}",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Note",
          "id" => "#{remote_actor.ap_id}#vote-note-#{System.unique_integer([:positive])}",
          "name" => "Option 1",
          "inReplyTo" => article_uri,
          "attributedTo" => remote_actor.ap_id,
          "to" => [Federation.actor_uri(:user, user.username)]
        }
      }

      assert :ok = InboxHandler.handle(activity, remote_actor, :shared)

      # Check that the vote was recorded
      updated_poll = Content.get_poll_for_article(article.id)
      assert updated_poll.voters_count == 1
      opt1 = Enum.find(updated_poll.options, &(&1.text == "Option 1"))
      assert opt1.votes_count == 1
    end
  end

  describe "Update(Question) — poll count refresh" do
    test "updates poll counts from remote" do
      board = create_board()
      remote_actor = create_remote_actor()
      ap_id = "https://remote.example/articles/upd-poll-#{System.unique_integer([:positive])}"
      board_uri = Federation.actor_uri(:board, board.slug)

      # Create the remote article with poll
      create_activity = %{
        "type" => "Create",
        "id" => "#{ap_id}#create",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Question",
          "id" => ap_id,
          "name" => "Update Poll",
          "content" => "<p>Content</p>",
          "attributedTo" => remote_actor.ap_id,
          "to" => ["https://www.w3.org/ns/activitystreams#Public"],
          "cc" => [board_uri],
          "audience" => [board_uri],
          "oneOf" => [
            %{"type" => "Note", "name" => "X", "replies" => %{"totalItems" => 0}},
            %{"type" => "Note", "name" => "Y", "replies" => %{"totalItems" => 0}}
          ],
          "votersCount" => 0
        }
      }

      assert :ok = InboxHandler.handle(create_activity, remote_actor, :shared)

      # Now send an Update(Question) with new counts
      update_activity = %{
        "type" => "Update",
        "id" => "#{ap_id}#update",
        "actor" => remote_actor.ap_id,
        "object" => %{
          "type" => "Question",
          "id" => ap_id,
          "oneOf" => [
            %{"type" => "Note", "name" => "X", "replies" => %{"totalItems" => 10}},
            %{"type" => "Note", "name" => "Y", "replies" => %{"totalItems" => 7}}
          ],
          "votersCount" => 17
        }
      }

      assert :ok = InboxHandler.handle(update_activity, remote_actor, :shared)

      article = Content.get_article_by_ap_id(ap_id)
      poll = Content.get_poll_for_article(article.id)
      assert poll.voters_count == 17

      x_opt = Enum.find(poll.options, &(&1.text == "X"))
      y_opt = Enum.find(poll.options, &(&1.text == "Y"))
      assert x_opt.votes_count == 10
      assert y_opt.votes_count == 7
    end
  end
end
