defmodule Baudrate.Federation.RemoteActorSuspensionTest do
  @moduledoc """
  Suspending one remote actor instance-wide (ADR 0030, decision 6).

  The lever between telling a reporter to block an account personally and
  blocking its entire domain. It shares the hiding predicate with domain
  blocks — these tests are what keeps the two from diverging.
  """
  use Baudrate.DataCase, async: false

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Federation.{DomainBlockCache, InboxHandler, RemoteActor, RemoteActors}
  alias Baudrate.Setup

  setup do
    Setup.seed_roles_and_permissions()
    Setup.set_setting("ap_federation_mode", "blocklist")
    DomainBlockCache.refresh()

    board = create_board()
    actor = create_remote_actor("shared.example", "loud")
    neighbour = create_remote_actor("shared.example", "quiet")

    marker = "zqxsuspended#{System.unique_integer([:positive])}"
    safe = "zqxneighbour#{System.unique_integer([:positive])}"

    {:ok, %{article: _}} = create_remote_article(board, actor, marker)
    {:ok, %{article: _}} = create_remote_article(board, neighbour, safe)

    %{board: board, actor: actor, neighbour: neighbour, marker: marker, safe: safe}
  end

  defp create_board do
    %Board{}
    |> Board.changeset(%{name: "Board", slug: "board-#{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp create_remote_actor(domain, prefix) do
    n = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{domain}/users/#{prefix}#{n}",
      username: "#{prefix}#{n}",
      domain: domain,
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://#{domain}/users/#{prefix}#{n}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp create_remote_article(board, actor, title) do
    n = System.unique_integer([:positive])

    Content.create_remote_article(
      %{
        title: title,
        body: "body of #{title}",
        slug: "slug-#{n}",
        ap_id: "https://#{actor.domain}/articles/#{n}",
        remote_actor_id: actor.id,
        visibility: "public"
      },
      [board.id]
    )
  end

  defp titles(board), do: Content.list_articles_for_board(board) |> Enum.map(& &1.title)

  describe "suspend/3" do
    test "hides the actor's content but leaves the rest of its instance alone", ctx do
      {:ok, _} = RemoteActors.suspend(ctx.actor, nil, "harassment")

      # This is the whole reason the lever exists: blocking the domain would
      # have taken the neighbour with it.
      refute ctx.marker in titles(ctx.board)
      assert ctx.safe in titles(ctx.board)
    end

    test "records who suspended it and why" do
      admin = admin_user()
      actor = create_remote_actor("other.example", "someone")

      {:ok, suspended} = RemoteActors.suspend(actor, admin, "spam")

      assert suspended.suspended_at
      assert suspended.suspend_reason == "spam"
      assert suspended.suspended_by_id == admin.id
    end

    test "refuses to re-suspend, so the original decision keeps its date", ctx do
      {:ok, first} = RemoteActors.suspend(ctx.actor, nil, "harassment")

      assert {:error, :already_suspended} =
               RemoteActors.suspend(Repo.reload(first), nil, "something else")

      assert Repo.reload(first).suspend_reason == "harassment"
    end

    test "hides it from search too — the same predicate as a domain block", ctx do
      # Suspension and domain blocking share `Filters.hidden_actor_ids/0`. This
      # is what proves the sharing is real rather than two parallel filters
      # that will drift: search is a different query from a board listing, and
      # `search_articles/2` also backs the unauthenticated /ap/search.
      {:ok, _} = RemoteActors.suspend(ctx.actor, nil, "harassment")

      assert %{articles: []} = Content.search_articles(ctx.marker, user: nil)
      assert %{articles: [_]} = Content.search_articles(ctx.safe, user: nil)
    end

    test "deletes nothing", ctx do
      {:ok, _} = RemoteActors.suspend(ctx.actor, nil, "harassment")

      assert Repo.get(RemoteActor, ctx.actor.id)
      assert Repo.exists?(from a in Content.Article, where: a.remote_actor_id == ^ctx.actor.id)
    end
  end

  describe "unsuspend/1" do
    test "brings the content back with no repair step", ctx do
      {:ok, suspended} = RemoteActors.suspend(ctx.actor, nil, "harassment")
      refute ctx.marker in titles(ctx.board)

      {:ok, lifted} = RemoteActors.unsuspend(suspended)

      assert ctx.marker in titles(ctx.board)
      assert lifted.suspended_at == nil
      assert lifted.suspend_reason == nil
    end

    test "says so when the actor was not suspended", ctx do
      assert {:error, :not_suspended} = RemoteActors.unsuspend(ctx.actor)
    end
  end

  describe "the inbox" do
    test "refuses a suspended actor's activities", ctx do
      {:ok, suspended} = RemoteActors.suspend(ctx.actor, nil, "harassment")

      activity = %{
        "id" => "https://shared.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => suspended.ap_id,
        "object" => "https://local.example/ap/users/someone"
      }

      assert {:error, :actor_suspended} = InboxHandler.handle(activity, suspended, :shared)
    end

    test "still accepts the neighbour on the same instance", ctx do
      {:ok, _} = RemoteActors.suspend(ctx.actor, nil, "harassment")

      activity = %{
        "id" => "https://shared.example/activities/#{System.unique_integer([:positive])}",
        "type" => "Follow",
        "actor" => ctx.neighbour.ap_id,
        "object" => "https://local.example/ap/users/someone"
      }

      # Not :actor_suspended — it gets as far as the Follow handling.
      assert InboxHandler.handle(activity, ctx.neighbour, :shared) != {:error, :actor_suspended}
    end
  end

  describe "a refresh from the peer" do
    test "cannot clear the suspension", ctx do
      {:ok, _} = RemoteActors.suspend(ctx.actor, nil, "harassment")

      # `changeset/2` is what an actor refresh uses, and it rewrites every
      # profile field from what the peer sends. A moderation decision must not
      # be reachable from there.
      {:ok, refreshed} =
        ctx.actor
        |> Repo.reload()
        |> RemoteActor.changeset(%{
          display_name: "a new name",
          suspended_at: nil,
          suspend_reason: nil
        })
        |> Repo.update()

      assert refreshed.display_name == "a new name"
      assert refreshed.suspended_at
      assert RemoteActors.suspended?(refreshed)
    end
  end

  defp admin_user do
    role = Repo.one!(from r in Setup.Role, where: r.name == "admin")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "admin_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end
end
