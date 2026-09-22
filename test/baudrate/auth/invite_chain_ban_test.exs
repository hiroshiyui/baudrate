defmodule Baudrate.Auth.InviteChainBanTest do
  @moduledoc """
  The acceptance gate for banning an account and the accounts it invited
  (Phase 5A).

  The dialog's checkboxes are client-supplied, so the gate is mostly about what
  the context refuses to do with them: ban an account outside the chain,
  overrule the rank rule, or overwrite a ban that was already there.
  """
  use BaudrateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.Auth
  alias Baudrate.Moderation.Log
  alias Baudrate.Repo
  alias Baudrate.Setup.{Setting, User}

  defp invited_by!(user, inviter) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [invited_by_id: inviter.id])
    Repo.get!(User, user.id) |> Repo.preload(:role)
  end

  # root → a → b → c, plus a second child of root.
  defp chain do
    root = setup_user("user")
    a = setup_user("user") |> invited_by!(root)
    sibling = setup_user("user") |> invited_by!(root)
    b = setup_user("user") |> invited_by!(a)
    c = setup_user("user") |> invited_by!(b)
    %{root: root, a: a, sibling: sibling, b: b, c: c}
  end

  defp status(user), do: Repo.get!(User, user.id).status

  describe "invite_tree/1" do
    test "walks the chain, level by level" do
      %{root: root, a: a, sibling: sibling, b: b, c: c} = chain()

      %{nodes: nodes, truncated: false} = Auth.invite_tree(root.id)
      depths = Map.new(nodes, &{&1.user.id, &1.depth})

      assert depths == %{a.id => 1, sibling.id => 1, b.id => 2, c.id => 3}
    end

    test "counts what each account has written, so an empty account can be told apart" do
      %{root: root, a: a} = chain()

      board =
        %Baudrate.Content.Board{}
        |> Baudrate.Content.Board.changeset(%{name: "B", slug: "chain-ban-board"})
        |> Repo.insert!()

      {:ok, _} =
        Baudrate.Content.create_article(
          %{title: "Hi", body: "x", slug: "chain-ban-post", user_id: a.id},
          [board.id]
        )

      %{nodes: nodes} = Auth.invite_tree(root.id)
      assert Enum.find(nodes, &(&1.user.id == a.id)).post_count == 1
    end

    test "stops at the depth bound and says so" do
      root = setup_user("user")

      Enum.reduce(1..7, root, fn _, parent -> setup_user("user") |> invited_by!(parent) end)

      %{nodes: nodes, truncated: truncated} = Auth.invite_tree(root.id)
      assert truncated
      assert Enum.max_by(nodes, & &1.depth).depth == 5
    end

    test "an account that invited nobody has an empty tree" do
      assert %{nodes: [], truncated: false} = Auth.invite_tree(setup_user("user").id)
    end
  end

  describe "ban_invite_chain/4" do
    setup do
      Map.put(chain(), :admin, setup_user("admin"))
    end

    test "bans exactly what was selected", %{admin: admin, root: root, a: a, b: b, c: c} do
      {:ok, %{banned: banned, refused: []}} =
        Auth.ban_invite_chain(root, [root.id, b.id], admin, "wave")

      assert Enum.map(banned, & &1.id) |> Enum.sort() == Enum.sort([root.id, b.id])
      assert status(root) == "banned"
      assert status(b) == "banned"
      assert status(a) == "active"
      assert status(c) == "active"
    end

    test "an id outside the chain is dropped, not banned", %{admin: admin, root: root} do
      # The checkbox values come from the page. Without the intersection the
      # dialog would be a way to ban any account by editing one.
      bystander = setup_user("user")

      {:ok, %{banned: banned}} = Auth.ban_invite_chain(root, [bystander.id], admin, nil)

      assert banned == []
      assert status(bystander) == "active"
    end

    test "the rank rule holds per account, and the rest are still banned",
         %{admin: admin, root: root, a: a} do
      staff = setup_user("admin") |> invited_by!(root)

      {:ok, %{banned: banned, refused: refused}} =
        Auth.ban_invite_chain(root, [a.id, staff.id], admin, nil)

      assert Enum.map(banned, & &1.id) == [a.id]
      assert [{%User{id: staff_id}, :role_too_high}] = refused
      assert staff_id == staff.id
      assert status(staff) == "active"
    end

    test "an account already banned keeps its original ban", %{admin: admin, root: root, a: a} do
      {:ok, _, _} = Auth.ban_user(a, admin, "the original reason")

      {:ok, %{refused: refused}} = Auth.ban_invite_chain(root, [a.id], admin, "a later reason")

      assert [{_, :already_banned}] = refused
      assert Repo.get!(User, a.id).ban_reason == "the original reason"
    end

    test "writes a per-account entry and one for the action as a whole",
         %{admin: admin, root: root, a: a, b: b} do
      {:ok, _} = Auth.ban_invite_chain(root, [a.id, b.id], admin, "wave")

      per_account =
        Repo.all(from(l in Log, where: l.action == "ban_user", select: l.target_id))

      assert Enum.sort(per_account) == Enum.sort([a.id, b.id])

      summary = Repo.get_by!(Log, action: "ban_invite_chain", target_id: root.id)
      assert summary.actor_id == admin.id
      assert Enum.sort(summary.details["banned"]) == Enum.sort([a.username, b.username])
    end

    test "a moderator without admin.manage_users bans nobody", %{root: root, a: a} do
      moderator = setup_user("moderator")

      {:ok, %{banned: [], refused: [{_, :unauthorized}]}} =
        Auth.ban_invite_chain(root, [a.id], moderator, nil)

      assert status(a) == "active"
    end
  end

  describe "the dialog on /admin/users/:id" do
    setup %{conn: conn} do
      Repo.insert!(%Setting{key: "setup_completed", value: "true"})
      admin = setup_user("admin")
      {:ok, Map.merge(chain(), %{conn: log_in_admin(conn, admin), admin: admin})}
    end

    test "opens with nothing ticked", %{conn: conn, root: root, a: a, b: b} do
      {:ok, lv, _} = live(conn, "/admin/users/#{root.id}")

      html = lv |> element("#admin-user-detail-chain-ban-open") |> render_click()

      assert html =~ a.username
      assert html =~ b.username
      refute html =~ ~r/admin-user-detail-chain-ban-check[^>]*checked/
    end

    test "bans what is ticked and nothing else", %{conn: conn, root: root, a: a, c: c} do
      {:ok, lv, _} = live(conn, "/admin/users/#{root.id}")
      lv |> element("#admin-user-detail-chain-ban-open") |> render_click()

      lv
      |> form("#admin-user-detail-chain-ban-form", %{
        "selected" => [to_string(a.id)],
        "reason" => "signup wave"
      })
      |> render_submit()

      assert status(a) == "banned"
      assert status(c) == "active"
      assert status(root) == "active"
    end

    test "the reason survives ticking a box", %{conn: conn, root: root, a: a} do
      # The LiveView input-reset trap: the checkboxes and the reason share a
      # form, so ticking one re-renders the form. The reason must come back.
      {:ok, lv, _} = live(conn, "/admin/users/#{root.id}")
      lv |> element("#admin-user-detail-chain-ban-open") |> render_click()

      html =
        lv
        |> form("#admin-user-detail-chain-ban-form", %{
          "selected" => [to_string(a.id)],
          "reason" => "typed before ticking"
        })
        |> render_change()

      assert html =~ "typed before ticking"
    end
  end
end
