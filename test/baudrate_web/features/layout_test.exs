defmodule BaudrateWeb.Features.LayoutTest do
  @moduledoc """
  Checks rendered layout in both default themes (Aqua light and dark) at a
  narrow and a desktop width: no page scrolls sideways, and every dropdown
  menu opens inside the viewport with each item reachable.

  The narrow width is Firefox's minimum window, 500 px (a 488 px viewport):
  Firefox refuses anything smaller, whatever the window size, pixel ratio or
  flags. It is below Tailwind's first breakpoint (640 px), so it renders the
  phone layout, though a 360 px phone has less room still.

  Pixel screenshots break with every browser update, so these are geometric
  assertions instead, aimed at the layout bugs that shipped: a long
  unbreakable token widening the page (the grid track blowout in CLAUDE.md),
  and the Aqua themes clipping card menus so most feed item actions could not
  be clicked (v1.19.1). An item is reachable when `elementFromPoint` at its
  centre lands inside the menu, which fails for clipped and covered items
  alike.
  """

  use BaudrateWeb.FeatureCase, async: false

  @moduletag :feature
  # Each feature checks every page in two themes at two widths.
  @moduletag timeout: 600_000

  alias Baudrate.{Content, Federation, Messaging, Repo}
  alias Baudrate.Federation.RemoteActor

  @themes [{"light", "aquaosx"}, {"dark", "aquaosxdark"}]
  @sizes [narrow: {500, 844}, desktop: {1280, 900}]

  # Returns the page's horizontal overflow, naming the innermost elements that
  # stick out (elements inside a scrolling or clipping container are allowed).
  @overflow """
  const vw = document.documentElement.clientWidth;
  const describe = (el) => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") +
    (typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\\s+/).slice(0, 2).join(".") : "");
  if (document.documentElement.scrollWidth <= vw + 1) return [];
  const contained = (el) => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      if (["auto", "scroll", "hidden", "clip"].includes(getComputedStyle(p).overflowX)) return true;
    }
    return false;
  };
  // An element sticks out when its box does, or when its content overflows a
  // box that shows it (text in a narrow box does not widen the box itself).
  const sticksOut = [...document.body.querySelectorAll("*")].filter((el) => {
    if (contained(el)) return false;
    const r = el.getBoundingClientRect();
    if (r.width > 0 && r.right > vw + 1) return true;
    return getComputedStyle(el).overflowX === "visible" && el.scrollWidth > el.clientWidth + 1 &&
      r.left + el.scrollWidth > vw + 1;
  });
  const innermost = sticksOut.filter((el) => !sticksOut.some((o) => o !== el && el.contains(o)));
  return ["page is " + document.documentElement.scrollWidth + "px wide in a " + vw + "px window: " +
    innermost.slice(0, 4).map(describe).join(", ")];
  """

  # Opens every visible dropdown in turn and records menus that stick out of
  # the viewport or have items another element covers or clips. Results land
  # in window.__menuProblems.
  @menus """
  window.__menuProblems = null;
  (async () => {
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const vw = document.documentElement.clientWidth;
    const describe = (el) => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") +
      (typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\\s+/).slice(0, 2).join(".") : "");
    // Scroll only the window: scrollIntoView also scrolls an overflow: hidden
    // ancestor, which would reveal exactly the clipped items being looked for.
    const centre = async (el) => {
      const r = el.getBoundingClientRect();
      if (r.top < 100 || r.bottom > window.innerHeight - 100) {
        window.scrollBy(0, r.top + r.height / 2 - window.innerHeight / 2);
        await sleep(50);
      }
    };
    const problems = [];
    const triggers = [...document.querySelectorAll(".dropdown > [aria-haspopup]")]
      .filter((t) => t.getClientRects().length > 0);
    for (const trigger of triggers) {
      const menu = trigger.closest(".dropdown").querySelector(".dropdown-content");
      if (!menu) continue;
      await centre(trigger);
      trigger.focus();
      await sleep(200);
      const r = menu.getBoundingClientRect();
      if (r.width === 0 || getComputedStyle(menu).visibility === "hidden") {
        problems.push(describe(trigger) + ": menu did not open");
      } else {
        if (r.left < -1 || r.right > vw + 1) {
          problems.push(describe(menu) + " sticks out of the viewport (" + Math.round(r.left) + " to " + Math.round(r.right) + " of " + vw + "px)");
        }
        for (const item of menu.querySelectorAll(":scope > li > a, :scope > li > button")) {
          if (item.getClientRects().length === 0) continue;
          await centre(item);
          const ir = item.getBoundingClientRect();
          const hit = document.elementFromPoint(ir.left + ir.width / 2, ir.top + ir.height / 2);
          if (!hit || !menu.contains(hit)) {
            problems.push(describe(item) + " in " + describe(menu) + " is covered or clipped by " + (hit ? describe(hit) : "nothing"));
          }
        }
      }
      trigger.blur();
      await sleep(150);
    }
    window.__menuProblems = problems;
  })();
  """

  setup do
    user = setup_user("user")
    other = setup_user("user")
    board = create_board(%{})
    # A long unbreakable token, as in federated and RSS content (no URL, so no
    # link preview fetch is started).
    long_token = String.duplicate("unbrokenpath", 20)

    article =
      create_article(user, board, %{
        title: "Layout " <> String.slice(long_token, 0, 200),
        body: "See " <> long_token <> " #layouttag"
      })

    other_article = create_article(other, board, %{})

    {:ok, _} =
      Content.create_comment(%{body: long_token, article_id: other_article.id, user_id: user.id})

    # Put the long title on the bookmarks, notifications and moderation pages.
    {:ok, _} = Content.bookmark_article(user.id, article.id)

    {:ok, reply} =
      Content.create_comment(%{body: long_token, article_id: article.id, user_id: other.id})

    Baudrate.Notification.Hooks.notify_comment_created(reply)

    {:ok, _} =
      Baudrate.Moderation.create_report(%{
        category: "spam",
        reason: long_token,
        reporter_id: other.id,
        article_id: article.id
      })

    {:ok, conversation} = Messaging.find_or_create_conversation(user, other)
    {:ok, _} = Messaging.create_message(conversation, other, %{"body" => long_token})

    # A long post, and a one-line one whose card is shorter than its menu (the
    # Aqua themes clipped that menu).
    follow_remote_actor_with_posts(user, [long_token, "Short post"])

    # The policy pages carry admin-written prose with an unbreakable URL in it,
    # and the footer that links them appears on every page below. The version is
    # deliberately *not* published here: a pending acceptance changes what these
    # pages do (the composer redirects), which is the gate working, not layout.
    Baudrate.Setup.update_eua("These are the terms. See https://#{long_token}.example/full-text")
    # Two rules, so /rules renders a numbered list and the admin page renders
    # its reorder controls with a long unbreakable title in the row.
    {:ok, _} =
      Baudrate.Setup.create_rule(%{
        "title" => "Rule one: #{String.slice(long_token, 0, 120)}",
        "body" => "See https://#{long_token}.example/rules"
      })

    {:ok, _} = Baudrate.Setup.create_rule(%{"title" => "Rule two"})
    Baudrate.Setup.update_policy(:privacy, "We log. See https://#{long_token}.example/privacy")

    %{
      user: user,
      paths: [
        "/",
        "/timeline",
        "/search?q=layout",
        "/boards/#{board.slug}",
        "/articles/#{article.slug}",
        "/articles/#{other_article.slug}",
        "/articles/#{article.slug}/edit",
        "/articles/#{article.slug}/history",
        "/users/#{user.username}/comments",
        "/articles/new",
        "/users/#{other.username}",
        "/users/#{user.username}",
        "/tags/layouttag",
        "/users/#{user.username}/articles",
        "/profile",
        "/messages",
        "/messages/#{conversation.id}",
        "/notifications",
        "/invites",
        "/bookmarks",
        "/following",
        "/terms",
        "/rules",
        "/privacy"
      ]
    }
  end

  feature "member pages fit the screen and their menus open fully, in both themes", %{
    session: session,
    user: user,
    paths: paths
  } do
    session = log_in_via_browser(session, user)
    assert check_layout(session, paths) == []
  end

  feature "admin pages fit the screen and their menus open fully, in both themes", %{
    session: session
  } do
    {session, admin, secret} = log_in_admin_via_browser(session)
    session = visit_admin(session, "/admin/settings", {admin, secret})

    # The user detail page carries the widest table in the admin area (six
    # columns of staff-written text), so it is crawled with a real record.
    member = sanctioned_member(admin)
    domain = blocked_instance(admin)

    paths = [
      "/admin/settings",
      "/admin/federation",
      "/admin/federation/instances/#{domain}",
      "/admin/moderation",
      "/admin/boards",
      "/admin/users",
      "/admin/users/#{member.id}",
      "/admin/rules",
      "/admin/moderation-log",
      "/admin/invites",
      "/admin/login-attempts",
      "/admin/data-exports",
      "/admin/bots"
    ]

    assert check_layout(session, paths) == []
  end

  # A member with a sanction whose reason is long and unbreakable — the shape
  # that widens a table before short test text ever does.
  # The instance page renders remote handles and staff-written reasons, both of
  # which are long unbreakable tokens from elsewhere — the shape that widens a
  # page rather than wrapping.
  defp blocked_instance(admin) do
    domain = "a-very-long-instance-name-from-the-fediverse.example"

    Baudrate.Repo.insert!(%Baudrate.Federation.RemoteActor{
      ap_id: "https://#{domain}/users/someone-with-a-very-long-handle-indeed",
      username: "someone-with-a-very-long-handle-indeed",
      domain: domain,
      display_name: "Someone With A Rather Long Display Name Too",
      public_key_pem: elem(Baudrate.Federation.KeyStore.generate_keypair(), 0),
      inbox: "https://#{domain}/users/someone-with-a-very-long-handle-indeed/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    {:ok, _} =
      Baudrate.Federation.DomainBlocks.block_domain(domain, admin, %{
        reason:
          "Sustained harassment, see https://example.com/a-very-long-unbreakable-link-about-the-incident"
      })

    domain
  end

  defp sanctioned_member(admin) do
    member = setup_user("user")

    {:ok, _} =
      Baudrate.Auth.issue_sanction(admin, member, "silence",
        reason:
          "Repeatedly posted https://example.com/a-very-long-unbreakable-link-that-should-wrap-rather-than-widen-the-page",
        expires_at:
          DateTime.utc_now() |> DateTime.add(7 * 86_400, :second) |> DateTime.truncate(:second)
      )

    member
  end

  defp check_layout(session, paths) do
    for {pref, theme} <- @themes,
        # The theme preference is per browser (localStorage), set once per theme.
        session = session |> visit(hd(paths)) |> execute_script(set_theme(pref)),
        {size_name, {width, height}} <- @sizes,
        session = resize_window(session, width, height),
        path <- paths,
        problem <- check_page(session, path, theme) do
      "#{theme} #{size_name} #{path} — #{problem}"
    end
  end

  defp set_theme(pref), do: "localStorage.setItem('phx:theme', '#{pref}')"

  defp check_page(session, path, theme) do
    session = visit(session, path)
    assert current_path(session) == URI.parse(path).path, "#{path} redirected"

    assert js_value(session, "return document.documentElement.getAttribute('data-theme')") ==
             theme

    js_value(session, @overflow) ++ menu_problems(session)
  end

  defp menu_problems(session) do
    execute_script(session, @menus)
    wait_for_menu_problems(session, 100)
  end

  defp wait_for_menu_problems(_session, 0), do: ["menu check did not finish"]

  defp wait_for_menu_problems(session, tries) do
    case js_value(session, "return window.__menuProblems") do
      nil -> Process.sleep(200) && wait_for_menu_problems(session, tries - 1)
      problems -> problems
    end
  end

  defp follow_remote_actor_with_posts(user, bodies) do
    uid = System.unique_integer([:positive])

    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/layout-#{uid}",
        username: "layout_#{uid}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/layout-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _} = Federation.accept_user_follow(follow.ap_id)

    for {body, n} <- Enum.with_index(bodies) do
      {:ok, _} =
        Federation.create_timeline_item(%{
          remote_actor_id: actor.id,
          activity_type: "Create",
          object_type: "Note",
          ap_id: "https://remote.example/notes/layout-#{uid}-#{n}",
          body: body,
          body_html: "<p>#{body}</p>",
          source_url: "https://remote.example/notes/layout-#{uid}-#{n}",
          published_at:
            DateTime.add(DateTime.utc_now(), -n * 60, :second) |> DateTime.truncate(:second)
        })
    end
  end
end
