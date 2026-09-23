defmodule BaudrateWeb.Helpers do
  @moduledoc """
  Shared helper functions for LiveView and controller parameter handling.
  """

  use BaudrateWeb, :verified_routes
  use Gettext, backend: BaudrateWeb.Gettext

  @doc """
  Formats a NaiveDateTime/DateTime in the viewer's time zone.

  That is the member's own `time_zone` when they chose one, and otherwise the
  site's `timezone` setting (`BaudrateWeb.TimeZone`); a zone the tz database
  no longer knows falls back rather than raising. A `NaiveDateTime` is taken
  as UTC, which is what every stored timestamp here is.

  ## Examples

      iex> BaudrateWeb.Helpers.format_datetime(~N[2026-01-15 08:30:00])
      "2026-01-15 08:30"

      iex> BaudrateWeb.Helpers.format_datetime(~N[2026-01-15 08:30:00], "%Y-%m-%d")
      "2026-01-15"
  """
  def format_datetime(datetime, format \\ "%Y-%m-%d %H:%M")

  def format_datetime(nil, _format), do: ""

  def format_datetime(%NaiveDateTime{} = ndt, format) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime(format)
  end

  def format_datetime(%DateTime{} = dt, format) do
    dt
    |> BaudrateWeb.TimeZone.shift()
    |> Calendar.strftime(format)
  end

  @doc """
  Returns the value for an HTML `<time datetime>` attribute: ISO 8601 in UTC,
  ending in `Z`, whoever is reading.

  It used to be the site's local time with no offset, which a machine
  reading the page could only take for UTC — wrong by the site's offset for
  everyone.

  ## Examples

      iex> BaudrateWeb.Helpers.datetime_attr(~N[2026-01-15 08:30:00])
      "2026-01-15T08:30:00Z"

      iex> BaudrateWeb.Helpers.datetime_attr(nil)
      ""
  """
  def datetime_attr(nil), do: ""

  def datetime_attr(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> datetime_attr()

  def datetime_attr(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc """
  Formats a date only (no time portion).

  ## Examples

      iex> BaudrateWeb.Helpers.format_date(~N[2026-01-15 08:30:00])
      "2026-01-15"
  """
  def format_date(datetime) do
    format_datetime(datetime, "%Y-%m-%d")
  end

  @doc """
  Safely parses a string parameter to a positive integer.
  Returns `{:ok, integer}` on success, `:error` on failure.

  ## Examples

      iex> BaudrateWeb.Helpers.parse_id("42")
      {:ok, 42}

      iex> BaudrateWeb.Helpers.parse_id("abc")
      :error

      iex> BaudrateWeb.Helpers.parse_id("-1")
      :error

      iex> BaudrateWeb.Helpers.parse_id("0")
      :error
  """
  def parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  def parse_id(_), do: :error

  @doc """
  Parses a page number from a string parameter.
  Returns 1 for nil, invalid, or non-positive values.

  ## Examples

      iex> BaudrateWeb.Helpers.parse_page("3")
      3

      iex> BaudrateWeb.Helpers.parse_page(nil)
      1

      iex> BaudrateWeb.Helpers.parse_page("abc")
      1
  """
  def parse_page(nil), do: 1

  def parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  @doc """
  Evaluates password strength criteria for UI feedback.

  Returns a map of boolean flags for each criterion:
  `:length`, `:lowercase`, `:uppercase`, `:digit`, `:special`.
  """
  def password_strength(password) do
    %{
      length: String.length(password) >= 12,
      lowercase: Regex.match?(~r/[a-z]/, password),
      uppercase: Regex.match?(~r/[A-Z]/, password),
      digit: Regex.match?(~r/[0-9]/, password),
      special: Regex.match?(~r/[^a-zA-Z0-9]/, password)
    }
  end

  @doc """
  Translates a file upload error to a human-readable string.

  Accepts optional keyword options:
  - `:max_size` — display string for the max file size (e.g. `"5 MB"`)
  - `:max_files` — display value for the max number of files

  ## Examples

      iex> BaudrateWeb.Helpers.upload_error_to_string(:too_large, max_size: "5 MB")
      "File too large (max 5 MB)"

      iex> BaudrateWeb.Helpers.upload_error_to_string(:not_accepted)
      "File type not accepted"
  """
  def upload_error_to_string(error, opts \\ [])

  def upload_error_to_string(:too_large, opts) do
    case Keyword.get(opts, :max_size) do
      nil -> gettext("File too large")
      size -> gettext("File too large (max %{size})", size: size)
    end
  end

  def upload_error_to_string(:too_many_files, opts) do
    case Keyword.get(opts, :max_files) do
      nil -> gettext("Too many files")
      n -> gettext("Too many files (max %{n})", n: n)
    end
  end

  def upload_error_to_string(:not_accepted, _opts), do: gettext("File type not accepted")
  def upload_error_to_string(_, _opts), do: gettext("Upload error")

  @doc """
  Translates a role name to a localized display string.
  """
  def translate_role("admin"), do: gettext("admin")
  def translate_role("moderator"), do: gettext("moderator")
  def translate_role("user"), do: gettext("user")
  def translate_role("guest"), do: gettext("guest")
  def translate_role(other), do: other

  @doc """
  Returns the canonical display timestamp for an article.

  Uses `published_at` when present (bot/federated articles with an original
  publication date), falling back to `inserted_at` for regular user articles.
  """
  def article_datetime(%{published_at: published_at}) when not is_nil(published_at),
    do: published_at

  def article_datetime(%{inserted_at: inserted_at}), do: inserted_at

  @doc """
  The accessible name for a gallery image's link.

  Gallery images are always rendered inside an `<a>` that opens the full-size
  file, so **the link carries the description and the `<img>` is `alt=""`**.
  Putting text in both announced the same image twice — "Image 2 (opens in new
  tab)", then "Image 2" — which is what every gallery did before descriptions
  existed.

  The description is the uploader's own when they wrote one
  (`Baudrate.Content.ImageAlt`), and falls back to the image's position in the
  gallery when they did not. A position is a poor description, but it is an
  honest one: it says which of the four images this is and claims nothing
  about what is in it.
  """
  @spec image_link_label(map(), list()) :: String.t()
  def image_link_label(image, images) do
    case Baudrate.Content.ImageAlt.describe(image) do
      nil ->
        gettext("Image %{number} (opens in new tab)", number: image_position(image, images))

      description ->
        gettext("%{description} (opens in new tab)", description: description)
    end
  end

  defp image_position(image, images) do
    case Enum.find_index(images, &(&1.id == image.id)) do
      nil -> 1
      index -> index + 1
    end
  end

  @doc """
  Returns a human-friendly display name for a user or remote actor.

  Falls back to `username` when `display_name` is nil or empty. An account
  that deleted itself is "deleted account", never its old name (ADR 0072).
  """
  def display_name(%Baudrate.Setup.User{status: "deleted"}), do: gettext("deleted account")

  def display_name(%Baudrate.Setup.User{display_name: dn})
      when is_binary(dn) and dn != "",
      do: dn

  def display_name(%Baudrate.Setup.User{username: username}), do: username

  def display_name(%Baudrate.Federation.RemoteActor{display_name: dn})
      when is_binary(dn) and dn != "",
      do: dn

  def display_name(%Baudrate.Federation.RemoteActor{username: username}), do: username

  @doc """
  The path of a local user's profile, or `nil` for an account that deleted
  itself — its profile is gone, so an author link renders as plain text
  (ADR 0072). Every template that links an author uses this.
  """
  def author_path(%Baudrate.Setup.User{status: "deleted"}), do: nil
  def author_path(%Baudrate.Setup.User{username: username}), do: ~p"/users/#{username}"
  def author_path(_), do: nil

  @doc """
  Returns the best profile URL for a remote actor.

  Prefers the human-friendly `url` field (e.g. `https://mastodon.social/@user`),
  falling back to `ap_id` (e.g. `https://mastodon.social/users/user`).
  """
  def remote_actor_profile_url(%Baudrate.Federation.RemoteActor{url: url})
      when is_binary(url) and url != "",
      do: url

  def remote_actor_profile_url(%Baudrate.Federation.RemoteActor{ap_id: ap_id}), do: ap_id

  @doc """
  Returns a display name for a conversation participant.

  Local users show their display name; remote actors show `display_name` or `username@domain`.
  """
  def participant_name(%Baudrate.Setup.User{} = user), do: display_name(user)

  def participant_name(%Baudrate.Federation.RemoteActor{} = actor),
    do: "#{display_name(actor)}@#{actor.domain}"

  def participant_name(_), do: "?"

  @doc """
  Returns the fediverse handle for a local user or board.

  ## Examples

      iex> fediverse_handle(%User{username: "alice"})
      "@alice@baudrate.tw"

      iex> fediverse_handle(%Board{slug: "sysop"})
      "@sysop@baudrate.tw"

  """
  def fediverse_handle(%Baudrate.Setup.User{username: username}) do
    host = URI.parse(BaudrateWeb.Endpoint.url()).host
    "@#{username}@#{host}"
  end

  def fediverse_handle(%Baudrate.Content.Board{slug: slug}) do
    host = URI.parse(BaudrateWeb.Endpoint.url()).host
    "@#{slug}@#{host}"
  end

  @doc """
  Translates a user status to a localized display string.
  """
  def translate_status("active"), do: gettext("active")
  def translate_status("pending"), do: gettext("pending")
  def translate_status("banned"), do: gettext("banned")
  def translate_status("deleted"), do: gettext("deleted")
  def translate_status(other), do: other

  @doc """
  Translates a content visibility value (`public`, `unlisted`,
  `followers_only`, `direct`) to a localized display string.
  Unknown values are returned unchanged.
  """
  def translate_visibility("public"), do: gettext("Public")
  def translate_visibility("unlisted"), do: gettext("Unlisted")
  def translate_visibility("followers_only"), do: gettext("Followers only")
  def translate_visibility("direct"), do: gettext("Direct")
  def translate_visibility(other), do: other

  @doc """
  Translates an ActivityStreams object type (`Note`, `Article`, `Page`) to a
  localized display string. Unknown values are returned unchanged.
  """
  def translate_object_type("Note"), do: gettext("Note")
  def translate_object_type("Article"), do: gettext("Article")
  def translate_object_type("Page"), do: gettext("Page")
  def translate_object_type(other), do: other

  @doc """
  Translates an ActivityPub actor type (`Person`, `Group`, `Organization`,
  `Service`, `Application`) to a localized display string. Unknown values are
  returned unchanged.
  """
  def translate_actor_type("Person"), do: gettext("Person")
  def translate_actor_type("Group"), do: gettext("Group")
  def translate_actor_type("Organization"), do: gettext("Organization")
  def translate_actor_type("Service"), do: gettext("Service")
  def translate_actor_type("Application"), do: gettext("Application")
  def translate_actor_type(other), do: other

  @doc """
  Translates a report status to a localized display string.
  """
  def translate_report_status("open"), do: gettext("open")
  def translate_report_status("resolved"), do: gettext("resolved")
  def translate_report_status("dismissed"), do: gettext("dismissed")
  def translate_report_status(other), do: other

  @doc """
  Translates a report's reason category (P1-D9) for display.
  """
  def translate_report_category("spam"), do: gettext("Spam")
  def translate_report_category("harassment"), do: gettext("Harassment")
  def translate_report_category("illegal"), do: gettext("Illegal content")
  def translate_report_category("rule_violation"), do: gettext("Breaks a rule")
  def translate_report_category("other"), do: gettext("Other")
  # A report that arrived as a federated Flag carries no category.
  def translate_report_category(nil), do: gettext("Not categorised")
  def translate_report_category(other), do: other

  @doc """
  Names a health check for an operational notice (ADR 0044).

  What each name means, and what to do about it, is in `doc/sysop.md`; this is
  only the short label an admin reads in their notifications. An unknown name
  falls through unchanged, so a check added later still says something.
  """
  def translate_health_check("database"), do: gettext("the database")
  def translate_health_check("delivery_queue"), do: gettext("the outgoing federation queue")
  def translate_health_check("inbound_queue"), do: gettext("the incoming federation queue")
  def translate_health_check("workers"), do: gettext("a background worker")
  def translate_health_check("disk"), do: gettext("free disk space")
  def translate_health_check("backup"), do: gettext("backups")
  def translate_health_check("encryption_keys"), do: gettext("the encryption keys")
  def translate_health_check(other), do: other

  @doc """
  Builds a full invite link URL for the given invite code string.

  ## Examples

      iex> BaudrateWeb.Helpers.invite_url("abc12345")
      BaudrateWeb.Endpoint.url() <> "/register?invite=abc12345"
  """
  def invite_url(code) when is_binary(code) do
    BaudrateWeb.Endpoint.url() <> "/register?invite=" <> code
  end

  @doc """
  Translates a delivery job status to a localized display string.
  """
  def translate_delivery_status("pending"), do: gettext("pending")
  def translate_delivery_status("delivered"), do: gettext("delivered")
  def translate_delivery_status("failed"), do: gettext("failed")
  def translate_delivery_status(other), do: other

  @doc """
  Returns a localized description for a notification type.

  Used in the notifications page to describe what happened.
  """
  def notification_text("reply_to_article"), do: gettext("replied to your article")
  def notification_text("reply_to_comment"), do: gettext("replied to your comment")
  def notification_text("mention"), do: gettext("mentioned you")
  def notification_text("new_follower"), do: gettext("followed you")
  def notification_text("follow_request"), do: gettext("asked to follow you")

  def notification_text("actor_moved"),
    do: gettext("moved to a new account, which you now follow")

  def notification_text("board_actor_moved"),
    do: gettext("moved to a new account. Boards that follow it were not switched over.")

  def notification_text("article_liked"), do: gettext("liked your article")
  def notification_text("comment_liked"), do: gettext("liked your comment")
  def notification_text("article_boosted"), do: gettext("boosted your article")
  def notification_text("comment_boosted"), do: gettext("boosted your comment")
  def notification_text("article_forwarded"), do: gettext("forwarded your article")
  def notification_text("moderation_report"), do: gettext("submitted a moderation report")
  def notification_text("admin_announcement"), do: gettext("posted an announcement")

  # Moderation outcomes (P1-D4). The reporter learns only that staff looked at
  # their report; the author of removed content is told, with the reason when
  # the removal came from a report.
  def notification_text("report_reviewed"),
    do: gettext("Your report has been reviewed by the moderators.")

  def notification_text("content_removed"),
    do: gettext("A moderator removed your content.")

  def notification_text("pending_registration"),
    do: gettext("registered and is waiting to be let in")

  # Held posts (ADR 0065). Actorless, so full sentences, and neither names
  # the moderator.
  def notification_text("held_post"), do: gettext("A post is waiting for review.")

  def notification_text("post_approved"),
    do: gettext("A moderator approved your post, and it is now published.")

  def notification_text("post_rejected"),
    do: gettext("A moderator declined to publish your post.")

  # Actorless, and deliberately says nothing about the result or about who
  # else voted (ADR 0069).
  def notification_text("poll_closed"),
    do: gettext("A poll you wrote or voted in has closed.")

  # From a watch the recipient set themselves (ADR 0070).
  def notification_text("watched_board_post"), do: gettext("posted in a board you watch")
  def notification_text("watched_thread_reply"), do: gettext("replied in a thread you watch")

  # Operational notices (ADR 0044). The check names follow on their own line,
  # translated by `translate_health_check/1`; the reasons stay in the detailed
  # health report, which is where an operator acts on them.
  def notification_text("health_alert"),
    do: gettext("Something on this server needs attention.")

  def notification_text("health_recovered"),
    do: gettext("Everything on this server is working again.")

  def notification_text("sanction_applied"),
    do: gettext("A moderator took action on your account.")

  def notification_text("sanction_lifted"),
    do: gettext("A restriction on your account was lifted.")

  def notification_text("sanction_ended"),
    do: gettext("A restriction on your account has ended.")

  # Account security notices have no actor, so these are full sentences.
  def notification_text("security_key_added"),
    do: gettext("A security key was added to your account.")

  def notification_text("security_key_removed"),
    do: gettext("A security key was removed from your account.")

  def notification_text("totp_enabled"),
    do: gettext("Two-factor authentication (TOTP) was set up on your account.")

  def notification_text("totp_disabled"),
    do: gettext("Two-factor authentication (TOTP) was turned off on your account.")

  def notification_text("password_changed"),
    do: gettext("Your account password was changed.")

  def notification_text("signed_out_everywhere"),
    do: gettext("All other sessions on your account were signed out.")

  def notification_text("totp_login_failed"),
    do:
      gettext(
        "Someone entered the correct password for your account but failed the two-factor code several times."
      )

  def notification_text("account_alias_added"),
    do: gettext("An account alias was added to your account.")

  def notification_text("account_alias_removed"),
    do: gettext("An account alias was removed from your account.")

  def notification_text("account_move_requested"),
    do:
      gettext(
        "A move of your account to another server was requested. It will be sent after 24 hours unless you cancel it."
      )

  def notification_text("account_deletion_requested"),
    do:
      gettext(
        "Deleting your account was requested. It will happen in 7 days unless you sign in again, which cancels it."
      )

  def notification_text("account_deletion_cancelled"),
    do: gettext("A pending deletion of your account was cancelled.")

  def notification_text("account_move_cancelled"),
    do: gettext("A pending move of your account was cancelled.")

  def notification_text("account_move_failed"),
    do: gettext("A pending move of your account could not be sent and was stopped.")

  def notification_text("account_moved"),
    do:
      gettext(
        "Your account has moved. Your followers were sent to your new account, and this account is now read-only."
      )

  def notification_text("account_redirect_removed"),
    do: gettext("The redirect of your moved account was removed. It can post again.")

  def notification_text("data_export_requested"),
    do:
      gettext("A data export of your account was requested. It can be downloaded after 24 hours.")

  def notification_text("data_export_ready"),
    do: gettext("Your data export is ready and can be downloaded for 48 hours.")

  def notification_text("data_export_downloaded"),
    do: gettext("Your data export was downloaded.")

  def notification_text("data_export_cancelled"),
    do: gettext("A data export request on your account was cancelled.")

  def notification_text("recovery_codes_regenerated"),
    do: gettext("New recovery codes were issued. Every earlier code has stopped working.")

  def notification_text("recovery_contact_added"),
    do: gettext("A recovery contact was added to your account. An admin has to verify it.")

  def notification_text("recovery_contact_removed"),
    do: gettext("A recovery contact was removed from your account.")

  def notification_text("recovery_contact_verified"),
    do: gettext("An admin verified one of your recovery contacts.")

  def notification_text("account_reset_issued"),
    do:
      gettext(
        "An admin issued a recovery link for your account. If you did not ask for one, tell them now."
      )

  def notification_text("account_reset_used"),
    do:
      gettext(
        "An admin-issued recovery link was used on your account: the password was replaced and every session signed out."
      )

  def notification_text("registration_approved"),
    do: gettext("Your account was approved. You can post, comment and send messages now.")

  def notification_text(_), do: gettext("sent you a notification")

  @doc "Flash text when a moved account tries to post or interact (ADR 0025)."
  def account_moved_message,
    do: gettext("Your account has moved and is read-only. Remove the redirect to post again.")

  @doc """
  Flash text for an interaction refused because a block stands between the
  user and the author (`{:error, :blocked}`).
  """
  def blocked_interaction_message,
    do: gettext("You cannot interact with this account.")

  @doc """
  Flash text for registration or sign-in refused because the visitor's
  address is banned (Phase 5E).

  Plain about what happened, and deliberately not about why or by whom: an
  address is shared by everyone behind the same network, so most people who
  read this did nothing, and the sentence has to be one an innocent person
  can act on.
  """
  def ip_banned_message,
    do:
      gettext(
        "Registration and sign-in are not available from your network. If you think this is a mistake, please contact the site's administrators."
      )

  # Everything `Auth.ensure_can_interact/1` can refuse with. Kept in one place
  # so a LiveView cannot handle three of the four and shrug at the fourth.
  @gate_refusals [
    :account_deleted,
    :account_moved,
    :account_silenced,
    :account_suspended,
    :banned,
    :terms_not_accepted
  ]

  # Everything the limits on new accounts can refuse with (ADR 0064).
  @new_account_refusals [
    :new_account_dm,
    :new_account_images,
    :new_account_links,
    :new_account_rate_limited,
    :new_account_signature
  ]

  @doc """
  Flash text for a refused action: the gate's own explanation when the gate
  refused it (ADR 0029), a new account's limit did (ADR 0064) or a content
  filter did (ADR 0065), and `fallback` for anything else.

  Call it from the `{:error, reason}` catch-all of an interaction handler.
  A member told only "that did not work" has no way to find out that they are
  silenced, or until when — and a new member refused with a shrug reads the
  site as broken.
  """
  def refusal_message(reason, user, fallback) do
    cond do
      reason in @gate_refusals -> interaction_refused_message(reason, user)
      reason in @new_account_refusals -> new_account_message(reason, user)
      reason == :content_filtered -> content_filtered_message()
      true -> fallback
    end
  end

  @doc """
  Flash text for a post a content filter refused (ADR 0065).

  It says that a rule of the site stopped the post and **never which one**: a
  filter that names the word it caught is a word-guessing oracle, and a
  spammer would rephrase until it passed. A member caught by mistake can ask
  the moderators, who can see which filter matched.
  """
  def content_filtered_message,
    do:
      gettext(
        "This can't be posted because it contains something this site doesn't allow. If you think this is a mistake, please contact the moderators."
      )

  @doc """
  Flash text for a post held for a moderator (ADR 0065): it is not lost, it
  is not public yet, and where to find it meanwhile.
  """
  def held_post_message,
    do:
      gettext(
        "Thanks — your post will appear once a moderator has looked at it. Until then you can find it under Drafts."
      )

  @doc """
  Flash text for something an account may not do until it has earned trust
  (ADR 0064): what the limit is, and — for the member in front of us — what is
  left before it lifts. Pass the current user; without one the message still
  names the limit, only not when it ends.
  """
  def new_account_message(reason, user \\ nil) do
    [new_account_limit(reason), new_account_lifts(user)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp new_account_limit(:new_account_links) do
    count = Baudrate.Auth.Trust.limits().links

    ngettext(
      "New accounts can put at most %{count} link in a post.",
      "New accounts can put at most %{count} links in a post.",
      count
    )
  end

  defp new_account_limit(:new_account_images) do
    count = Baudrate.Auth.Trust.limits().images

    ngettext(
      "New accounts can put at most %{count} image in a post.",
      "New accounts can put at most %{count} images in a post.",
      count
    )
  end

  defp new_account_limit(:new_account_rate_limited) do
    count = Baudrate.Auth.Trust.limits().posts_per_hour

    ngettext(
      "New accounts can post at most %{count} time an hour. Please try again later.",
      "New accounts can post at most %{count} times an hour. Please try again later.",
      count
    )
  end

  defp new_account_limit(:new_account_signature),
    do:
      gettext(
        "New accounts cannot add links or images to their signature, which is shown under every article they post."
      )

  defp new_account_limit(:new_account_dm),
    do:
      gettext(
        "New accounts can send direct messages only to people who follow them, people who have written to them first, and staff."
      )

  # What is left for this member: a date, a number of posts, or both. Said in
  # full sentences rather than assembled from parts, because the parts do not
  # translate as parts.
  defp new_account_lifts(nil), do: nil

  defp new_account_lifts(user) do
    standing = Baudrate.Auth.trust_standing(user)
    remaining = max(standing.posts_required - standing.post_count, 0)

    cond do
      standing.trusted ->
        nil

      standing.old_enough_at && remaining > 0 ->
        ngettext(
          "This lifts once %{date} has passed and you have written %{count} more post.",
          "This lifts once %{date} has passed and you have written %{count} more posts.",
          remaining,
          date: format_datetime(standing.old_enough_at)
        )

      standing.old_enough_at ->
        gettext("This lifts once %{date} has passed.",
          date: format_datetime(standing.old_enough_at)
        )

      remaining > 0 ->
        ngettext(
          "This lifts once you have written %{count} more post.",
          "This lifts once you have written %{count} more posts.",
          remaining
        )

      true ->
        nil
    end
  end

  @doc """
  Flash text for an interaction the gate refused (ADR 0029).

  A post that fails with a shrug is worse than the sanction, so a silenced or
  suspended member is told what stands against them, why, and until when. The
  staff-written reason is interpolated as data, never as markup. Pass the
  current user so the active sanction can be quoted; without one the message
  is still correct, only vaguer.
  """
  def interaction_refused_message(reason, user \\ nil)

  def interaction_refused_message(:account_moved, _user), do: account_moved_message()

  def interaction_refused_message(:banned, _user),
    do: gettext("Your account has been banned.")

  def interaction_refused_message(:account_deleted, _user),
    do: gettext("This account has been deleted.")

  def interaction_refused_message(:account_silenced, user),
    do: sanction_message(gettext("Your account is silenced and cannot post."), user, "silence")

  def interaction_refused_message(:account_suspended, user),
    do: sanction_message(gettext("Your account is suspended."), user, "suspend")

  # The one refusal the member clears themselves, so it says how instead of
  # telling them to wait or to write to staff.
  def interaction_refused_message(:terms_not_accepted, _user),
    do: gettext("The terms have changed. Read and accept them to post again.")

  def interaction_refused_message(_reason, _user),
    do: gettext("You cannot do that right now.")

  @doc """
  Flash text when a sign-in is refused because the account is suspended.
  Takes the sanction, which `Auth.authenticate_by_password/2` returns for
  exactly this purpose.
  """
  def suspended_login_message(sanction),
    do: decorate_sanction(gettext("Your account is suspended."), sanction)

  defp sanction_message(lead, nil, _kind), do: lead

  defp sanction_message(lead, user, kind),
    do: decorate_sanction(lead, Baudrate.Auth.active_sanction(user, kind))

  defp decorate_sanction(lead, nil), do: lead

  defp decorate_sanction(lead, sanction) do
    [lead]
    |> append_if(sanction.reason, &gettext("Reason: %{reason}", reason: &1))
    |> append_if(sanction.expires_at, &gettext("It ends %{at}.", at: format_datetime(&1)))
    |> Enum.join(" ")
  end

  defp append_if(parts, nil, _fun), do: parts
  defp append_if(parts, value, fun), do: parts ++ [fun.(value)]

  @doc """
  Whether to render an interactive like/boost toggle for `user` on content by
  `author_id`, given whether the user has already `active`-ly liked or boosted it.

  Guests and authors get the static count. A moved account is read-only
  (ADR 0025), so it gets a toggle only to undo an existing like or boost; the
  context boundary enforces the same rule.
  """
  def interaction_toggle?(nil, _author_id, _active), do: false
  def interaction_toggle?(%{id: id}, id, _active), do: false

  def interaction_toggle?(%{moved_to: moved_to}, _author_id, active) when is_binary(moved_to),
    do: active == true

  def interaction_toggle?(_user, _author_id, _active), do: true

  @doc "Whether `user` is a moved (read-only) account (ADR 0025)."
  def moved_account?(%{moved_to: moved_to}) when is_binary(moved_to), do: true
  def moved_account?(_user), do: false

  @doc """
  Returns the Heroicon name for a notification type.
  """
  def notification_icon("reply_to_article"), do: "hero-chat-bubble-left-ellipsis"
  def notification_icon("reply_to_comment"), do: "hero-chat-bubble-left-right"
  def notification_icon("mention"), do: "hero-at-symbol"
  def notification_icon("new_follower"), do: "hero-user-plus"
  def notification_icon("follow_request"), do: "hero-user-plus"
  def notification_icon("article_liked"), do: "hero-heart"
  def notification_icon("comment_liked"), do: "hero-heart"
  def notification_icon("article_boosted"), do: "hero-arrow-path-rounded-square"
  def notification_icon("comment_boosted"), do: "hero-arrow-path-rounded-square"
  def notification_icon("article_forwarded"), do: "hero-arrow-uturn-right"
  def notification_icon("moderation_report"), do: "hero-flag"
  def notification_icon("admin_announcement"), do: "hero-megaphone"
  def notification_icon("report_reviewed"), do: "hero-flag"
  def notification_icon("content_removed"), do: "hero-trash"
  def notification_icon("pending_registration"), do: "hero-user-plus"
  def notification_icon("held_post"), do: "hero-inbox-stack"
  def notification_icon("post_approved"), do: "hero-check-circle"
  def notification_icon("post_rejected"), do: "hero-x-circle"
  def notification_icon("poll_closed"), do: "hero-chart-bar"
  def notification_icon("watched_board_post"), do: "hero-eye"
  def notification_icon("watched_thread_reply"), do: "hero-eye"
  def notification_icon("health_alert"), do: "hero-exclamation-triangle"
  def notification_icon("health_recovered"), do: "hero-check-badge"
  def notification_icon("sanction_applied"), do: "hero-exclamation-triangle"
  def notification_icon("sanction_lifted"), do: "hero-check-badge"
  def notification_icon("sanction_ended"), do: "hero-check-badge"
  def notification_icon("security_key_added"), do: "hero-key"
  def notification_icon("security_key_removed"), do: "hero-key"
  def notification_icon("totp_enabled"), do: "hero-shield-check"
  def notification_icon("totp_disabled"), do: "hero-shield-exclamation"
  def notification_icon("password_changed"), do: "hero-lock-closed"
  def notification_icon("signed_out_everywhere"), do: "hero-arrow-right-start-on-rectangle"
  def notification_icon("totp_login_failed"), do: "hero-exclamation-triangle"
  def notification_icon("account_alias_added"), do: "hero-link"
  def notification_icon("account_alias_removed"), do: "hero-link-slash"
  def notification_icon("account_move_requested"), do: "hero-truck"
  def notification_icon("account_move_cancelled"), do: "hero-x-circle"
  def notification_icon("account_deletion_requested"), do: "hero-trash"
  def notification_icon("account_deletion_cancelled"), do: "hero-arrow-uturn-left"
  def notification_icon("account_move_failed"), do: "hero-exclamation-triangle"
  def notification_icon("account_moved"), do: "hero-truck"
  def notification_icon("account_redirect_removed"), do: "hero-arrow-uturn-left"
  def notification_icon("actor_moved"), do: "hero-truck"
  def notification_icon("board_actor_moved"), do: "hero-truck"
  def notification_icon("data_export_requested"), do: "hero-archive-box"
  def notification_icon("data_export_ready"), do: "hero-archive-box-arrow-down"
  def notification_icon("data_export_downloaded"), do: "hero-arrow-down-tray"
  def notification_icon("data_export_cancelled"), do: "hero-archive-box-x-mark"
  def notification_icon("recovery_codes_regenerated"), do: "hero-key"
  def notification_icon("recovery_contact_added"), do: "hero-envelope"
  def notification_icon("recovery_contact_removed"), do: "hero-envelope"
  def notification_icon("recovery_contact_verified"), do: "hero-check-badge"
  def notification_icon("account_reset_issued"), do: "hero-exclamation-triangle"
  def notification_icon("account_reset_used"), do: "hero-lock-open"
  def notification_icon("registration_approved"), do: "hero-hand-raised"
  def notification_icon(_), do: "hero-bell"

  @doc """
  Extracts the real client IP from a LiveView socket.

  Checks the proxy header configured for `BaudrateWeb.Plugs.RealIp` (e.g.
  `x-forwarded-for`) from the WebSocket upgrade request's `x_headers` first.
  Falls back to `peer_data` (the raw TCP peer address) when no proxy header
  is configured or present.

  Returns a string IP address, or `"unknown"` if neither source is available.

  ## Examples

      # With x-forwarded-for header configured and present:
      extract_peer_ip(socket)  #=> "203.0.113.50"

      # Without proxy header (direct connection):
      extract_peer_ip(socket)  #=> "127.0.0.1"
  """
  def extract_peer_ip(socket) do
    header =
      Application.get_env(:baudrate, BaudrateWeb.Plugs.RealIp, [])
      |> Keyword.get(:header)

    peer_ip =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: addr} -> addr
        _ -> nil
      end

    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

    forwarded =
      with header when is_binary(header) <- header,
           {_, value} <- List.keyfind(x_headers, header, 0) do
        value
      else
        _ -> nil
      end

    # Same resolution as the RealIp plug: trusted peer + parseable header, with
    # IPv4-mapped addresses unmapped. An unparseable header value falls back to
    # the peer rather than being used verbatim as a rate-limit key or log field.
    case BaudrateWeb.Plugs.RealIp.client_ip(peer_ip, forwarded) do
      nil -> "unknown"
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  end

  @doc """
  Formats a datetime as a relative time string (e.g. "just now", "3h ago").

  For times older than 7 days, falls back to `format_date/1`.

  ## Examples

      iex> BaudrateWeb.Helpers.format_relative_time(DateTime.utc_now())
      "just now"
  """
  def format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> gettext("%{count}m ago", count: div(diff, 60))
      diff < 86_400 -> gettext("%{count}h ago", count: div(diff, 3600))
      diff < 604_800 -> gettext("%{count}d ago", count: div(diff, 86_400))
      true -> format_date(datetime)
    end
  end

  @doc """
  Formats a file size in bytes to a human-readable string with localized units.

  ## Examples

      iex> BaudrateWeb.Helpers.format_file_size(500)
      "500 B"

      iex> BaudrateWeb.Helpers.format_file_size(2048)
      "2.0 KB"
  """
  def format_file_size(bytes) when bytes < 1024,
    do: gettext("%{n} B", n: bytes)

  def format_file_size(bytes) when bytes < 1_048_576,
    do: gettext("%{n} KB", n: Float.round(bytes / 1024, 1))

  def format_file_size(bytes),
    do: gettext("%{n} MB", n: Float.round(bytes / 1_048_576, 1))

  @doc """
  Builds the path to a comment on an article's page: `/articles/:slug`, with
  `?page=N` when the comment is not on the first page, and `#comment-ID`.

  Comments are paged, so a bare `#comment-ID` only works for a comment on
  page 1. Take the page and anchor from `Baudrate.Content.comment_location/2`,
  or use `comment_link/3`, which does.

  ## Examples

      iex> BaudrateWeb.Helpers.comment_path("hello", 1, "comment-7")
      "/articles/hello#comment-7"

      iex> BaudrateWeb.Helpers.comment_path("hello", 3, "comment-7")
      "/articles/hello?page=3#comment-7"
  """
  def comment_path(%{slug: slug}, page, anchor), do: comment_path(slug, page, anchor)

  def comment_path(slug, page, anchor) when is_binary(slug) do
    base = if page > 1, do: ~p"/articles/#{slug}?page=#{page}", else: ~p"/articles/#{slug}"
    base <> "#" <> anchor
  end

  @doc """
  Returns the path to `comment` on `article`'s page as `viewer` would see it,
  or the article's own path when the comment's thread is not visible to them.
  """
  def comment_link(article, comment, viewer) do
    case Baudrate.Content.comment_location(comment, viewer) do
      {page, anchor} -> comment_path(article, page, anchor)
      nil -> ~p"/articles/#{article.slug}"
    end
  end

  @doc """
  Returns `path` when it is a safe same-origin path, otherwise `fallback`.

  **This is the one definition.** Every controller that redirects to a path it
  was handed — the share target's stored `:return_to`, the language switcher's
  form field — asks here, because an open-redirect guard that exists twice is
  one that gets fixed once.

  A value passes only if it starts with a single `/` and carries none of the
  ways a string can stop being a local path:

    * `//host` — protocol-relative, so the browser leaves the site;
    * `..` — traversal, which can climb out of a scope a caller assumed;
    * `\\` — some parsers fold it to `/`, so `/\\evil.example` is `//evil.example`;
    * `@` — the authority separator, so `/@evil.example` can be read as a host;
    * CR, LF, NUL — header and terminator injection.

  It deliberately does **not** try to parse the value as a URI and inspect the
  host: a rejection list of shapes is what the rest of the codebase already
  used, and `URI.parse/1` accepts several strings a browser resolves
  differently from Elixir.

  ## Examples

      iex> BaudrateWeb.Helpers.local_path("/boards/sysop", "/")
      "/boards/sysop"

      iex> BaudrateWeb.Helpers.local_path("//evil.example", "/")
      "/"
  """
  def local_path(path, fallback)

  def local_path(path, fallback) when is_binary(path) do
    if String.starts_with?(path, "/") and
         not String.starts_with?(path, "//") and
         not String.contains?(path, "..") and
         not String.contains?(path, "\\") and
         not String.contains?(path, "\n") and
         not String.contains?(path, "\r") and
         not String.contains?(path, "@") and
         not String.contains?(path, "\0") do
      path
    else
      fallback
    end
  end

  def local_path(_path, fallback), do: fallback
end
