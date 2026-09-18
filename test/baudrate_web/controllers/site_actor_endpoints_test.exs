defmodule BaudrateWeb.SiteActorEndpointsTest do
  @moduledoc """
  Every endpoint the site actor advertises has to be served.

  The instance actor published `inbox`, `outbox` and `followers` under
  `/ap/site/…` for as long as it has existed, and none of the three was in the
  router: a peer that followed the actor document got a 404. Nobody noticed
  because `endpoints.sharedInbox` points at `/ap/inbox`, which does work, and
  that is what Mastodon and most implementations use.

  So these tests deliberately read the **document** and check the router,
  rather than listing paths of their own. A test that hardcoded the three URLs
  would pass just as happily while the actor advertised a fourth.
  """

  use BaudrateWeb.ConnCase, async: true

  alias Baudrate.Federation

  @activity_json "application/activity+json"

  # The actor document is the source of truth for what we promise to serve.
  defp advertised do
    actor = Federation.site_actor()

    %{
      "inbox" => {"POST", actor["inbox"]},
      "outbox" => {"GET", actor["outbox"]},
      "followers" => {"GET", actor["followers"]},
      "sharedInbox" => {"POST", actor["endpoints"]["sharedInbox"]}
    }
  end

  defp path_of(url), do: URI.parse(url).path

  test "every endpoint the site actor advertises is routed" do
    for {field, {method, url}} <- advertised() do
      assert is_binary(url), "the site actor advertises no #{field}"

      path = path_of(url)

      assert %{} = Phoenix.Router.route_info(BaudrateWeb.Router, method, path, "localhost"),
             """
             The site actor advertises #{field} at #{path}, and the router has no
             #{method} route for it. A peer that reads the actor document and
             follows that URL gets a 404.
             """
    end
  end

  test "the outbox answers, and is empty", %{conn: conn} do
    path = path_of(Federation.site_actor()["outbox"])

    body =
      conn
      |> put_req_header("accept", @activity_json)
      |> get(path)
      |> json_response(200)

    assert body["type"] == "OrderedCollection"
    assert body["totalItems"] == 0

    # The instance actor never posts, so the first page exists but is empty
    # rather than absent — an advertised collection whose first page 404s is
    # the same defect one level down.
    page =
      conn
      |> put_req_header("accept", @activity_json)
      |> get(path, %{"page" => "1"})
      |> json_response(200)

    assert page["type"] == "OrderedCollectionPage"
    assert page["orderedItems"] == []
  end

  test "the followers collection answers", %{conn: conn} do
    path = path_of(Federation.site_actor()["followers"])

    body =
      conn
      |> put_req_header("accept", @activity_json)
      |> get(path)
      |> json_response(200)

    assert body["type"] == "OrderedCollection"
    assert is_integer(body["totalItems"])
  end
end
