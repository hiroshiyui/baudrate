defmodule BaudrateWeb.AutocompleteSuggestHookTest do
  @moduledoc """
  The hashtag / @mention suggest events are answered for every authenticated
  LiveView, including pages whose only Markdown textarea is a settings field.
  `/profile` and `/admin/settings` used to have no handler, so typing `#` or
  `@` there crashed the LiveView.
  """

  use BaudrateWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting
  alias BaudrateWeb.AutocompleteSuggestHook

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    :ok
  end

  test "the profile signature field gets suggestions instead of crashing", %{conn: conn} do
    user = setup_user("user")
    other = setup_user("user")
    {:ok, lv, _html} = live(log_in_user(conn, user), "/profile")

    render_hook(lv, "mention_suggest", %{"prefix" => String.slice(other.username, 0, 6)})
    assert_push_event(lv, "mention_suggestions", %{users: users})
    assert Enum.any?(users, &(&1.username == other.username))
    refute Enum.any?(users, &(&1.username == user.username))

    render_hook(lv, "hashtag_suggest", %{"prefix" => "el"})
    assert_push_event(lv, "hashtag_suggestions", %{tags: _})
    assert Process.alive?(lv.pid)
  end

  test "the admin End User Agreement field gets suggestions", %{conn: conn} do
    admin = setup_user("admin")
    {:ok, lv, _html} = live(log_in_admin(conn, admin), "/admin/settings")

    render_hook(lv, "hashtag_suggest", %{"prefix" => "el"})
    assert_push_event(lv, "hashtag_suggestions", %{tags: _})
    assert Process.alive?(lv.pid)
  end

  test "a malformed suggest event is dropped, other events pass through" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:halt, ^socket} =
             AutocompleteSuggestHook.handle_event("mention_suggest", %{"prefix" => 1}, socket)

    assert {:halt, ^socket} = AutocompleteSuggestHook.handle_event("hashtag_suggest", %{}, socket)
    assert {:cont, ^socket} = AutocompleteSuggestHook.handle_event("save", %{}, socket)
  end
end
