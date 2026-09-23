defmodule BaudrateWeb.ProfilePagesTest do
  @moduledoc """
  The five settings pages a member reaches from `/profile` (6E-1): each
  renders, marks itself in the shared navigation, renders every `id` once
  (`semantic_anchors_test.exs` fetches only as a guest, and these pages
  redirect a guest), and survives a message it does not handle — the count
  hooks forward DM and notification events to every signed-in LiveView.
  """

  use BaudrateWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  @pages [
    {"/profile", "profile"},
    {"/profile/security", "security"},
    {"/profile/notifications", "notifications"},
    {"/profile/privacy", "privacy"},
    {"/profile/account", "account"}
  ]

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")
    %{conn: log_in_user(conn, user)}
  end

  test "every page marks itself, and only itself, as the current one", %{conn: conn} do
    for {path, key} <- @pages do
      {:ok, lv, _html} = live(conn, path)

      assert has_element?(lv, ~s(#profile-nav-#{key}[aria-current="page"])),
             "#{path} does not mark its own navigation link"

      for {_other, other_key} <- @pages, other_key != key do
        refute has_element?(lv, ~s(#profile-nav-#{other_key}[aria-current])),
               "#{path} marks #{other_key} as current too"
      end
    end
  end

  test "no page renders a duplicate id", %{conn: conn} do
    for {path, _key} <- @pages do
      body = conn |> get(path) |> html_response(200)

      dups =
        ~r/\sid="([^"]+)"/
        |> Regex.scan(body, capture: :all_but_first)
        |> List.flatten()
        |> Enum.frequencies()
        |> Enum.filter(fn {_id, n} -> n > 1 end)

      assert dups == [], "#{path} renders duplicate ids: #{inspect(dups)}"
    end
  end

  test "a message a page does not handle is ignored", %{conn: conn} do
    for {path, _key} <- @pages do
      {:ok, lv, _html} = live(conn, path)
      send(lv.pid, {:dm_received, %{conversation_id: 1}})
      assert render(lv) =~ "profile-nav"
    end
  end
end
