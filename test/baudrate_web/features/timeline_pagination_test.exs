defmodule BaudrateWeb.Features.FeedPaginationTest do
  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  alias Baudrate.{Federation, Repo}
  alias Baudrate.Federation.RemoteActor

  setup do
    user = setup_user("user")
    uid = System.unique_integer([:positive])

    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/pg-#{uid}",
        username: "pg_#{uid}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/pg-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _} = Federation.accept_user_follow(follow.ap_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for n <- 1..45 do
      {:ok, _} =
        Federation.create_timeline_item(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/pg-#{uid}-#{n}",
          body: "Post number #{n}",
          body_html: "<p>Post number #{n}</p>",
          source_url: "https://remote.example/notes/pg-#{uid}-#{n}",
          published_at: DateTime.add(now, -n * 60, :second)
        })
    end

    %{user: user}
  end

  # The feed composer's textarea mounts HashtagAutocompleteHook. Its mounted/0
  # used to call a method that no longer existed, and the thrown error made
  # LiveView drop every later patch: the URL changed, the page did not.
  feature "the pager switches pages, including from ?page=2", %{session: session, user: user} do
    session
    |> log_in_via_browser(user)
    |> visit("/timeline")
    |> click(Query.css(".pagination-page", text: "2"))
    |> assert_has(Query.css(".pagination-current", text: "2"))
    |> assert_has(Query.text("Post number 21"))
    |> visit("/timeline?page=2")
    |> click(Query.css(".pagination-page", text: "3"))
    |> assert_has(Query.css(".pagination-current", text: "3"))
    |> assert_has(Query.text("Post number 41"))
    |> click(Query.css(".pagination-prev"))
    |> assert_has(Query.css(".pagination-current", text: "2"))
  end

  feature "paging from the bottom scrolls back to the top of the list", %{
    session: session,
    user: user
  } do
    session =
      session
      |> log_in_via_browser(user)
      |> visit("/timeline")
      |> execute_script("window.scrollTo(0, document.body.scrollHeight)")
      |> click(Query.css(".pagination-page", text: "2"))
      |> assert_has(Query.css(".pagination-current", text: "2"))

    # Let the scroll-to-top event and the focus handler run.
    Process.sleep(300)

    execute_script(
      session,
      """
      const list = document.getElementById("timeline-items");
      const header = document.getElementById("site-header");
      return [Math.round(list.getBoundingClientRect().top - (header ? header.offsetHeight : 0)),
              list.contains(document.activeElement)];
      """,
      fn value -> send(self(), {:scroll, value}) end
    )

    assert_receive {:scroll, [offset, focus_inside]}
    assert abs(offset) <= 2
    assert focus_inside
  end

  feature "@mention autocomplete suggests in the feed composer", %{session: session, user: user} do
    other = setup_user("user")
    prefix = String.slice(other.username, 0, 6)

    session
    |> log_in_via_browser(user)
    |> visit("/timeline")
    |> fill_in(Query.css("#quick-post textarea"), with: "Hello @#{prefix}")
    |> assert_has(Query.css("[role=option]", text: other.username))
  end
end
