defmodule BaudrateWeb.Features.JsErrorsTest do
  @moduledoc """
  Crawls the member pages in a real browser and fails on any JavaScript error.

  JS hooks are not covered by the LiveView tests, so a hook that throws (or a
  `phx-hook` name that is not registered) passed the whole suite while it
  broke the page: `HashtagAutocompleteHook` called a renamed method and made
  LiveView drop later patches (the feed pager stopped working), and the DM
  page asked for an unregistered `ScrollBottom` hook.

  Errors thrown while the page first loads happen before a recorder can be
  installed, so each page is re-mounted through a live navigation after the
  recorder is in place. The recorder catches `window` errors, unhandled
  promise rejections, `console.error` (where LiveView reports unknown hooks)
  and LiveView marking a view with `phx-error`, which is how a server-side
  crash shows up: typing `@` in the `/profile` signature crashed
  `ProfileLive`, which had no handler for the event the autocomplete hook
  pushed. Textareas and dropdown menus are then exercised.
  """

  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature

  alias Baudrate.{Content, Federation, Messaging, Repo}
  alias Baudrate.Federation.RemoteActor

  @recorder """
  if (!window.__jsErrors) {
    window.__jsErrors = [];
    const push = (kind, msg) => window.__jsErrors.push(kind + ": " + String(msg));
    window.addEventListener("error", (e) => push("error", e.message));
    window.addEventListener("unhandledrejection", (e) => push("rejection", e.reason));
    const original = console.error.bind(console);
    console.error = (...args) => { push("console.error", args.map(String).join(" ")); original(...args); };
    // A LiveView process that crashes on the server makes the client mark the
    // view with phx-error while it rejoins; no JS error is thrown.
    new MutationObserver((mutations) => {
      for (const m of mutations) {
        const el = m.target;
        if (el.classList && (el.classList.contains("phx-error") || el.classList.contains("phx-server-error"))) {
          push("liveview", "view crashed or disconnected (" + (el.id || el.tagName) + ")");
        }
      }
    }).observe(document.documentElement, {attributes: true, attributeFilter: ["class"], subtree: true});
  }
  """

  @remount """
  const main = document.querySelector("[data-phx-main]");
  if (main) {
    const a = document.createElement("a");
    a.href = location.pathname + location.search;
    a.setAttribute("data-phx-link", "redirect");
    a.setAttribute("data-phx-link-state", "replace");
    a.hidden = true;
    main.appendChild(a);
    a.click();
  }
  """

  @exercise """
  const fire = (el, type, init) => el.dispatchEvent(new (type.startsWith("key") ? KeyboardEvent : Event)(type, Object.assign({bubbles: true}, init || {})));
  document.querySelectorAll("textarea").forEach((t) => {
    if (t.disabled || t.readOnly) return;
    t.focus();
    for (const text of ["#te", "@us", ":smi"]) {
      t.value = text;
      t.setSelectionRange(text.length, text.length);
      fire(t, "input");
      fire(t, "keydown", {key: "ArrowDown"});
      fire(t, "keydown", {key: "Escape"});
    }
    t.value = "";
    fire(t, "input");
    t.blur();
  });
  document.querySelectorAll(".dropdown [aria-haspopup]").forEach((b) => {
    b.focus();
    fire(b, "keydown", {key: "Escape"});
    fire(b, "mousedown");
    b.blur();
  });
  """

  setup do
    user = setup_user("user")
    other = setup_user("user")
    board = create_board(%{})
    article = create_article(user, board, %{body: "Body with #tag"})
    _other_article = create_article(other, board, %{})

    {:ok, _} =
      Content.create_comment(%{body: "A comment", article_id: article.id, user_id: other.id})

    {:ok, conversation} = Messaging.find_or_create_conversation(user, other)
    {:ok, _} = Messaging.create_message(conversation, other, %{"body" => "Hello there"})

    uid = System.unique_integer([:positive])

    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/js-#{uid}",
        username: "js_#{uid}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/js-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _} = Federation.accept_user_follow(follow.ap_id)

    {:ok, _} =
      Federation.create_feed_item(%{
        remote_actor_id: actor.id,
        activity_type: "Create",
        object_type: "Note",
        ap_id: "https://remote.example/notes/js-#{uid}",
        body: "Remote post",
        body_html: "<p>Remote post</p>",
        source_url: "https://remote.example/notes/js-#{uid}",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{
      user: user,
      paths: [
        "/",
        "/feed",
        "/search?q=test",
        "/users/#{other.username}",
        "/users/#{user.username}/articles",
        "/boards/#{board.slug}",
        "/boards/#{board.slug}/articles/new",
        "/articles/new",
        "/articles/#{article.slug}",
        "/articles/#{article.slug}/edit",
        "/articles/#{article.slug}/history",
        "/tags/tag",
        "/profile",
        "/profile/password",
        "/invites",
        "/messages",
        "/messages/new",
        "/messages/#{conversation.id}",
        "/notifications",
        "/following",
        "/bookmarks"
      ]
    }
  end

  feature "member pages run without JavaScript errors", %{
    session: session,
    user: user,
    paths: paths
  } do
    session = log_in_via_browser(session, user)
    assert crawl(session, paths) == []
  end

  feature "public pages run without JavaScript errors for guests", %{
    session: session,
    paths: paths
  } do
    public =
      Enum.filter(paths, fn path ->
        path == "/" or String.starts_with?(path, ["/search", "/users/", "/boards/", "/tags/"]) or
          (String.starts_with?(path, "/articles/") and not String.ends_with?(path, "/edit") and
             path != "/articles/new")
      end)
      |> Enum.reject(&String.ends_with?(&1, "/articles/new"))

    assert crawl(session, public ++ ["/login", "/register"]) == []
  end

  defp crawl(session, paths) do
    Enum.flat_map(paths, fn path ->
      session
      |> visit(path)
      |> execute_script(@recorder)
      |> execute_script(@remount)

      # Let the live navigation finish and the hooks mount again.
      Process.sleep(700)

      session
      |> execute_script(@recorder)
      |> execute_script(@exercise)

      Process.sleep(400)

      execute_script(session, "return window.__jsErrors || []", fn value ->
        send(self(), {:js_errors, value})
      end)

      errors =
        receive do
          {:js_errors, value} -> value
        after
          1_000 -> ["no result"]
        end

      Enum.map(errors, &"#{path} — #{&1}")
    end)
  end
end
