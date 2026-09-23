defmodule Baudrate.AccountDeletionTest do
  @moduledoc """
  Acceptance gate for [ADR 0072](../../doc/adr/0072-a-deleted-account-leaves-a-tombstone.md):
  a member can delete their own account. The request needs step-up
  re-authentication and waits seven days; signing in cancels it. Carrying it
  out never deletes the user row — it becomes a tombstone, so nothing of
  anyone else's is lost — and the account's `Delete(Person)` is queued in the
  same transaction, to everyone elsewhere that has the account on record.
  """

  use BaudrateWeb.ConnCase, async: false

  import Ecto.Query

  alias Baudrate.AccountDeletion
  alias Baudrate.AccountDeletion.Deletion
  alias Baudrate.{Auth, Content, Federation, Messaging, Repo}
  alias Baudrate.Auth.{UserBlock, UserSession}
  alias Baudrate.Content.{Article, Board, Comment}
  alias Baudrate.Federation.{DeliveryJob, Follower, KeyStore, RemoteActor, UserFollow}
  alias Baudrate.Messaging.DirectMessage
  alias Baudrate.Notification.Notification
  alias Baudrate.Setup.User

  @password "Password123!x"

  setup do
    Repo.insert!(%Baudrate.Setup.Setting{key: "setup_completed", value: "true"})
    member = setup_user("user")
    {:ok, member} = KeyStore.ensure_user_keypair(member)
    %{member: member}
  end

  # --- fixtures -------------------------------------------------------------

  defp request!(user, opts \\ []) do
    {:ok, deletion} =
      AccountDeletion.request(
        user,
        %{password: @password},
        Keyword.merge([ip_address: "203.0.113.4"], opts)
      )

    deletion
  end

  # Makes the request due and runs the sweep, as the hourly step would.
  defp carry_out!(deletion) do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(d in Deletion, where: d.id == ^deletion.id),
      set: [execute_after: past]
    )

    AccountDeletion.sweep()
    Repo.reload!(deletion)
  end

  defp remote_actor(name) do
    uid = System.unique_integer([:positive])

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://#{name}.example/users/r#{uid}",
      username: "r#{uid}",
      domain: "#{name}.example",
      public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
      inbox: "https://#{name}.example/users/r#{uid}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp board do
    Repo.insert!(
      Board.changeset(%Board{}, %{
        name: "Deletion",
        slug: "deletion-#{System.unique_integer([:positive])}"
      })
    )
  end

  defp article(user, board) do
    {:ok, %{article: article}} =
      Content.create_article(
        %{
          title: "Article",
          body: "Body",
          slug: "del-#{System.unique_integer([:positive])}",
          user_id: user.id
        },
        [board.id]
      )

    article
  end

  defp comment(user, article) do
    {:ok, comment} =
      Content.create_comment(%{
        "body" => "a comment",
        "article_id" => article.id,
        "user_id" => user.id
      })

    comment
  end

  defp jobs(type) do
    Repo.all(from(j in DeliveryJob, select: {j.inbox_url, j.activity_json}))
    |> Enum.filter(fn {_inbox, json} -> Jason.decode!(json)["type"] == type end)
  end

  # --- requesting -----------------------------------------------------------

  describe "requesting" do
    test "needs the password", %{member: member} do
      assert {:error, :invalid_credentials} =
               AccountDeletion.request(member, %{password: "wrong"}, ip_address: "203.0.113.4")

      refute AccountDeletion.open(member.id)
    end

    test "refuses staff, board moderators and bots" do
      admin = setup_user("admin")
      moderator = setup_user("moderator")

      for user <- [admin, moderator] do
        assert {:error, :staff} =
                 AccountDeletion.request(user, %{password: @password}, ip_address: "203.0.113.4")
      end

      board_mod = setup_user("user")
      Repo.insert!(%Baudrate.Content.BoardModerator{board_id: board().id, user_id: board_mod.id})

      assert {:error, :board_moderator} =
               AccountDeletion.request(board_mod, %{password: @password},
                 ip_address: "203.0.113.4"
               )

      bot = setup_user("user")
      Repo.update_all(from(u in User, where: u.id == ^bot.id), set: [is_bot: true])
      assert {:error, :bot} = AccountDeletion.eligibility(Repo.reload!(bot))
    end

    test "signs out every other session, keeps the requesting one, and tells the member",
         %{member: member} do
      {:ok, token, _} = Auth.create_user_session(member.id)
      keep = Auth.session_id_by_token(token)
      {:ok, other_token, _} = Auth.create_user_session(member.id)
      other = Auth.session_id_by_token(other_token)

      deletion = request!(member, session_id: keep)

      assert deletion.status == "pending"
      assert DateTime.diff(deletion.execute_after, deletion.requested_at) == 7 * 86_400
      assert Repo.get(UserSession, keep)
      refute Repo.get(UserSession, other)

      assert [%{type: "account_deletion_requested"}] =
               Repo.all(from(n in Notification, where: n.user_id == ^member.id))
    end

    test "a second request is refused while one is open", %{member: member} do
      request!(member)

      assert {:error, :pending_deletion_exists} =
               AccountDeletion.request(member, %{password: @password}, ip_address: "203.0.113.4")
    end
  end

  # --- cancelling -----------------------------------------------------------

  describe "signing in" do
    test "cancels a pending deletion and says so", %{member: member} do
      deletion = request!(member)

      assert :cancelled = AccountDeletion.cancel_pending(member.id, "signed_in")
      assert %{status: "cancelled", cancel_reason: "signed_in"} = Repo.reload!(deletion)

      assert Repo.exists?(
               from(n in Notification,
                 where: n.user_id == ^member.id and n.type == "account_deletion_cancelled"
               )
             )

      assert :none = AccountDeletion.cancel_pending(member.id, "signed_in")
    end

    test "cannot cancel one the sweep has already claimed", %{member: member} do
      deletion = request!(member)

      Repo.update_all(from(d in Deletion, where: d.id == ^deletion.id),
        set: [status: "executing"]
      )

      assert :executing = AccountDeletion.cancel_pending(member.id, "signed_in")
    end
  end

  # --- carrying it out ------------------------------------------------------

  describe "the sweep" do
    test "does nothing before the seven days are up", %{member: member} do
      deletion = request!(member)

      assert AccountDeletion.sweep() == 0
      assert Repo.reload!(deletion).status == "pending"
      assert Repo.reload!(member).status == "active"
    end

    test "carries it out once, then never again", %{member: member} do
      deletion = carry_out!(request!(member))

      assert deletion.status == "completed"
      assert Repo.reload!(member).status == "deleted"
      assert AccountDeletion.sweep() == 0
    end

    test "a run that crashed after the claim is finished by the next", %{member: member} do
      deletion = request!(member)
      # What a crash between the claim and the tombstone leaves behind.
      Repo.update_all(from(d in Deletion, where: d.id == ^deletion.id),
        set: [status: "executing"]
      )

      assert AccountDeletion.sweep() == 1
      assert Repo.reload!(deletion).status == "completed"
      assert Repo.reload!(member).status == "deleted"
    end

    test "a member who became staff meanwhile is not deleted", %{member: member} do
      deletion = request!(member)
      moderator_role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "moderator"))

      Repo.update_all(from(u in User, where: u.id == ^member.id),
        set: [role_id: moderator_role.id]
      )

      assert carry_out!(deletion).status == "cancelled"
      assert Repo.reload!(member).status == "active"
    end
  end

  describe "the tombstone" do
    # Every column is either cleared or deliberately kept. A new personal
    # column fails this until it is put in one list or the other.
    @kept ~w(id username role_id is_bot status deleted_at inserted_at updated_at
             banned_at ban_reason moved_to moved_at invited_by_id terms_accepted_at
             terms_version ap_public_key ap_private_key_encrypted hashed_password
             dm_access totp_enabled)a

    test "clears everything personal and keeps only what is listed", %{member: member} do
      {:ok, member} = Auth.update_bio(member, "about me")
      {:ok, member} = Auth.update_time_zone(member, "Asia/Tokyo")
      carry_out!(request!(member))

      tombstone = Repo.reload!(member)
      assert tombstone.status == "deleted"
      assert tombstone.username == member.username
      assert tombstone.dm_access == "nobody"
      refute tombstone.totp_enabled

      for field <- User.__schema__(:fields) -- @kept do
        value = Map.fetch!(tombstone, field)

        assert value in [nil, [], %{}, false],
               "#{field} survives the tombstone as #{inspect(value)}: clear it in " <>
                 "User.tombstone_changeset/1, or add it to @kept if it is a record"
      end
    end

    test "the username stays reserved, and the password no longer signs in", %{member: member} do
      carry_out!(request!(member))

      assert {:error, :invalid_credentials} =
               Auth.authenticate_by_password(member.username, @password)

      role = Repo.one!(from(r in Baudrate.Setup.Role, where: r.name == "user"))

      assert {:error, changeset} =
               %User{}
               |> User.registration_changeset(%{
                 "username" => String.upcase(member.username),
                 "password" => @password,
                 "password_confirmation" => @password,
                 "role_id" => role.id
               })
               |> Repo.insert()

      assert Baudrate.DataCase.errors_on(changeset)[:username]
    end

    test "the interaction gate refuses it, with its own message", %{member: member} do
      carry_out!(request!(member))

      assert {:error, :account_deleted} = Auth.ensure_can_interact(member.id)

      assert BaudrateWeb.Helpers.refusal_message(:account_deleted, nil, "fallback") =~
               "deleted"
    end

    test "cannot be banned back to life", %{member: member} do
      carry_out!(request!(member))
      tombstone = Repo.reload!(member)

      refute User.unban_changeset(tombstone).valid?

      refute User.ban_changeset(tombstone, %{status: "banned", banned_at: DateTime.utc_now()}).valid?
    end
  end

  describe "federation" do
    test "Delete(Person) goes to followers, followed accounts and DM counterparts, in the tombstone transaction",
         %{member: member} do
      follower = remote_actor("follower")
      followed = remote_actor("followed")
      correspondent = remote_actor("dm")
      actor_uri = Federation.actor_uri(:user, member.username)

      {:ok, _} = Federation.create_follower(actor_uri, follower, "https://follower.example/f/1")

      Repo.insert!(%UserFollow{
        user_id: member.id,
        remote_actor_id: followed.id,
        state: "accepted",
        ap_id: "#{actor_uri}#follow-#{System.unique_integer([:positive])}"
      })

      {:ok, _conv} = Messaging.find_or_create_remote_conversation(member, correspondent)

      carry_out!(request!(member))

      delete_inboxes = jobs("Delete") |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert delete_inboxes ==
               Enum.sort([follower.inbox, followed.inbox, correspondent.inbox])

      assert [{inbox, _}] = jobs("Undo")
      assert inbox == followed.inbox
      refute Repo.exists?(from(f in Follower, where: f.actor_uri == ^actor_uri))
      refute Repo.exists?(from(f in UserFollow, where: f.user_id == ^member.id))
    end

    test "the key is kept for the deliveries, never regenerated, and cleared after",
         %{member: member} do
      follower = remote_actor("follower")
      actor_uri = Federation.actor_uri(:user, member.username)
      {:ok, _} = Federation.create_follower(actor_uri, follower, "https://follower.example/f/2")

      deletion = carry_out!(request!(member))
      tombstone = Repo.reload!(member)
      assert is_binary(tombstone.ap_public_key)

      old = DateTime.utc_now() |> DateTime.add(-31 * 86_400) |> DateTime.truncate(:second)

      Repo.update_all(from(d in Deletion, where: d.id == ^deletion.id),
        set: [completed_at: old]
      )

      # A Delete still waiting keeps the key.
      assert AccountDeletion.sweep_keys() == 0

      Repo.update_all(from(j in DeliveryJob, where: j.actor_uri == ^actor_uri),
        set: [status: "delivered"]
      )

      assert AccountDeletion.sweep_keys() == 1
      cleared = Repo.reload!(member)
      assert is_nil(cleared.ap_public_key)
      assert {:error, :account_deleted} = KeyStore.ensure_user_keypair(cleared)
      assert {:error, :account_deleted} = Baudrate.Federation.Delivery.get_private_key(actor_uri)
    end
  end

  describe "content" do
    test "without the tick, posts stay under the tombstone and nothing of anyone else's goes",
         %{member: member} do
      other = setup_user("user")
      board = board()
      article = article(member, board)
      theirs = comment(other, article)
      mine = comment(member, article)

      carry_out!(request!(member))

      assert is_nil(Repo.reload!(article).deleted_at)
      assert is_nil(Repo.reload!(mine).deleted_at)
      assert is_nil(Repo.reload!(theirs).deleted_at)
      assert Repo.reload!(article).user_id == member.id
    end

    test "with the tick, the member's articles and comments are withdrawn as theirs",
         %{member: member} do
      board = board()
      article = article(member, board)
      mine = comment(member, article(setup_user("user"), board))

      carry_out!(request!(member, withdraw_content: true))

      assert %Article{deleted_at: %DateTime{}, deleted_by_id: by} = Repo.reload!(article)
      assert by == member.id
      assert %Comment{deleted_at: %DateTime{}} = Repo.reload!(mine)
    end

    test "the text of the member's direct messages always goes", %{member: member} do
      other = setup_user("user")
      {:ok, conv} = Messaging.find_or_create_conversation(member, other)
      {:ok, sent} = Messaging.create_message(conv, member, %{body: "private words"})
      {:ok, received} = Messaging.create_message(conv, other, %{body: "their words"})

      carry_out!(request!(member))

      assert %DirectMessage{deleted_at: %DateTime{}, body: "[deleted]"} = Repo.reload!(sent)
      assert Repo.reload!(received).body == "their words"
    end

    test "only the member's own blocks go; other members' blocks of them stay", %{member: member} do
      other = setup_user("user")
      {:ok, _} = Auth.block_user(member, other)
      {:ok, _} = Auth.block_user(other, member)

      carry_out!(request!(member))

      refute Repo.exists?(from(b in UserBlock, where: b.user_id == ^member.id))
      assert Repo.exists?(from(b in UserBlock, where: b.user_id == ^other.id))
    end
  end
end
