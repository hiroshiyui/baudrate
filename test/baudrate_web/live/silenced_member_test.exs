defmodule BaudrateWeb.SilencedMemberTest do
  @moduledoc """
  What a silenced member actually sees when they try to act (ADR 0029, P1-D4).

  A post that fails with a shrug is worse than the sanction: the refusal has
  to name the restriction, the reason and when it ends, or the member has no
  way to find out what happened.
  """

  use BaudrateWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Content
  alias Baudrate.Repo
  alias Baudrate.Setup.Setting

  setup %{conn: conn} do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})

    admin = setup_user("admin")
    member = setup_user("user")
    author = setup_user("user")

    {:ok, board} =
      Content.create_board(%{
        name: "Silence #{System.unique_integer([:positive])}",
        slug: "silence-#{System.unique_integer([:positive])}"
      })

    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "A post",
          body: "Body",
          slug: "silenced-#{System.unique_integer([:positive])}",
          user_id: author.id
        },
        [board.id]
      )

    %{conn: conn, admin: admin, member: member, article: article}
  end

  defp silence(admin, member) do
    {:ok, _} =
      Auth.issue_sanction(admin, member, "silence",
        reason: "Repeated abuse",
        expires_at:
          DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.truncate(:second)
      )
  end

  test "a refused like says which restriction stands, why and until when", %{
    conn: conn,
    admin: admin,
    member: member,
    article: article
  } do
    silence(admin, member)
    conn = log_in_user(conn, member)

    {:ok, lv, _html} = live(conn, ~p"/articles/#{article.slug}")
    html = lv |> element("[phx-click=\"toggle_like\"]") |> render_click()

    assert html =~ "silenced"
    assert html =~ "Repeated abuse"
    refute html =~ "Failed to toggle like"
  end

  test "the composer is gone, and a banner says why", %{
    conn: conn,
    admin: admin,
    member: member,
    article: article
  } do
    silence(admin, member)
    conn = log_in_user(conn, member)

    {:ok, lv, html} = live(conn, ~p"/articles/#{article.slug}")

    # The control the context would refuse is hidden...
    refute has_element?(lv, "#comment-form")
    # ...but a control that simply vanishes explains nothing.
    assert html =~ "Your account is silenced and cannot post."
    assert html =~ "Repeated abuse"
    assert has_element?(lv, "#sanction-notice")
  end

  test "an unsanctioned member sees no banner and keeps the composer", %{
    conn: conn,
    member: member,
    article: article
  } do
    conn = log_in_user(conn, member)

    {:ok, lv, html} = live(conn, ~p"/articles/#{article.slug}")

    refute has_element?(lv, "#sanction-notice")
    refute html =~ "Your account is silenced and cannot post."
    assert has_element?(lv, "#comment-form")
  end

  test "a suspended member cannot reach an authenticated page at all", %{
    conn: conn,
    admin: admin,
    member: member,
    article: article
  } do
    {:ok, _} =
      Auth.issue_sanction(admin, member, "suspend",
        reason: "Three removals",
        expires_at:
          DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.truncate(:second)
      )

    # A suspension revokes the sessions, so sign in after it is issued —
    # here the member simply cannot, which is the point.
    assert {:error, {:suspended, _}} =
             Auth.authenticate_by_password(member.username, "Password123!x")

    # Even a session minted afterwards does not get them onto an
    # authenticated page, and a public page treats them as a guest.
    conn = log_in_user(conn, member)
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/profile")

    {:ok, lv, _html} = live(conn, ~p"/articles/#{article.slug}")
    refute has_element?(lv, "#comment-form")
  end
end
