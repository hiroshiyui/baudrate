defmodule Baudrate.Messaging.DmPrivacyTest do
  @moduledoc """
  Acceptance gate for [ADR 0071](../../../doc/adr/0071-a-direct-message-stays-between-the-two-people-in-it.md):
  a direct message stays between the two people in it — its push carries no
  text, its images are readable only by them (and by a moderator for a
  reported message), they never leave this instance, a search reaches only
  the member's own conversations, and deleting a message takes its images
  with it.
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Messaging
  alias Baudrate.Messaging.{DmImage, Images, Push}
  alias Baudrate.Notification.{Notification, WebPush}
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    alice = setup_user("user")
    bob = setup_user("user")
    {:ok, conversation} = Messaging.find_or_create_conversation(alice, bob)

    png = Path.join(System.tmp_dir!(), "dm-#{System.unique_integer([:positive])}.png")
    {:ok, img} = Image.new(64, 64, color: [200, 50, 50])
    Image.write!(img, png)
    on_exit(fn -> File.rm(png) end)

    %{alice: alice, bob: bob, conversation: conversation, png: png}
  end

  describe "a push about a direct message" do
    test "names the sender and carries no text", %{alice: alice, bob: bob, conversation: c} do
      payload = WebPush.build_dm_payload(bob, alice, c.id)

      assert payload.body == ""
      assert payload.title =~ BaudrateWeb.Helpers.display_name(alice)
      assert payload.url =~ "/messages/#{c.id}"
      assert payload.type == "dm-#{c.id}"
    end

    test "is one notice, never a row on /notifications", ctx do
      {:ok, _} = Messaging.create_message(ctx.conversation, ctx.alice, %{body: "secret words"})
      assert Repo.aggregate(Notification, :count) == 0
    end

    test "is not sent for a muted sender, or when switched off", %{alice: alice, bob: bob} do
      assert Push.wanted?(bob, alice)

      {:ok, _} = Baudrate.Auth.mute_user(bob, alice)
      refute Push.wanted?(Repo.reload(bob), alice)

      carol = setup_user("user")

      {:ok, carol} =
        Baudrate.Auth.update_notification_preferences(carol, %{
          "direct_message" => %{"web_push" => false}
        })

      refute Push.wanted?(carol, alice)
    end
  end

  describe "images are private" do
    setup ctx do
      {:ok, image} = Messaging.create_dm_image(ctx.alice, ctx.png)

      {:ok, message} =
        Messaging.create_message(ctx.conversation, ctx.alice, %{body: "", image_ids: [image.id]})

      %{image: Repo.reload(image), message: message}
    end

    test "both participants can open the image", ctx do
      for user <- [ctx.alice, ctx.bob] do
        conn = ctx.conn |> log_in_user(user) |> get("/messages/images/#{ctx.image.id}")
        assert conn.status == 200
        assert get_resp_header(conn, "cache-control") == ["private, no-store"]
        assert get_resp_header(conn, "content-type") == ["image/webp"]
      end
    end

    test "a guest, a stranger and a moderator with no open report get 404", ctx do
      assert get(build_conn(), "/messages/images/#{ctx.image.id}").status == 404

      stranger = build_conn() |> log_in_user(setup_user("user"))
      assert get(stranger, "/messages/images/#{ctx.image.id}").status == 404

      moderator = build_conn() |> log_in_user(setup_user("moderator"))
      assert get(moderator, "/messages/images/#{ctx.image.id}").status == 404
    end

    test "a moderator sees the image of a message an open report names", ctx do
      {:ok, _report} =
        Baudrate.Moderation.report_message(ctx.bob, ctx.message.id, %{
          reason: "unwanted",
          category: "harassment"
        })

      moderator = build_conn() |> log_in_user(setup_user("moderator"))

      assert get(moderator, "/messages/images/#{ctx.image.id}").status == 200
    end

    test "nothing is served by its path under /uploads", ctx do
      conn = get(build_conn(), "/uploads/dm_images/#{ctx.image.filename}")
      assert conn.status == 404
    end

    # The shipped nginx configs refuse the directory too, ahead of the
    # /uploads/ alias that would otherwise serve it.
    test "both nginx configs deny the directory before serving uploads" do
      for path <- [
            "ansible/roles/nginx/templates/baudrate.conf.j2",
            "doc/examples/nginx.conf.example"
          ] do
        conf = File.read!(path)
        {deny, _} = :binary.match(conf, "location ^~ /uploads/dm_images/ {")
        {uploads, _} = :binary.match(conf, "location /uploads/ {")
        assert deny < uploads, "#{path} must deny /uploads/dm_images/ before /uploads/"
      end
    end

    test "the conversation never shows the filename", ctx do
      {:ok, _lv, html} =
        ctx.conn |> log_in_user(ctx.bob) |> live("/messages/#{ctx.conversation.id}")

      assert html =~ "/messages/images/#{ctx.image.id}"
      refute html =~ ctx.image.filename
    end

    test "deleting the message deletes the image and its file", ctx do
      {:ok, path} = Baudrate.DataPortability.Files.image_path("dm_images", ctx.image.filename)
      assert File.exists?(path)

      {:ok, _} = Messaging.soft_delete_message(ctx.message, ctx.alice)

      refute Repo.get(DmImage, ctx.image.id)
      refute File.exists?(path)
      conn = ctx.conn |> log_in_user(ctx.bob) |> get("/messages/images/#{ctx.image.id}")
      assert conn.status == 404
    end

    test "an unsent upload is visible to its uploader only", ctx do
      {:ok, draft} = Messaging.create_dm_image(ctx.alice, ctx.png)

      assert {:ok, _, _} = Messaging.accessible_dm_image(ctx.alice, draft.id)
      assert :error = Messaging.accessible_dm_image(ctx.bob, draft.id)
    end
  end

  describe "images stay on this instance" do
    test "a conversation with another server refuses them", ctx do
      remote =
        %Baudrate.Federation.RemoteActor{}
        |> Baudrate.Federation.RemoteActor.changeset(%{
          ap_id: "https://remote.example/users/r#{System.unique_integer([:positive])}",
          username: "r",
          domain: "remote.example",
          public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
          inbox: "https://remote.example/inbox",
          actor_type: "Person",
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert!()

      {:ok, conversation} = Messaging.find_or_create_remote_conversation(ctx.alice, remote)
      {:ok, image} = Messaging.create_dm_image(ctx.alice, ctx.png)

      assert {:error, :dm_images_local_only} =
               Messaging.create_message(conversation, ctx.alice, %{
                 body: "look",
                 image_ids: [image.id]
               })
    end
  end

  describe "uploads are rationed before they are processed" do
    setup do
      BaudrateWeb.RateLimiter.Sandbox.set_fun(&BaudrateWeb.RateLimiter.Hammer.check_rate/3)
      BaudrateWeb.RateLimit.reset_all()
      :ok
    end

    # A path that does not exist would fail in the processor; a refusal that
    # names the limit proves the processor was never called.
    test "the hourly limit refuses without processing", %{alice: alice, png: png} do
      for _ <- 1..4 do
        {:ok, image} = Messaging.create_dm_image(alice, png)
        Repo.update_all(from(i in DmImage, where: i.id == ^image.id), set: [message_id: nil])
        :ok = Messaging.delete_unsent_dm_image(alice, image.id)
      end

      for _ <- 5..20 do
        BaudrateWeb.RateLimits.check_dm_image_upload(alice.id, true)
      end

      assert {:error, :rate_limited} = Messaging.create_dm_image(alice, "/nonexistent.png")
    end

    test "no more than #{Images.max_pending()} unsent images at once", %{alice: alice, png: png} do
      for _ <- 1..Images.max_pending(), do: {:ok, _} = Messaging.create_dm_image(alice, png)

      assert {:error, :too_many_pending} = Messaging.create_dm_image(alice, "/nonexistent.png")
    end
  end

  describe "search reaches only the member's own conversations" do
    test "finds one's own messages and nobody else's", ctx do
      carol = setup_user("user")
      dave = setup_user("user")
      {:ok, theirs} = Messaging.find_or_create_conversation(carol, dave)

      {:ok, mine} =
        Messaging.create_message(ctx.conversation, ctx.bob, %{body: "the pineapple plan"})

      {:ok, _} = Messaging.create_message(theirs, carol, %{body: "pineapple for dave"})

      %{messages: found} = Messaging.search_messages(ctx.alice, "pineapple")
      assert Enum.map(found, & &1.id) == [mine.id]
    end

    test "skips deleted messages, and treats % and _ literally", ctx do
      {:ok, gone} =
        Messaging.create_message(ctx.conversation, ctx.alice, %{body: "vanishing ink"})

      {:ok, _} = Messaging.soft_delete_message(gone, ctx.alice)
      {:ok, _} = Messaging.create_message(ctx.conversation, ctx.alice, %{body: "abc"})

      assert %{messages: []} = Messaging.search_messages(ctx.alice, "vanishing")
      assert %{messages: []} = Messaging.search_messages(ctx.alice, "%%")
      assert %{messages: []} = Messaging.search_messages(ctx.alice, "a_c")
    end

    test "is never part of the site search or /ap/search", ctx do
      {:ok, _} = Messaging.create_message(ctx.conversation, ctx.alice, %{body: "zebracorn"})

      conn =
        build_conn()
        |> put_req_header("accept", "application/activity+json")
        |> get("/ap/search?q=zebracorn")

      assert Jason.decode!(conn.resp_body)["totalItems"] == 0
      assert Baudrate.Content.search_articles("zebracorn", []).articles == []
    end
  end
end
