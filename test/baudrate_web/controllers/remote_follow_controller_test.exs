defmodule BaudrateWeb.RemoteFollowControllerTest do
  @moduledoc """
  The web half of "Follow from your instance" (Phase 4E).

  `Baudrate.Federation.RemoteFollowTest` covers what may be believed about the
  *remote* server. This covers what may be believed about the **form**: the
  actor is rebuilt from a kind and a name rather than taken from a posted URI,
  so a submission cannot name something the page would never have offered.
  """
  use BaudrateWeb.ConnCase

  alias Baudrate.Content.Board
  alias Baudrate.Federation.{DomainBlocks, HTTPClient}
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  @template "https://remote.example/authorize_interaction?uri={uri}"

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    user = setup_user("user")

    %{conn: conn, user: user}
  end

  defp stub_subscribe_template do
    body =
      Jason.encode!(%{
        "subject" => "acct:alice@remote.example",
        "links" => [
          %{"rel" => "http://ostatus.org/schema/1.0/subscribe", "template" => @template}
        ]
      })

    Req.Test.stub(HTTPClient, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  defp board!(slug, min_role_to_view, ap_enabled) do
    %Board{}
    |> Board.changeset(%{
      name: "Board #{slug}",
      slug: slug,
      description: "Test board",
      min_role_to_view: min_role_to_view,
      min_role_to_post: "user",
      ap_enabled: ap_enabled
    })
    |> Repo.insert!()
  end

  describe "a user" do
    test "hands the visitor a link to their own instance", %{conn: conn, user: user} do
      stub_subscribe_template()

      html =
        conn
        |> post(~p"/remote-follow", %{
          "type" => "user",
          "name" => user.username,
          "handle" => "@alice@remote.example"
        })
        |> html_response(200)

      assert html =~ ~s(id="remote-follow-continue")
      assert html =~ "remote.example"
      # The actor is the one the server built, not one the form supplied.
      assert html =~ URI.encode_www_form("/ap/users/#{user.username}") |> String.slice(0, 12)
    end

    test "404s for an account that does not exist", %{conn: conn} do
      assert_error_sent(404, fn ->
        post(conn, ~p"/remote-follow", %{
          "type" => "user",
          "name" => "nobody",
          "handle" => "@alice@remote.example"
        })
      end)
    end

    test "404s for a banned account, exactly as for one that never existed", %{conn: conn} do
      banned = setup_user("user", %{username: "gonesoon"})
      {:ok, _} = banned |> Ecto.Changeset.change(%{status: "banned"}) |> Repo.update()

      assert_error_sent(404, fn ->
        post(conn, ~p"/remote-follow", %{
          "type" => "user",
          "name" => "gonesoon",
          "handle" => "@alice@remote.example"
        })
      end)
    end

    # A move is a redirect; the local Follow button is hidden for one, so this
    # must not offer what that withholds.
    test "404s for a moved account", %{conn: conn} do
      moved = setup_user("user", %{username: "movedaway"})

      {:ok, _} =
        moved
        |> Ecto.Changeset.change(%{moved_to: "https://elsewhere.example/users/movedaway"})
        |> Repo.update()

      assert_error_sent(404, fn ->
        post(conn, ~p"/remote-follow", %{
          "type" => "user",
          "name" => "movedaway",
          "handle" => "@alice@remote.example"
        })
      end)
    end
  end

  describe "a board" do
    test "hands the visitor a link for a federated board", %{conn: conn} do
      stub_subscribe_template()
      board!("open-board", "guest", true)

      html =
        conn
        |> post(~p"/remote-follow", %{
          "type" => "board",
          "name" => "open-board",
          "handle" => "@alice@remote.example"
        })
        |> html_response(200)

      assert html =~ ~s(id="remote-follow-continue")
    end

    # The one that would be easy to get wrong: `ap_enabled` is true, so the
    # board page shows a handle — but the actor 404s and a Follow is Rejected
    # (ADR 0004/0043), so this must refuse, and refuse indistinguishably from
    # a board that does not exist.
    test "404s for an AP-enabled board a guest cannot see", %{conn: conn} do
      board!("members-only", "user", true)

      assert_error_sent(404, fn ->
        post(conn, ~p"/remote-follow", %{
          "type" => "board",
          "name" => "members-only",
          "handle" => "@alice@remote.example"
        })
      end)
    end

    test "404s for a public board with AP switched off", %{conn: conn} do
      board!("quiet-board", "guest", false)

      assert_error_sent(404, fn ->
        post(conn, ~p"/remote-follow", %{
          "type" => "board",
          "name" => "quiet-board",
          "handle" => "@alice@remote.example"
        })
      end)
    end
  end

  describe "refusals all look the same" do
    setup %{user: user} do
      %{path_params: %{"type" => "user", "name" => user.username}}
    end

    test "a malformed handle, a blocked domain and a silent server are one page", %{
      conn: conn,
      path_params: params
    } do
      # 1. malformed
      Req.Test.stub(HTTPClient, fn c -> Plug.Conn.send_resp(c, 200, "{}") end)
      malformed = body(conn, params, "not-a-handle")

      # 2. blocked domain — never fetched
      {:ok, _} = DomainBlocks.block_domain("blocked.example", nil, %{reason: "test"})
      blocked = body(conn, params, "@alice@blocked.example")

      # 3. a server with no subscribe template
      silent = body(conn, params, "@alice@remote.example")

      assert malformed =~ ~s(id="remote-follow-failure")
      assert malformed == blocked
      assert blocked == silent
      refute malformed =~ ~s(id="remote-follow-continue")
    end

    test "and say nothing about which server was asked", %{conn: conn, path_params: params} do
      {:ok, _} = DomainBlocks.block_domain("blocked.example", nil, %{reason: "test"})

      blocked = body(conn, params, "@alice@blocked.example")

      refute blocked =~ "blocked.example"
    end

    test "answers 422 rather than 200, so it is not cached as a result", %{
      conn: conn,
      path_params: params
    } do
      Req.Test.stub(HTTPClient, fn c -> Plug.Conn.send_resp(c, 200, "{}") end)

      conn = post(conn, ~p"/remote-follow", Map.put(params, "handle", "nope"))

      assert conn.status == 422
    end
  end

  test "an unknown target type 404s", %{conn: conn} do
    assert_error_sent(404, fn ->
      post(conn, ~p"/remote-follow", %{
        "type" => "site",
        "name" => "site",
        "handle" => "@alice@remote.example"
      })
    end)
  end

  # The answer itself, without the layout — a fresh CSRF token in <head> makes
  # two byte-identical answers differ, and it is the <main> that must not say
  # which refusal happened.
  defp body(conn, params, handle) do
    conn
    |> post(~p"/remote-follow", Map.put(params, "handle", handle))
    |> html_response(422)
    |> String.split("<main", parts: 2)
    |> List.last()
  end
end
