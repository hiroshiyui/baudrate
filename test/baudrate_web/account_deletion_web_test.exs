defmodule BaudrateWeb.AccountDeletionWebTest do
  @moduledoc """
  What a deleted account looks like from outside (ADR 0072): gone over
  ActivityPub (410, with the key while its last deliveries go out), 404 as a
  profile, "deleted account" as an author with no link; and the page that
  requests it, the sign-out that follows, and the sign-in that cancels it.
  A banned account, meanwhile, is served bare over ActivityPub.
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Baudrate.AccountDeletion
  alias Baudrate.AccountDeletion.Deletion
  alias Baudrate.{Auth, Content, Federation, Repo}
  alias Baudrate.Content.Board
  alias Baudrate.Federation.KeyStore
  alias Baudrate.Setup.{Setting, User}

  @password "Password123!x"
  @ap "application/activity+json"

  setup do
    Repo.insert!(%Setting{key: "setup_completed", value: "true"})
    Repo.insert!(%Setting{key: "ap_federation_enabled", value: "true"})
    member = setup_user("user")
    {:ok, member} = KeyStore.ensure_user_keypair(member)
    %{member: member}
  end

  defp delete!(user) do
    {:ok, deletion} =
      AccountDeletion.request(user, %{password: @password}, ip_address: "203.0.113.4")

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(d in Deletion, where: d.id == ^deletion.id), set: [execute_after: past])
    AccountDeletion.sweep()
    Repo.reload!(user)
  end

  defp ap_get(path), do: build_conn() |> put_req_header("accept", @ap) |> get(path)

  describe "over ActivityPub" do
    test "the actor answers 410 with a Tombstone that still carries the key", %{member: member} do
      tombstone = delete!(member)
      conn = ap_get("/ap/users/#{member.username}")

      assert conn.status == 410
      body = Jason.decode!(conn.resp_body)
      assert body["type"] == "Tombstone"
      assert body["formerType"] == "Person"
      assert body["publicKey"]["publicKeyPem"] == tombstone.ap_public_key
      refute body["name"]
    end

    test "after the key sweep the Tombstone is plain and no key is minted", %{member: member} do
      delete!(member)

      Repo.update_all(from(u in User, where: u.id == ^member.id),
        set: [ap_public_key: nil, ap_private_key_encrypted: nil]
      )

      conn = ap_get("/ap/users/#{member.username}")
      assert conn.status == 410
      refute Jason.decode!(conn.resp_body)["publicKey"]
      assert is_nil(Repo.reload!(member).ap_public_key)
    end

    test "its collections and WebFinger are gone too", %{member: member} do
      delete!(member)

      for path <- ~w(outbox followers following) do
        assert ap_get("/ap/users/#{member.username}/#{path}").status == 410
      end

      host = URI.parse(Federation.base_url()).host
      conn = get(build_conn(), "/.well-known/webfinger?resource=acct:#{member.username}@#{host}")
      assert conn.status == 410
    end

    test "a banned account is served bare, with an empty outbox" do
      banned = setup_user("user")
      {:ok, banned} = KeyStore.ensure_user_keypair(banned)
      {:ok, banned} = Auth.update_bio(banned, "a bio nobody should see")

      Repo.update_all(from(u in User, where: u.id == ^banned.id),
        set: [status: "banned", display_name: "Shown Name"]
      )

      actor = Jason.decode!(ap_get("/ap/users/#{banned.username}").resp_body)
      assert actor["type"] == "Person"
      assert actor["publicKey"]
      refute actor["name"]
      refute actor["summary"]

      outbox = Jason.decode!(ap_get("/ap/users/#{banned.username}/outbox").resp_body)
      assert outbox["totalItems"] == 0
    end
  end

  describe "on the site" do
    test "the profile answers 404, as for an account that never existed", %{member: member} do
      delete!(member)

      assert_error_sent 404, fn -> get(build_conn(), "/users/#{member.username}") end
    end

    test "a kept article is by \"deleted account\", with no link to the old profile",
         %{member: member} do
      board =
        Repo.insert!(
          Board.changeset(%Board{}, %{name: "B", slug: "b-#{System.unique_integer([:positive])}"})
        )

      Repo.update_all(from(b in Board, where: b.id == ^board.id),
        set: [min_role_to_view: "guest"]
      )

      {:ok, %{article: article}} =
        Content.create_article(
          %{
            title: "Kept",
            body: "Body",
            slug: "kept-#{System.unique_integer([:positive])}",
            user_id: member.id
          },
          [board.id]
        )

      delete!(member)

      {:ok, lv, html} = live(build_conn(), "/articles/#{article.slug}")
      assert has_element?(lv, ".article-author", "deleted account")
      refute html =~ ~s(href="/users/#{member.username}")
    end
  end

  describe "requesting it from /profile/account" do
    test "the form signs this session out through the trigger", %{conn: conn, member: member} do
      conn = log_in_user(conn, member)
      {:ok, lv, _html} = live(conn, "/profile/account")

      lv
      |> form("#account-deletion-form",
        deletion: %{password: @password, withdraw_content: "true"}
      )
      |> render_submit()

      assert %Deletion{status: "pending", withdraw_content: true} =
               AccountDeletion.open(member.id)

      assert has_element?(lv, "#account-deletion-signout-form[phx-trigger-action]")
    end

    test "a wrong password requests nothing", %{conn: conn, member: member} do
      {:ok, lv, _html} = live(log_in_user(conn, member), "/profile/account")

      html =
        lv
        |> form("#account-deletion-form", deletion: %{password: "wrong"})
        |> render_submit()

      assert html =~ "Invalid credentials"
      refute AccountDeletion.open(member.id)
    end

    test "staff are told why they cannot", %{conn: conn} do
      moderator = setup_user("moderator")
      {:ok, lv, _html} = live(log_in_user(conn, moderator), "/profile/account")

      assert has_element?(lv, "#profile-account-deletion-ineligible", "demoted")
      refute has_element?(lv, "#account-deletion-form")
    end

    test "the sign-out ends the session and gives the date", %{conn: conn, member: member} do
      conn = log_in_user(conn, member)
      token = get_session(conn, :session_token)

      {:ok, _} =
        AccountDeletion.request(member, %{password: @password},
          ip_address: "203.0.113.4",
          session_id: Auth.session_id_by_token(token)
        )

      conn = post(conn, "/account/deletion-requested")

      assert redirected_to(conn) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "will be deleted on"
      assert Auth.session_id_by_token(token) == nil
    end
  end

  describe "signing in" do
    test "cancels the pending deletion and says so", %{conn: conn, member: member} do
      {:ok, _} =
        AccountDeletion.request(member, %{password: @password}, ip_address: "203.0.113.4")

      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", member.id)

      conn = post(conn, "/auth/session", %{"token" => token})

      assert get_session(conn, :session_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "deletion has been cancelled"
      refute AccountDeletion.open(member.id)
    end

    test "is refused while the deletion is being carried out", %{conn: conn, member: member} do
      {:ok, deletion} =
        AccountDeletion.request(member, %{password: @password}, ip_address: "203.0.113.4")

      Repo.update_all(from(d in Deletion, where: d.id == ^deletion.id),
        set: [status: "executing"]
      )

      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", member.id)

      conn = post(conn, "/auth/session", %{"token" => token})

      assert redirected_to(conn) == "/login"
      refute get_session(conn, :session_token)
    end

    test "a deleted account cannot finish a sign-in begun before it was deleted",
         %{conn: conn, member: member} do
      token = Phoenix.Token.sign(BaudrateWeb.Endpoint, "user_auth", member.id)
      delete!(member)

      conn = post(conn, "/auth/session", %{"token" => token})

      assert redirected_to(conn) == "/login"
      refute get_session(conn, :session_token)
    end
  end
end
