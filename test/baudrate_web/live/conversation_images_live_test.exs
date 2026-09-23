defmodule BaudrateWeb.ConversationImagesLiveTest do
  @moduledoc """
  Images in the conversation composer, and searching one's messages from
  `/messages` (6D, ADR 0071).
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Messaging
  alias Baudrate.Messaging.DmImage
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    alice = setup_user("user")
    bob = setup_user("user")
    {:ok, conversation} = Messaging.find_or_create_conversation(alice, bob)

    on_exit(fn ->
      for image <- Repo.all(DmImage) do
        with {:ok, path} <-
               Baudrate.DataPortability.Files.image_path("dm_images", image.filename),
             do: File.rm(path)
      end
    end)

    %{conn: log_in_user(conn, alice), alice: alice, bob: bob, conversation: conversation}
  end

  # Denying every bucket would refuse the page's own mount.
  defp deny_only(prefix) do
    BaudrateWeb.RateLimiter.Sandbox.set_fun(fn bucket, _scale, _limit ->
      if String.starts_with?(bucket, prefix), do: {:deny, 1}, else: {:allow, 1}
    end)
  end

  defp png, do: Image.new!(32, 32, color: :white) |> Image.write!(:memory, suffix: ".png")

  defp upload(lv, name) do
    lv
    |> file_input("#conversation-images-form", :dm_images, [
      %{name: name, content: png(), type: "image/png"}
    ])
    |> render_upload(name)
  end

  describe "attaching images" do
    test "an image uploads, takes a description, and sends on its own", ctx do
      {:ok, lv, _html} = live(ctx.conn, "/messages/#{ctx.conversation.id}")

      upload(lv, "photo.png")
      [image] = Repo.all(DmImage)
      assert is_nil(image.message_id)
      assert has_element?(lv, "#conversation-uploaded-image-#{image.id}")

      render_blur(lv, "save_dm_image_alt", %{"id" => to_string(image.id), "value" => "A cat"})
      assert Repo.reload(image).alt == "A cat"

      lv |> form("#conversation-compose-form", message: %{body: ""}) |> render_submit()

      image = Repo.reload(image)
      assert image.message_id
      assert has_element?(lv, "#message-image-#{image.id}[aria-label^=\"A cat\"]")
      refute has_element?(lv, "#conversation-uploaded-image-#{image.id}")
    end

    test "an image can be removed before sending, and its file goes", ctx do
      {:ok, lv, _html} = live(ctx.conn, "/messages/#{ctx.conversation.id}")
      upload(lv, "photo.png")
      [image] = Repo.all(DmImage)
      {:ok, path} = Baudrate.DataPortability.Files.image_path("dm_images", image.filename)

      lv |> element("#conversation-uploaded-image-remove-#{image.id}") |> render_click()

      refute Repo.get(DmImage, image.id)
      refute File.exists?(path)
    end

    test "a refused upload says why", ctx do
      deny_only("dm_image_upload:")
      {:ok, lv, _html} = live(ctx.conn, "/messages/#{ctx.conversation.id}")

      html = upload(lv, "photo.png")

      assert html =~ "You have attached as many images as you can for now."
      assert Repo.aggregate(DmImage, :count) == 0
    end

    test "a conversation with another server offers no images", ctx do
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
      {:ok, lv, _html} = live(ctx.conn, "/messages/#{conversation.id}")

      refute has_element?(lv, "#conversation-images")
      assert has_element?(lv, "#conversation-compose-form")
    end
  end

  describe "searching your messages" do
    test "finds a message and opens the conversation on it", ctx do
      {:ok, found} =
        Messaging.create_message(ctx.conversation, ctx.bob, %{body: "meet at the lighthouse"})

      for i <- 1..120 do
        Messaging.create_message(ctx.conversation, ctx.alice, %{body: "filler #{i}"})
      end

      {:ok, lv, _html} = live(ctx.conn, "/messages")

      lv |> form("#messages-search-form", q: "lighthouse") |> render_submit()
      assert_patch(lv, "/messages?q=lighthouse")
      assert has_element?(lv, "#messages-search-result-#{found.id}", "lighthouse")
      assert has_element?(lv, "#messages-search-status", "1 message found")

      # The hit is older than the 100 messages a conversation opens with.
      {:ok, conv_lv, _html} =
        live(ctx.conn, "/messages/#{ctx.conversation.id}?around=#{found.id}")

      assert has_element?(conv_lv, "#message-#{found.id}.message-found")
    end

    test "a new query takes a place in the search limit", ctx do
      deny_only("search:")
      {:ok, lv, _html} = live(ctx.conn, "/messages")

      lv |> form("#messages-search-form", q: "anything") |> render_submit()

      assert render(lv) =~ "Too many searches."
      refute has_element?(lv, "#messages-search-results")
    end

    test "an id from another conversation opens nothing special", ctx do
      carol = setup_user("user")
      {:ok, other} = Messaging.find_or_create_conversation(ctx.bob, carol)
      {:ok, foreign} = Messaging.create_message(other, carol, %{body: "not yours"})

      {:ok, lv, html} = live(ctx.conn, "/messages/#{ctx.conversation.id}?around=#{foreign.id}")

      refute html =~ "not yours"
      refute has_element?(lv, ".message-found")
    end
  end
end
