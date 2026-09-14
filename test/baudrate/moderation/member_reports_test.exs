defmodule Baudrate.Moderation.MemberReportsTest do
  @moduledoc """
  Members report feed items, direct messages they received, and remote
  accounts through context functions that check the reporter can see what
  they report. A message report copies that one message's text, nothing else.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.{Federation, Messaging, Moderation, Setup}
  alias Baudrate.Federation.{KeyStore, RemoteActor}
  alias Baudrate.Moderation.Report

  setup do
    Setup.seed_roles_and_permissions()
    %{user: create_user(), actor: create_remote_actor()}
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "mr_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    Repo.preload(user, :role)
  end

  defp create_remote_actor do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/mr-#{uid}",
      username: "mr_#{uid}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/mr-#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp create_feed_item(actor) do
    uid = System.unique_integer([:positive])

    {:ok, item} =
      Federation.create_feed_item(%{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/#{uid}",
        body: "Buy now",
        body_html: "<p>Buy now</p>",
        source_url: "https://remote.example/notes/#{uid}",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    item
  end

  defp follow!(user, actor) do
    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _} = Federation.accept_user_follow(follow.ap_id)
  end

  describe "report_feed_item/3" do
    test "records the item and its remote author", %{user: user, actor: actor} do
      follow!(user, actor)
      item = create_feed_item(actor)

      assert {:ok, %Report{} = report} =
               Moderation.report_feed_item(user, to_string(item.id), "Spam")

      assert report.feed_item_id == item.id
      assert report.remote_actor_id == actor.id
      assert report.reporter_id == user.id
    end

    test "refuses an item outside the reporter's feed", %{user: user, actor: actor} do
      item = create_feed_item(actor)
      assert {:error, :not_found} = Moderation.report_feed_item(user, item.id, "Spam")
      assert {:error, :not_found} = Moderation.report_feed_item(user, "nope", "Spam")
    end

    test "refuses a second open report of the same item", %{user: user, actor: actor} do
      follow!(user, actor)
      item = create_feed_item(actor)

      assert {:ok, _} = Moderation.report_feed_item(user, item.id, "Spam")
      assert {:error, :already_reported} = Moderation.report_feed_item(user, item.id, "Again")
    end
  end

  describe "report_message/3" do
    setup %{user: user} do
      sender = create_user()
      {:ok, conversation} = Messaging.find_or_create_conversation(sender, user)
      {:ok, message} = Messaging.create_message(conversation, sender, %{"body" => "You again"})

      %{sender: sender, conversation: conversation, message: message}
    end

    test "copies only the reported message and names its sender",
         %{user: user, sender: sender, conversation: conversation, message: message} do
      {:ok, _other} = Messaging.create_message(conversation, sender, %{"body" => "Unreported"})

      assert {:ok, report} = Moderation.report_message(user, to_string(message.id), "Harassment")

      assert report.message_id == message.id
      assert report.message_body == "You again"
      assert report.reported_user_id == sender.id
      assert is_nil(report.remote_actor_id)
    end

    test "keeps the copy after the sender deletes the message",
         %{user: user, sender: sender, message: message} do
      {:ok, report} = Moderation.report_message(user, message.id, "Harassment")
      {:ok, _} = Messaging.soft_delete_message(message, sender)

      assert Repo.reload!(report).message_body == "You again"
    end

    test "refuses the sender, outsiders, and deleted messages",
         %{user: user, sender: sender, message: message} do
      assert {:error, :not_found} = Moderation.report_message(sender, message.id, "Mine")
      assert {:error, :not_found} = Moderation.report_message(create_user(), message.id, "x")

      {:ok, _} = Messaging.soft_delete_message(message, sender)
      assert {:error, :not_found} = Moderation.report_message(user, message.id, "Gone")
    end

    test "records a remote sender as the reported actor", %{user: user, actor: actor} do
      {:ok, message} =
        Messaging.receive_remote_dm(user, actor, %{
          body: "Remote hello",
          body_html: "<p>Remote hello</p>",
          ap_id: "https://remote.example/dms/#{System.unique_integer([:positive])}"
        })

      assert {:ok, report} = Moderation.report_message(user, message.id, "Spam")
      assert report.remote_actor_id == actor.id
      assert is_nil(report.reported_user_id)
      assert report.message_body == "Remote hello"
    end

    test "message_body cannot be set through report attributes", %{user: user, actor: actor} do
      {:ok, report} =
        Moderation.create_report(%{
          reason: "x",
          reporter_id: user.id,
          remote_actor_id: actor.id,
          message_body: "forged"
        })

      assert is_nil(report.message_body)
    end
  end

  describe "report_remote_actor/3" do
    test "reports the account", %{user: user, actor: actor} do
      assert {:ok, report} = Moderation.report_remote_actor(user, actor.id, "Impersonation")
      assert report.remote_actor_id == actor.id
      assert is_nil(report.feed_item_id)
    end

    test "refuses an unknown actor", %{user: user} do
      assert {:error, :not_found} = Moderation.report_remote_actor(user, -1, "x")
    end

    test "a report about one of the account's posts is not a report about the account",
         %{user: user, actor: actor} do
      follow!(user, actor)
      item = create_feed_item(actor)

      assert {:ok, _} = Moderation.report_feed_item(user, item.id, "Spam")
      assert {:ok, _} = Moderation.report_remote_actor(user, actor.id, "Spam account")

      assert {:error, :already_reported} =
               Moderation.report_remote_actor(user, actor.id, "Again")
    end
  end

  test "a feed item report appears in the queue with its author",
       %{user: user, actor: actor} do
    follow!(user, actor)
    item = create_feed_item(actor)

    {:ok, report} = Moderation.report_feed_item(user, item.id, "Spam")

    assert [%{id: id, feed_item: %{remote_actor: %RemoteActor{}}}] =
             Moderation.list_reports(status: "open")

    assert id == report.id
  end
end
