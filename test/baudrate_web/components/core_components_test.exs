defmodule BaudrateWeb.CoreComponentsTest do
  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BaudrateWeb.CoreComponents

  describe "translate_error/1" do
    test "translates simple error message" do
      assert is_binary(CoreComponents.translate_error({"is invalid", []}))
    end

    test "translates error with count for pluralization" do
      result =
        CoreComponents.translate_error({"should be at least %{count} character(s)", [count: 3]})

      assert is_binary(result)
    end
  end

  describe "image_alt_input/1" do
    # ADR 0061. These two attributes are the whole design: without them the
    # control is an ordinary form input, and LiveView patches an ordinary form
    # input back to the server's value on every `phx-change` re-render — which
    # is to say, it erases what the member is typing as soon as they touch any
    # other field in the composer.
    test "carries no name, so it never joins the form params" do
      html = render_component(&CoreComponents.image_alt_input/1, image: %{id: 7, alt: nil})

      refute html =~ ~s(name=")
      assert html =~ ~s(id="image-alt-7")
      assert html =~ ~s(phx-value-id="7")
    end

    test "sits in an ignored container, so a re-render cannot patch it back" do
      html = render_component(&CoreComponents.image_alt_input/1, image: %{id: 7, alt: nil})

      assert html =~ ~s(id="image-alt-wrap-7")
      assert html =~ ~s(phx-update="ignore")
    end

    test "renders the stored description, and saves on blur as well as keyup" do
      html =
        render_component(&CoreComponents.image_alt_input/1,
          image: %{id: 9, alt: "a cat on a fence"}
        )

      assert html =~ ~s(value="a cat on a fence")
      # Blur alone loses a description typed and then submitted with the
      # keyboard; keyup alone loses one that was pasted.
      assert html =~ ~s(phx-blur="save_image_alt")
      assert html =~ ~s(phx-keyup="save_image_alt")
      assert html =~ ~s(maxlength="#{Baudrate.Content.ImageAlt.max_length()}")
    end

    test "the label is present for a screen reader even though it is not shown" do
      html = render_component(&CoreComponents.image_alt_input/1, image: %{id: 3, alt: nil})

      assert html =~ ~s(for="image-alt-3")
      assert html =~ "image-alt-label sr-only"
    end

    test "a caller may name its own handler, which the timeline needs" do
      html =
        render_component(&CoreComponents.image_alt_input/1,
          image: %{id: 4, alt: nil},
          event: "save_reply_image_alt"
        )

      assert html =~ ~s(phx-blur="save_reply_image_alt")
      refute html =~ ~s(phx-blur="save_image_alt")
    end
  end

  describe "translate_errors/2" do
    test "extracts and translates errors for a specific field" do
      errors = [name: {"can't be blank", []}, email: {"is invalid", []}]
      result = CoreComponents.translate_errors(errors, :name)
      assert length(result) == 1
    end

    test "returns empty list when field has no errors" do
      errors = [name: {"can't be blank", []}]
      assert CoreComponents.translate_errors(errors, :email) == []
    end

    test "returns multiple errors for the same field" do
      errors = [
        name: {"can't be blank", []},
        name: {"is too short", [count: 3]}
      ]

      result = CoreComponents.translate_errors(errors, :name)
      assert length(result) == 2
    end
  end

  describe "icon/1" do
    test "renders a heroicon span" do
      html = render_component(&CoreComponents.icon/1, name: "hero-x-mark")
      assert html =~ "hero-x-mark"
      assert html =~ "aria-hidden=\"true\""
    end

    test "renders with custom class" do
      html =
        render_component(&CoreComponents.icon/1, name: "hero-check", class: "size-6 text-green")

      assert html =~ "size-6 text-green"
    end
  end

  describe "header/1" do
    test "renders h1 with title" do
      html =
        render_component(&CoreComponents.header/1, %{
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "My Title" end}],
          subtitle: [],
          actions: []
        })

      assert html =~ "My Title"
      assert html =~ "<h1"
    end
  end

  describe "button/1" do
    test "renders a button element" do
      html =
        render_component(&CoreComponents.button/1, %{
          rest: %{},
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Click me" end}]
        })

      assert html =~ "Click me"
      assert html =~ "<button"
      assert html =~ "btn"
    end

    test "renders a link when navigate is set" do
      html =
        render_component(&CoreComponents.button/1, %{
          rest: %{navigate: "/home"},
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "Go Home" end}]
        })

      assert html =~ "Go Home"
      assert html =~ "/home"
    end
  end

  describe "flash/1" do
    test "renders info flash" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          flash: %{"info" => "Success!"},
          rest: %{},
          title: nil,
          inner_block: []
        })

      assert html =~ "Success!"
      assert html =~ "alert-info"
      assert html =~ "role=\"alert\""
    end

    test "renders error flash" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :error,
          flash: %{"error" => "Something went wrong"},
          rest: %{},
          title: nil,
          inner_block: []
        })

      assert html =~ "Something went wrong"
      assert html =~ "alert-error"
    end

    test "does not render when flash is empty" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          flash: %{},
          rest: %{},
          title: nil,
          inner_block: []
        })

      refute html =~ "alert"
    end
  end

  describe "avatar/1" do
    test "renders placeholder avatar with initial when no avatar_id" do
      user = %Baudrate.Setup.User{username: "alice", display_name: nil, avatar_id: nil}

      html =
        render_component(&CoreComponents.avatar/1, user: user, size: 48)

      assert html =~ "A"
      assert html =~ "avatar-placeholder"
    end

    test "renders image avatar when avatar_id is present" do
      user = %Baudrate.Setup.User{username: "bob", display_name: "Bob", avatar_id: "abc123"}

      html =
        render_component(&CoreComponents.avatar/1, user: user, size: 48)

      assert html =~ "<img"
      assert html =~ "abc123"
    end

    test "uses display_name for alt text when present" do
      user = %Baudrate.Setup.User{username: "bob", display_name: "Bobby", avatar_id: "abc123"}

      html =
        render_component(&CoreComponents.avatar/1, user: user, size: 48)

      assert html =~ "Bobby"
    end

    test "renders 120px avatar with image" do
      user = %Baudrate.Setup.User{username: "carol", display_name: "Carol", avatar_id: "def456"}

      html =
        render_component(&CoreComponents.avatar/1, user: user, size: 120)

      assert html =~ "<img"
      assert html =~ "w-[120px]"
      assert html =~ "def456"
    end

    test "renders 120px placeholder avatar" do
      user = %Baudrate.Setup.User{username: "dave", display_name: nil, avatar_id: nil}

      html =
        render_component(&CoreComponents.avatar/1, user: user, size: 120)

      assert html =~ "avatar-placeholder"
      assert html =~ "w-[120px]"
      assert html =~ "text-4xl"
      assert html =~ "D"
    end
  end

  describe "pagination/1" do
    test "renders pagination when total_pages > 1" do
      html =
        render_component(&CoreComponents.pagination/1,
          page: 2,
          total_pages: 5,
          path: "/boards/test",
          params: %{}
        )

      assert html =~ "aria-label=\"Pagination\""
      assert html =~ "aria-current=\"page\""
      assert html =~ "page=1"
      assert html =~ "page=3"
    end

    test "does not render when total_pages is 1" do
      html =
        render_component(&CoreComponents.pagination/1,
          page: 1,
          total_pages: 1,
          path: "/boards/test",
          params: %{}
        )

      refute html =~ "Pagination"
    end

    test "disables previous button on first page" do
      html =
        render_component(&CoreComponents.pagination/1,
          page: 1,
          total_pages: 3,
          path: "/boards/test",
          params: %{}
        )

      assert html =~ "disabled"
    end

    test "disables next button on last page" do
      html =
        render_component(&CoreComponents.pagination/1,
          page: 3,
          total_pages: 3,
          path: "/boards/test",
          params: %{}
        )

      # The next button should be disabled
      assert html =~ "disabled"
    end

    test "preserves existing params in pagination links" do
      html =
        render_component(&CoreComponents.pagination/1,
          page: 2,
          total_pages: 5,
          path: "/boards/test",
          params: %{"status" => "open"}
        )

      assert html =~ "status=open"
    end

    test "current page exposes its name via visually hidden text, not aria-label" do
      html =
        render_component(&CoreComponents.pagination/1,
          page: 2,
          total_pages: 5,
          path: "/boards/test",
          params: %{}
        )

      assert html =~ ~r/class="pagination-current[^"]*"\s+aria-current="page"/
      refute html =~ ~r/class="pagination-current[^"]*"[^>]*aria-label=/
      assert html =~ ~r/class="pagination-current-label sr-only">\s*Page 2\s*</
      assert html =~ ~r/class="pagination-current-number" aria-hidden="true">2</
    end
  end

  describe "avatar/1 decorative" do
    test "placeholder avatar is hidden from assistive technology" do
      user = %Baudrate.Setup.User{username: "erin", display_name: nil, avatar_id: nil}

      html = render_component(&CoreComponents.avatar/1, user: user, size: 24, decorative: true)

      assert html =~ ~s(aria-hidden="true")
      refute html =~ ~s(role="img")
      refute html =~ ~s(aria-label="erin")
    end

    test "image avatar renders an empty alt" do
      user = %Baudrate.Setup.User{username: "frank", display_name: "Frank", avatar_id: "abc123"}

      html = render_component(&CoreComponents.avatar/1, user: user, size: 24, decorative: true)

      assert html =~ ~s(alt="")
      refute html =~ ~s(alt="Frank")
    end

    test "non-decorative placeholder keeps role=img and label" do
      user = %Baudrate.Setup.User{username: "gina", display_name: nil, avatar_id: nil}

      html = render_component(&CoreComponents.avatar/1, user: user, size: 24)

      assert html =~ ~s(role="img")
      assert html =~ ~s(aria-label="gina")
      # The initial inside is always aria-hidden; only the wrapper must stay exposed.
      [wrapper] = Regex.run(~r/<div class="core-avatar[^>]*>/, html)
      refute wrapper =~ ~s(aria-hidden="true")
    end
  end

  describe "input/1 textarea" do
    test "label only wraps the label text and points at the textarea" do
      html =
        render_component(&CoreComponents.input/1,
          type: "textarea",
          id: "post-body",
          name: "post[body]",
          value: "",
          label: "Body",
          toolbar: true
        )

      assert html =~ ~r/<label[^>]*for="post-body"[^>]*>\s*Body\s*<\/label>/
      refute html =~ ~r/<label[^>]*>(?:(?!<\/label>).)*<textarea/s
      refute html =~ ~r/<label[^>]*>(?:(?!<\/label>).)*post-body-md-toolbar/s
      assert html =~ ~s(id="post-body-md-preview")
      assert html =~ ~s(id="post-body-md-toolbar")
      assert html =~ ~s(phx-hook="MarkdownToolbarHook")
    end

    test "renders no label element when label is nil" do
      html =
        render_component(&CoreComponents.input/1,
          type: "textarea",
          id: "plain-body",
          name: "body",
          value: ""
        )

      refute html =~ "<label"
      assert html =~ ~s(id="plain-body")
    end

    test "label_class is applied to the label" do
      html =
        render_component(&CoreComponents.input/1,
          type: "textarea",
          id: "reply-body",
          name: "body",
          value: "",
          label: "Reply",
          label_class: "sr-only"
        )

      assert html =~ ~r/<label[^>]*for="reply-body"[^>]*class="[^"]*sr-only/
    end
  end

  describe "extract_youtube_video_id/1" do
    test "extracts from standard watch URL" do
      assert CoreComponents.extract_youtube_video_id(
               "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
             ) ==
               "dQw4w9WgXcQ"
    end

    test "extracts from short youtu.be URL" do
      assert CoreComponents.extract_youtube_video_id("https://youtu.be/dQw4w9WgXcQ") ==
               "dQw4w9WgXcQ"
    end

    test "extracts from embed URL" do
      assert CoreComponents.extract_youtube_video_id("https://www.youtube.com/embed/dQw4w9WgXcQ") ==
               "dQw4w9WgXcQ"
    end

    test "extracts from shorts URL" do
      assert CoreComponents.extract_youtube_video_id("https://www.youtube.com/shorts/dQw4w9WgXcQ") ==
               "dQw4w9WgXcQ"
    end

    test "extracts from mobile URL" do
      assert CoreComponents.extract_youtube_video_id("https://m.youtube.com/watch?v=dQw4w9WgXcQ") ==
               "dQw4w9WgXcQ"
    end

    test "extracts with extra query params" do
      assert CoreComponents.extract_youtube_video_id(
               "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s"
             ) == "dQw4w9WgXcQ"
    end

    test "extracts from HTTP URL" do
      assert CoreComponents.extract_youtube_video_id("http://www.youtube.com/watch?v=dQw4w9WgXcQ") ==
               "dQw4w9WgXcQ"
    end

    test "returns nil for non-YouTube URL" do
      assert CoreComponents.extract_youtube_video_id("https://example.com/video") == nil
    end

    test "returns nil for nil input" do
      assert CoreComponents.extract_youtube_video_id(nil) == nil
    end

    test "returns nil for YouTube channel URL" do
      assert CoreComponents.extract_youtube_video_id("https://www.youtube.com/@channel") == nil
    end
  end

  describe "show/2 and hide/2" do
    test "show returns a JS struct" do
      js = CoreComponents.show("#modal")
      assert %Phoenix.LiveView.JS{} = js
    end

    test "hide returns a JS struct" do
      js = CoreComponents.hide("#modal")
      assert %Phoenix.LiveView.JS{} = js
    end

    test "show with existing JS struct" do
      js = Phoenix.LiveView.JS.push("event")
      result = CoreComponents.show(js, "#modal")
      assert %Phoenix.LiveView.JS{} = result
    end
  end
end
