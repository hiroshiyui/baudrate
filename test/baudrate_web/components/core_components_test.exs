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
