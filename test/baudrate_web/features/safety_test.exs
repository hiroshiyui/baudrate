defmodule BaudrateWeb.Features.SafetyTest do
  use BaudrateWeb.FeatureCase, async: false

  import Ecto.Query

  alias Baudrate.{Federation, Repo}
  alias Baudrate.Auth.{UserBlock, UserMute}
  alias Baudrate.Content.Comment
  alias Baudrate.Federation.RemoteActor
  alias Baudrate.Moderation.Report

  @moduletag :feature

  feature "a member blocks someone from their profile, which stops their comments, then unblocks",
          %{session: session} do
    member = setup_user("user")
    other = setup_user("user")
    article = create_article(member, create_board(%{}), %{title: "My article"})

    session
    |> log_in_via_browser(member)
    |> visit("/users/#{other.username}")
    |> accept_confirms()
    |> click(Query.css("#user-profile-more-actions"))
    |> click(Query.css("#user-profile-block"))
    |> assert_has(Query.text("User blocked."))

    start_another_session()
    |> log_in_via_browser(other)
    |> visit("/articles/#{article.slug}")
    |> fill_in(Query.css("#comment_body"), with: "Can you hear me?")
    |> click(Query.button("Post Comment"))
    |> assert_has(Query.text("You cannot interact with this account."))

    refute Repo.exists?(from(c in Comment, where: c.article_id == ^article.id))
    block = Repo.get_by!(UserBlock, user_id: member.id, blocked_user_id: other.id)

    session
    |> visit("/profile/privacy")
    |> assert_has(Query.css("#blocked-account-#{block.id}", text: other.username))
    |> click(Query.css("#blocked-account-unblock-#{block.id}"))
    |> assert_has(Query.css("#profile-blocked-accounts-empty"))

    refute Repo.exists?(from(b in UserBlock, where: b.id == ^block.id))
  end

  feature "muting a member hides their articles from a board until unmuted", %{
    session: session
  } do
    member = setup_user("user")
    noisy = setup_user("user")
    board = create_board(%{})
    create_article(noisy, board, %{title: "Loud opinions"})

    session
    |> log_in_via_browser(member)
    |> visit("/boards/#{board.slug}")
    |> assert_has(Query.text("Loud opinions"))
    |> visit("/users/#{noisy.username}")
    |> accept_confirms()
    |> click(Query.css("#user-profile-mute"))
    |> assert_has(Query.text("User muted."))
    |> visit("/boards/#{board.slug}")
    |> refute_has(Query.text("Loud opinions"))

    mute = Repo.get_by!(UserMute, user_id: member.id, muted_user_id: noisy.id)

    session
    |> visit("/profile/privacy")
    |> click(Query.css("#muted-user-unmute-#{mute.id}"))
    |> refute_has(Query.css("#muted-user-#{mute.id}"))
    |> visit("/boards/#{board.slug}")
    |> assert_has(Query.text("Loud opinions"))
  end

  feature "a remote post's menu reports it and mutes its account", %{session: session} do
    member = setup_user("user")
    {actor, [item | _]} = followed_remote_actor_with_posts(member)

    session =
      session
      |> log_in_via_browser(member)
      |> visit("/timeline")
      |> click(Query.css("#timeline-item-actions-menu-toggle-#{item.id}"))
      |> click(Query.css("#timeline-item-report-#{item.id}"))
      |> click(Query.css("#report-category option[value=harassment]"))
      |> fill_in(Query.css("#report-reason"), with: "Harassment")
      |> click(Query.css("#report-modal .report-modal-submit"))
      |> assert_has(Query.text("Report submitted. Thank you."))

    assert Repo.exists?(
             from(r in Report,
               where: r.timeline_item_id == ^item.id and r.reporter_id == ^member.id
             )
           )

    session
    |> accept_confirms()
    |> click(Query.css("#timeline-item-actions-menu-toggle-#{item.id}"))
    |> click(Query.css("#timeline-item-#{item.id}-mute-actor"))
    |> assert_has(Query.text("Account muted."))
    |> refute_has(Query.css("#timeline-item-fi-#{item.id}"))

    assert Repo.get_by(UserMute, user_id: member.id, muted_actor_ap_id: actor.ap_id)
  end

  # Confirmation prompts (data-confirm) go through window.confirm.
  defp accept_confirms(session), do: execute_script(session, "window.confirm = () => true")

  defp followed_remote_actor_with_posts(user) do
    uid = System.unique_integer([:positive])

    actor =
      %RemoteActor{}
      |> RemoteActor.changeset(%{
        ap_id: "https://remote.example/users/safety-#{uid}",
        username: "safety_#{uid}",
        domain: "remote.example",
        public_key_pem: "-----BEGIN PUBLIC KEY-----\nfake\n-----END PUBLIC KEY-----",
        inbox: "https://remote.example/users/safety-#{uid}/inbox",
        actor_type: "Person",
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    {:ok, follow} = Federation.create_user_follow(user, actor)
    {:ok, _} = Federation.accept_user_follow(follow.ap_id)

    items =
      for n <- 1..2 do
        {:ok, item} =
          Federation.create_timeline_item(%{
            remote_actor_id: actor.id,
            activity_type: "Create",
            object_type: "Note",
            ap_id: "https://remote.example/notes/safety-#{uid}-#{n}",
            body: "Remote post #{n}",
            body_html: "<p>Remote post #{n}</p>",
            source_url: "https://remote.example/notes/safety-#{uid}-#{n}",
            published_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        item
      end

    {actor, items}
  end
end
