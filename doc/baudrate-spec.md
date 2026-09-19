# Baudrate conformance index

**This file states no rules of its own.** Every row is a one-line summary plus
pointers: the record that explains the decision, the code that enforces it, and
the test that fails if it breaks.

That makes the precedence explicit, and it matters when they disagree:

1. **The code is what the instance does.** If a row and the code disagree, the
   code wins and the row is a bug in this file.
2. **The ADR is what we decided.** If the code and its record disagree, one of
   them is a defect — say which, and do not quietly edit the record
   ([0000](adr/0000-use-architecture-decision-records.md): accepted records are
   immutable but for their Status line).
3. **This index is neither.** It is a finding aid, so that "is there a rule
   about X, and what proves it holds?" is one lookup instead of a search across
   `CLAUDE.md`, 50 records and the test suite.

`CLAUDE.md` remains the operative guide for whoever is writing code right now;
[`doc/development.md`](development.md) remains the reference manual. This exists
because neither of them, nor the records, could answer the second half of that
question.

## How to use it

- **Adding a rule?** It needs a row, an ADR if the decision is expensive to
  reverse, and — if it can be tested — a gate. A row whose gate is **none** is
  a rule held up by review alone.
- **Changing code under a row?** The gate is the fastest way to find out what
  the rule actually is; it is more precise than any prose here, including the
  record.
- **The gate column is the point.** Eighteen rows have no automated gate. Those
  are listed here rather than left to be rediscovered: a 2026-09-19 audit of
  all 46 records then on file found eight real defects, and most of them lived
  exactly where no gate did.

`test/doc/spec_index_test.exs` checks this file mechanically: every ADR on disk
has at least one row, every named test file exists, every named function exists
at the arity given, and any test a record names in its own **Acceptance gate**
section appears in that record's rows. What it cannot check is whether a
summary is *true* — for that there is no substitute for reading the record.


## Federation

The trust boundary. Everything here is reachable by an unauthenticated remote instance sending JSON.

| Invariant | Why | Enforced in | Gate |
|---|---|---|---|
| Users render as AP Person, boards as Group whose preferredUsername is the bare slug matching WebFinger | [0003](adr/0003-activitypub-federation.md) | `Baudrate.Federation.ActorRenderer.board_actor/1`, `Baudrate.Federation.Discovery.webfinger/1` | [`actor_renderer_test.exs`](../test/baudrate/federation/actor_renderer_test.exs) |
| Every local article is stamped post-insert with a canonical ap_id derived from Federation.actor_uri/2 | [0003](adr/0003-activitypub-federation.md) | `Baudrate.Federation.actor_uri/2` | [`article_test.exs`](../test/baudrate/content/article_test.exs) |
| An AP Accept header on GET /articles/:slug is content-negotiated to the AS2 endpoint | [0003](adr/0003-activitypub-federation.md) | `BaudrateWeb.Plugs.ArticleApContentNeg.call/2` | [`article_ap_content_neg_test.exs`](../test/baudrate_web/plugs/article_ap_content_neg_test.exs) |
| Every inbound Like, Announce, Create(Note) reply and poll vote on a local article passes one federation gate | [0004](adr/0004-federation-gate-for-non-public-boards.md) | `Baudrate.Federation.InboxHandler.article_federated?/1` | [`inbox_handler_test.exs`](../test/baudrate/federation/inbox_handler_test.exs) |
| A board federates only when min_role_to_view == guest and ap_enabled; otherwise its AP endpoints 404 | [0004](adr/0004-federation-gate-for-non-public-boards.md) | `Baudrate.Content.Board.federated?/1`, `BaudrateWeb.ActivityPubController.board_actor/2` | [`board_test.exs`](../test/baudrate/content/board_test.exs) |
| Outbound HTTP requires HTTPS, rejects private or reserved resolved IPs, and pins the connection to that IP | [0007](adr/0007-single-ssrf-safe-http-client.md) | `Baudrate.Federation.HTTPClient.validate_url/1`, `Baudrate.Federation.HTTPClient.private_ip?/1` | [`http_client_test.exs`](../test/baudrate/federation/http_client_test.exs) |
| HTTPSignature.sign/5 and sign_get/3 never emit a host header; HTTPClient owns it for DNS pinning | [0007](adr/0007-single-ssrf-safe-http-client.md) | `Baudrate.Federation.HTTPSignature.sign/5`, `Baudrate.Federation.HTTPSignature.sign_get/3` | [`http_signature_test.exs`](../test/baudrate/federation/http_signature_test.exs) |
| Non-ActivityPub outbound POSTs go through HTTPClient.post_raw/3, never a bare Req.post | [0007](adr/0007-single-ssrf-safe-http-client.md) | `Baudrate.Federation.HTTPClient.post_raw/3` | [`http_client_test.exs`](../test/baudrate/federation/http_client_test.exs) |
| Inbound remote public keys must be RSA of at least 2048 bits; other key types are rejected | [0010](adr/0010-encrypt-secrets-at-rest.md) | `Baudrate.Federation.HTTPSignature.validate_public_key_pem/1` | [`http_signature_test.exs`](../test/baudrate/federation/http_signature_test.exs) |
| Delivery.get_private_key/1 lazily generates a missing keypair for a local user, board or site actor | [0010](adr/0010-encrypt-secrets-at-rest.md) | `Baudrate.Federation.Delivery.get_private_key/1`, `Baudrate.Federation.KeyStore.ensure_user_keypair/1` | [`delivery_test.exs`](../test/baudrate/federation/delivery_test.exs) |
| An outbound activity is queued as a row before any POST, and a duplicate pending job is never enqueued | [0013](adr/0013-database-backed-delivery-queue.md) | `Baudrate.Federation.Delivery.enqueue/3` | [`delivery_test.exs`](../test/baudrate/federation/delivery_test.exs) |
| A failed delivery is retried with exponential backoff, and abandoned on a final 4xx or past its maximum age | [0013](adr/0013-database-backed-delivery-queue.md) | `Baudrate.Federation.Delivery.deliver_one/1` | [`delivery_test.exs`](../test/baudrate/federation/delivery_test.exs) |
| The delivery worker delivers only jobs that are due and pending, never delivered or abandoned ones | [0013](adr/0013-database-backed-delivery-queue.md) | `Baudrate.Federation.DeliveryWorker.handle_info/2` | [`delivery_worker_test.exs`](../test/baudrate/federation/delivery_worker_test.exs) |
| Requesting a move needs step-up re-auth and an active, non-staff, non-bot account with 7-day-old TOTP | [0025](adr/0025-account-migration.md) | `Baudrate.AccountMigration.request_move/4`, `Baudrate.AccountMigration.move_eligibility/1` | [`account_migration_test.exs`](../test/baudrate/account_migration_test.exs) |
| A Move is sent only after the 24-hour cooling-off and only if every eligibility check still holds | [0025](adr/0025-account-migration.md) | `Baudrate.AccountMigration.send_move/1`, `Baudrate.AccountMigration.sweep_due_moves/0` | [`account_migration_test.exs`](../test/baudrate/account_migration_test.exs) |
| A blocked remote actor's Follow, Like, Announce and replies are refused at the inbox, and no Block is sent | [0026](adr/0026-blocks-stop-interaction-locally.md) | `Baudrate.Auth.remote_actor_blocked_by?/2` | [`inbox_handler_block_test.exs`](../test/baudrate/federation/inbox_handler_block_test.exs) |
| Blocking severs follows in both directions, and unblocking restores none | [0026](adr/0026-blocks-stop-interaction-locally.md) | `Baudrate.Federation.sever_remote_follows/2` | [`block_enforcement_test.exs`](../test/baudrate/auth/block_enforcement_test.exs) |
| A domain block hides content at query time and deletes nothing, so unblocking restores it | [0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md) | `Baudrate.Content.Filters.exclude_unservable_remote/1` | [`blocked_domain_hiding_test.exs`](../test/baudrate/federation/blocked_domain_hiding_test.exs) |
| A suspended remote actor is hidden by the same predicate as a blocked domain | [0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md) | `Baudrate.Federation.DomainBlocks.actor_hidden?/1` | [`remote_actor_suspension_test.exs`](../test/baudrate/federation/remote_actor_suspension_test.exs) |
| A blocked domain receives no outbound fetch from us either: actors, objects, media or link previews | [0030](adr/0030-domain-blocks-are-rows-and-hiding-is-reversible.md) | `Baudrate.Federation.Validator.domain_blocked?/1` | [`blocked_domain_outbound_test.exs`](../test/baudrate/federation/blocked_domain_outbound_test.exs) |
| A change and its delivery jobs commit together, or neither does | [0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md) | `Baudrate.Federation.federate/2`, `Baudrate.Federation.Delivery.enqueue/3` | [`durable_delivery_test.exs`](../test/baudrate/federation/durable_delivery_test.exs) |
| An unreachable inbox domain's jobs are held by a circuit whose state lives in the database, not ETS | [0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md) | `Baudrate.Federation.DeliveryCircuits.record/3` | [`delivery_circuits_test.exs`](../test/baudrate/federation/delivery_circuits_test.exs) |
| The inbox stores and answers 202; processing runs later, one activity per actor, re-checking admission | [0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md) | `Baudrate.Federation.InboxHandler.admit/2`, `Baudrate.Federation.InboundWorker.next_activities/2` | [`inbound_worker_test.exs`](../test/baudrate/federation/inbound_worker_test.exs) |
| A delivery in flight past its deadline is killed and recorded, never left for the next poll to retry | [0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md) | `Baudrate.Federation.Delivery.record_interrupted/2` | [`delivery_worker_test.exs`](../test/baudrate/federation/delivery_worker_test.exs) |
| An inbound activity is stored once per signing actor and id; a redelivery is answered and dropped | [0034](adr/0034-federation-work-is-committed-before-it-is-acknowledged.md) | `Baudrate.Federation.Inbound.accept/4` | [`inbound_test.exs`](../test/baudrate/federation/inbound_test.exs) |
| An Announce item records the original author in remote_actor_id and the booster in boosted_by_actor_id | [0039](adr/0039-the-personal-stream-is-a-timeline.md) | `Baudrate.Federation.TimelineItem.changeset/2` | [`timeline_item_test.exs`](../test/baudrate/federation/timeline_item_test.exs) |
| A follow matches a Create on remote_actor_id and an Announce on boosted_by_actor_id | [0039](adr/0039-the-personal-stream-is-a-timeline.md) | `Baudrate.Federation.Timeline.list_timeline_items/2` | [`timeline_item_context_test.exs`](../test/baudrate/federation/timeline_item_context_test.exs) |
| A reply to a timeline item requires a body, the item and a local author, and the item must be reachable | [0039](adr/0039-the-personal-stream-is-a-timeline.md) | `Baudrate.Federation.TimelineItemReply.changeset/2` | [`timeline_item_reply_test.exs`](../test/baudrate/federation/timeline_item_reply_test.exs) |
| Blocking a remote author from the timeline removes the follow and hides that actor's items at once | [0039](adr/0039-the-personal-stream-is-a-timeline.md) | `Baudrate.Auth.block_remote_actor/2` | [`timeline_live_test.exs`](../test/baudrate_web/live/timeline_live_test.exs) |
| Content leaves the instance only for an article that is board-less or in one federated board | [0043](adr/0043-the-outbound-federation-gate-and-withdrawals.md) | `Baudrate.Content.Board.federated?/1`, `Baudrate.Federation.Delivery.enqueue_for_article/4` | [`publisher_test.exs`](../test/baudrate/federation/publisher_test.exs) |
| A withdrawal passes intent: :withdraw and is never gated by the board it left | [0043](adr/0043-the-outbound-federation-gate-and-withdrawals.md) | `Baudrate.Federation.Delivery.enqueue_for_article/4` | [`publisher_test.exs`](../test/baudrate/federation/publisher_test.exs) |
| Federation decisions use Board.federated?/1, never Board.public?/1 | [0043](adr/0043-the-outbound-federation-gate-and-withdrawals.md) | `Baudrate.Federation.ObjectBuilder.article_object/1` | [`publisher_test.exs`](../test/baudrate/federation/publisher_test.exs) |
| A fetched actor document's id shares a host with the URL it was fetched from | [0046](adr/0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md) | `Baudrate.Federation.Validator.same_host?/2` | [`actor_resolver_test.exs`](../test/baudrate/federation/actor_resolver_test.exs) |
| An object's id and its attributedTo share a host with the document that carried it | [0046](adr/0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md) | `Baudrate.Federation.Validator.same_host?/2` | [`object_resolver_test.exs`](../test/baudrate/federation/object_resolver_test.exs) |
| A local URI asserted by a remote sender is refused outright, not host-compared | [0046](adr/0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md) | `Baudrate.Federation.Validator.local_actor?/1` | [`validator_test.exs`](../test/baudrate/federation/validator_test.exs) |
| An activity's id must share a host with its actor, checked at admission before anything is stored | [0046](adr/0046-every-identity-claim-is-bound-to-the-host-that-can-prove-it.md) | `Baudrate.Federation.Validator.validate_activity/1` | [`inbound_test.exs`](../test/baudrate/federation/inbound_test.exs) |
| Every local comment and poll is minted at a dereferenceable path, never a URI fragment | [0050](adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md) | `Baudrate.Federation.actor_uri/2` | [`object_identity_test.exs`](../test/baudrate/federation/object_identity_test.exs) |
| /ap/comments/:id and /ap/polls/:id refuse exactly what /ap/articles/:slug refuses, and never serve a remote object | [0050](adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md) | `BaudrateWeb.ActivityPubController.comment/2` | [`object_identity_test.exs`](../test/baudrate/federation/object_identity_test.exs) |
| An id a peer learned before the rewrite still resolves inbound, and a withdrawal names it too | [0050](adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md) | `Baudrate.Content.Comments.get_comment_by_ap_id/1`, `Baudrate.Federation.Publisher.publish_comment_deleted/2` | [`object_identity_test.exs`](../test/baudrate/federation/object_identity_test.exs) |
| The ap_id rewrite is resumable and never touches a remote row | [0050](adr/0050-a-comment-and-a-poll-are-objects-with-their-own-uri.md) | `Baudrate.Release.backfill_ap_ids/1` | [`release_test.exs`](../test/baudrate/release_test.exs) |
| A comment's inReplyTo names its parent comment, from one definition shared by the activity, the object and the replies collection | [0051](adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md) | `Baudrate.Federation.ObjectBuilder.reply_target_uri/2` | [`mentions_test.exs`](../test/baudrate/federation/mentions_test.exs) |
| A remote @user@domain handle is never parsed as a local mention, and an email address is never parsed as either | [0051](adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md) | `Baudrate.Content.Markdown.extract_remote_mentions/1` | [`mentions_test.exs`](../test/baudrate/federation/mentions_test.exs) |
| A mention produces no tag, no cc, no delivery and no lookup for content the board gate refuses | [0051](adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md) | `Baudrate.Federation.Mentions.known/1` | [`mentions_test.exs`](../test/baudrate/federation/mentions_test.exs), [`publisher_test.exs`](../test/baudrate/federation/publisher_test.exs) |
| An unknown handle is resolved once, before the write transaction, bounded by rate limit, per-post cap and deadline | [0051](adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md) | `Baudrate.Federation.Mentions.warm/2`, `BaudrateWeb.RateLimits.check_mention_resolve/1` | [`mentions_test.exs`](../test/baudrate/federation/mentions_test.exs) |
| An actor on a blocked domain is never addressed by a mention, though the cached row still exists | [0051](adr/0051-a-mention-addresses-and-the-board-gate-still-decides.md) | `Baudrate.Federation.Mentions.known/1` | [`mentions_test.exs`](../test/baudrate/federation/mentions_test.exs) |
| A content warning is stored in summary and sensitive; the body is never rewritten to carry it | [0052](adr/0052-a-content-warning-is-a-field-not-a-prefix.md) | `Baudrate.Content.ContentWarning.validate/1` | [`content_warning_test.exs`](../test/baudrate/federation/content_warning_test.exs) |
| Every schema that accepts a warning applies the same normalisation, implication and bound | [0052](adr/0052-a-content-warning-is-a-field-not-a-prefix.md) | `Baudrate.Content.ContentWarning.fields/0` | [`content_warning_test.exs`](../test/baudrate/federation/content_warning_test.exs) |
| An outbound summary is the content warning and never a body excerpt | [0052](adr/0052-a-content-warning-is-a-field-not-a-prefix.md) | `Baudrate.Federation.ObjectBuilder.article_object/1` | [`content_warning_test.exs`](../test/baudrate/federation/content_warning_test.exs) |
| Video and audio attachments render as a link to the origin, never an embed or a proxied subresource | [0052](adr/0052-a-content-warning-is-a-field-not-a-prefix.md) | `Baudrate.Federation.AttachmentExtractor.playable?/1` | [`content_warning_test.exs`](../test/baudrate/federation/content_warning_test.exs) |

## Auth

Who someone is, and how they prove it again.

| Invariant | Why | Enforced in | Gate |
|---|---|---|---|
| Session and refresh tokens are persisted only as SHA-256 hashes; raw tokens live only in the cookie | [0008](adr/0008-server-side-dual-token-sessions.md) | `Baudrate.Auth.Sessions.hash_token/1`, `Baudrate.Auth.Sessions.create_user_session/2` | [`user_session_test.exs`](../test/baudrate/auth/user_session_test.exs) |
| RefreshSession rotates both tokens once refreshed_at is 24 h stale, and drops the session if refresh fails | [0008](adr/0008-server-side-dual-token-sessions.md) | `BaudrateWeb.Plugs.RefreshSession.call/2` | [`refresh_session_test.exs`](../test/baudrate_web/plugs/refresh_session_test.exs) |
| Repeated per-account login failures incur a progressive delay checked before bcrypt, never a hard lockout | [0008](adr/0008-server-side-dual-token-sessions.md) | `Baudrate.Auth.Sessions.check_login_throttle/1` | [`login_attempt_test.exs`](../test/baudrate/auth/login_attempt_test.exs) |
| admin and moderator must enrol a second factor; user may enrol, guest cannot | [0009](adr/0009-mandatory-2fa-and-admin-sudo-mode.md) | `Baudrate.Auth.SecondFactor.totp_policy/1` | [`auth_test.exs`](../test/baudrate/auth_test.exs) |
| Admin LiveView routes require TOTP or WebAuthn re-verification within 10 minutes or redirect to /admin/verify | [0009](adr/0009-mandatory-2fa-and-admin-sudo-mode.md) | `BaudrateWeb.AuthHooks.on_mount/4` | [`admin_sudo_deadline_test.exs`](../test/baudrate_web/live/admin_sudo_deadline_test.exs) |
| While setup is incomplete and no installation key is configured, every browser route answers 503 | [0021](adr/0021-setup-wizard-and-installation-key-gate.md) | `BaudrateWeb.Plugs.EnsureSetup.call/2` | [`setup_live_test.exs`](../test/baudrate_web/live/setup_live_test.exs) |
| The setup wizard refuses to start until the configured installation key is submitted | [0021](adr/0021-setup-wizard-and-installation-key-gate.md) | `BaudrateWeb.SetupLive.mount/3`, `Baudrate.Setup.InstallationKey.verify/1` | [`setup_live_test.exs`](../test/baudrate_web/live/setup_live_test.exs) |
| Registering or removing a WebAuthn key requires step-up re-authentication in the same LiveView process | [0022](adr/0022-step-up-reauthentication-for-second-factor-changes.md) | `Baudrate.Auth.verify_reauthentication/5` | [`profile_live_security_keys_test.exs`](../test/baudrate_web/live/profile_live_security_keys_test.exs) |
| A recovery code never satisfies step-up re-authentication | [0022](adr/0022-step-up-reauthentication-for-second-factor-changes.md) | `Baudrate.Auth.verify_reauthentication/5` | [`reauthentication_test.exs`](../test/baudrate/auth/reauthentication_test.exs) |
| A WebAuthn challenge is spendable only for the purpose it was issued for, and a mismatched pop consumes it | [0022](adr/0022-step-up-reauthentication-for-second-factor-changes.md) | `Baudrate.Auth.WebAuthnChallenges.pop/3` | [`webauthn_test.exs`](../test/baudrate/auth/webauthn_test.exs) |
| A TOTP code is accepted once per account; a later request with the same or an older step is refused | [0024](adr/0024-totp-codes-are-single-use-with-a-one-period-grace-window.md) | `Baudrate.Auth.SecondFactor.verify_totp_code/3` | [`second_factor_test.exs`](../test/baudrate/auth/second_factor_test.exs) |
| A code from the current or the previous 30-second period is accepted, and never one from the next | [0024](adr/0024-totp-codes-are-single-use-with-a-one-period-grace-window.md) | `Baudrate.Auth.SecondFactor.match_totp_step/3` | [`second_factor_test.exs`](../test/baudrate/auth/second_factor_test.exs) |
| Every TOTP code field is described by a single-use hint, always, not only after a reuse | [0024](adr/0024-totp-codes-are-single-use-with-a-one-period-grace-window.md) | `BaudrateWeb.CoreComponents.totp_code_hint/1` | [`totp_code_hint_test.exs`](../test/baudrate_web/totp_code_hint_test.exs) |
| Validating the terms checkbox and recording the acceptance are one function, and neither field is castable | [0031](adr/0031-terms-acceptance-is-recorded-and-versioned.md) | `Baudrate.Setup.User.accept_terms/1` | [`terms_acceptance_test.exs`](../test/baudrate/auth/terms_acceptance_test.exs) |
| A recovery code verifies under every configured auth key, so a rotation never locks a member out | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) | `Baudrate.Crypto.Keyring.candidates/1` | [`recovery_code_keys_test.exs`](../test/baudrate/auth/recovery_code_keys_test.exs) |

## Authorization

What an authenticated account may do. Every one of these is enforced at a context boundary, never in a LiveView ([0016](adr/0016-authorization-at-the-context-boundary.md)).

| Invariant | Why | Enforced in | Gate |
|---|---|---|---|
| Board access compares ordered role levels (guest 0 < user 1 < moderator 2 < admin 3) to the board minimum | [0011](adr/0011-role-levels-for-board-authorization.md) | `Baudrate.Setup.role_level/1`, `Baudrate.Setup.role_meets_minimum?/2` | [`board_permissions_test.exs`](../test/baudrate/content/board_permissions_test.exs) |
| Board listing queries filter by viewer role, so a board the user cannot view never appears | [0011](adr/0011-role-levels-for-board-authorization.md) | `Baudrate.Content.list_visible_top_boards/1`, `Baudrate.Content.list_visible_sub_boards/2` | [`board_permissions_test.exs`](../test/baudrate/content/board_permissions_test.exs) |
| Posting requires the role minimum, an active account and the user.create_content permission together | [0011](adr/0011-role-levels-for-board-authorization.md) | `Baudrate.Content.can_post_in_board?/2` | [`board_permissions_test.exs`](../test/baudrate/content/board_permissions_test.exs) |
| Pinning, locking or deleting an article is authorized inside the context against freshly loaded state | [0016](adr/0016-authorization-at-the-context-boundary.md) | `Baudrate.Content.toggle_pin_article/2`, `Baudrate.Content.Permissions.authorize_delete_article/2` | [`moderation_authorized_in_context_test.exs`](../test/baudrate/content/moderation_authorized_in_context_test.exs) |
| Every direct message re-checks blocks and dm_access at send time, returning {:error, :not_allowed} | [0016](adr/0016-authorization-at-the-context-boundary.md) | `Baudrate.Messaging.create_message/3` | [`messaging_test.exs`](../test/baudrate/messaging_test.exs) |
| Forwarding checks the actor can view the comment's source board before the visibility gate | [0016](adr/0016-authorization-at-the-context-boundary.md) | `Baudrate.Content.forward_comment_to_board/3`, `Baudrate.Content.Interactions.article_visible_to_user?/2` | [`content_test.exs`](../test/baudrate/content_test.exs) |
| A moved account cannot post, comment, like, boost, forward or vote, refused at the context boundary | [0025](adr/0025-account-migration.md) | `Baudrate.AccountMigration.ensure_not_moved/1` | [`read_only_test.exs`](../test/baudrate/account_migration/read_only_test.exs) |
| A block refuses interaction both ways at the context boundary; undoing an earlier like or boost stays allowed | [0026](adr/0026-blocks-stop-interaction-locally.md) | `Baudrate.Auth.blocked_with_author?/2` | [`block_enforcement_test.exs`](../test/baudrate/auth/block_enforcement_test.exs) |
| An active sanction is decided by the clock, never by a sweep | [0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md) | `Baudrate.Auth.Sanctions.ensure_can_interact/2` | [`sanctions_gate_test.exs`](../test/baudrate/auth/sanctions_gate_test.exs) |
| Every content or interaction path calls the one gate; ensure_not_moved/1 is called nowhere outside it | [0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md) | `Baudrate.Auth.ensure_can_interact/1` | [`sanctions_gate_test.exs`](../test/baudrate/auth/sanctions_gate_test.exs) |
| Nobody sanctions themselves or an account at or above their own role level; the 30-day cap is server-side | [0029](adr/0029-sanctions-are-rows-with-an-explicit-end.md) | `Baudrate.Auth.Sanctions.authorize/3`, `Baudrate.Auth.Sanctions.issue/4` | [`sanctions_test.exs`](../test/baudrate/auth/sanctions_test.exs) |
| A member behind on the published terms is refused by the interaction gate, checked last, bots exempt | [0031](adr/0031-terms-acceptance-is-recorded-and-versioned.md) | `Baudrate.Auth.ensure_can_interact/1` | [`terms_gate_test.exs`](../test/baudrate/auth/terms_gate_test.exs) |
| Every seeded permission is either checked somewhere in lib/ or named in the known-unenforced list | [0042](adr/0042-roles-are-ordered-and-capabilities-are-not-configurable.md) | `Baudrate.Setup.default_permissions/0`, `Baudrate.Setup.has_permission?/2` | [`permissions_are_enforced_test.exs`](../test/baudrate/setup/permissions_are_enforced_test.exs) |
| admin.manage_roles gates role reassignment in the context; a moderator cannot change a role | [0042](adr/0042-roles-are-ordered-and-capabilities-are-not-configurable.md) | `Baudrate.Auth.update_user_role/3` | [`permissions_are_enforced_test.exs`](../test/baudrate/setup/permissions_are_enforced_test.exs) |
| No account changes its own role, admins included | [0042](adr/0042-roles-are-ordered-and-capabilities-are-not-configurable.md) | `Baudrate.Auth.update_user_role/3` | [`permissions_are_enforced_test.exs`](../test/baudrate/setup/permissions_are_enforced_test.exs) |

## Privacy

What this instance does not disclose — to other members, to remote instances, or to third parties the reader never chose to contact.

| Invariant | Why | Enforced in | Gate |
|---|---|---|---|
| No rendered page emits an img src pointing at a host this instance does not control | [0006](adr/0006-media-proxy-no-third-party-subresources.md) | `Baudrate.Media.Rewriter.rewrite_img_src/1`, `BaudrateWeb.SafeHTML.body_html/1` | [`no_hotlink_test.exs`](../test/baudrate_web/no_hotlink_test.exs) |
| Media proxy URLs are signed with deterministic HMAC-SHA256 over the URL alone, never Phoenix.Token | [0006](adr/0006-media-proxy-no-third-party-subresources.md) | `Baudrate.Media.Proxy.url/1` | [`proxy_test.exs`](../test/baudrate/media/proxy_test.exs) |
| The media proxy fetches only URLs this instance itself signed; a forged signature 404s | [0006](adr/0006-media-proxy-no-third-party-subresources.md) | `Baudrate.Media.Proxy.verify/2` | [`media_controller_test.exs`](../test/baudrate_web/controllers/media_controller_test.exs) |
| TOTP secrets and actor RSA private keys are stored AES-256-GCM encrypted under a config-held key | [0010](adr/0010-encrypt-secrets-at-rest.md) | `Baudrate.Auth.TotpVault.encrypt/2`, `Baudrate.Federation.KeyVault.encrypt/2` | [`totp_vault_test.exs`](../test/baudrate/auth/totp_vault_test.exs) |
| Self-service export requires an active, non-bot account with TOTP enabled at least 7 days | [0023](adr/0023-data-export-threat-model.md) | `Baudrate.DataPortability.eligibility/1`, `Baudrate.DataPortability.request_export/3` | [`data_portability_test.exs`](../test/baudrate/data_portability_test.exs) |
| No secret column's value and no other person's content appears anywhere in a built archive | [0023](adr/0023-data-export-threat-model.md) | `Baudrate.DataPortability.Archive.build/2` | [`archive_test.exs`](../test/baudrate/data_portability/archive_test.exs) |
| A download is a same-origin top-level navigation carrying a single-use token, or it is refused | [0023](adr/0023-data-export-threat-model.md) | `BaudrateWeb.ExportController.download/2` | [`export_controller_test.exs`](../test/baudrate_web/controllers/export_controller_test.exs) |
| A timeline item older than 90 days with no like, boost or reply is hard-deleted | [0040](adr/0040-retention-deletes-what-nobody-touched.md) | `Baudrate.Retention.purge_timeline_items/1` | [`retention_test.exs`](../test/baudrate/retention_test.exs) |
| A soft-deleted article or comment is hard-deleted after 90 days, with its image files unlinked | [0040](adr/0040-retention-deletes-what-nobody-touched.md) | `Baudrate.Retention.purge_soft_deleted/1` | [`retention_test.exs`](../test/baudrate/retention_test.exs) |
| No rendered page carries a third-party subresource of any kind | [0045](adr/0045-the-video-player-loads-on-a-click.md) | `BaudrateWeb.CoreComponents.link_preview/1` | [`no_hotlink_test.exs`](../test/baudrate_web/no_hotlink_test.exs) |
| A YouTube preview renders a local poster and a play button, never an iframe at render time | [0045](adr/0045-the-video-player-loads-on-a-click.md) | `BaudrateWeb.CoreComponents.link_preview/1` | [`no_hotlink_test.exs`](../test/baudrate_web/no_hotlink_test.exs) |
| The only read path for a poll's voter is get_user_poll_votes/2, called with the viewer's own id | [0048](adr/0048-a-poll-records-who-voted-and-nothing-reads-it-back.md) | `Baudrate.Content.Polls.get_user_poll_votes/2` | [`poll_anonymity_test.exs`](../test/baudrate/content/poll_anonymity_test.exs) |
| A published Question carries totalItems and votersCount and no items collection | [0048](adr/0048-a-poll-records-who-voted-and-nothing-reads-it-back.md) | `Baudrate.Federation.ObjectBuilder.article_object/1` | [`poll_anonymity_test.exs`](../test/baudrate/content/poll_anonymity_test.exs) |

## Content

What a member may write, and what happens to it afterwards.

| Invariant | Why | Enforced in | Gate |
|---|---|---|---|
| Sanitization, Open Graph parsing and feed parsing are Rust NIFs via Rustler, not pure-Elixir libraries | [0005](adr/0005-rust-nifs-for-untrusted-parsing.md) | — | **none** |
| Forwarding a soft-deleted article or comment to a board fails with {:error, :not_found} | [0015](adr/0015-soft-deletion.md) | `Baudrate.Content.forward_article_to_board/3`, `Baudrate.Content.forward_comment_to_board/3` | [`content_test.exs`](../test/baudrate/content_test.exs) |
| A soft-deleted timeline item is inaccessible, so no reply, like, boost or forward can reach it | [0015](adr/0015-soft-deletion.md) | `Baudrate.Federation.timeline_item_accessible?/2` | [`timeline_item_reply_test.exs`](../test/baudrate/federation/timeline_item_reply_test.exs) |
| The published terms version moves only when an admin publishes it, and an unreadable value reads as zero | [0031](adr/0031-terms-acceptance-is-recorded-and-versioned.md) | `Baudrate.Setup.publish_terms_version/0` | [`terms_acceptance_test.exs`](../test/baudrate/auth/terms_acceptance_test.exs) |
| A rule's position is assigned by the context and swapped transactionally, never cast from a form | [0032](adr/0032-rules-are-records-and-retired-not-deleted.md) | `Baudrate.Setup.create_rule/1`, `Baudrate.Setup.move_rule/2` | [`rules_test.exs`](../test/baudrate/setup/rules_test.exs) |
| A rule is retired, never deleted, so a report that cited it still names it | [0032](adr/0032-rules-are-records-and-retired-not-deleted.md) | `Baudrate.Setup.retire_rule/1` | [`rules_test.exs`](../test/baudrate/setup/rules_test.exs) |
| Citing a rule on a report is always optional, and a non-integer client value becomes nil | [0032](adr/0032-rules-are-records-and-retired-not-deleted.md) | `BaudrateWeb.SafetyActions.report_details/1` | [`report_test.exs`](../test/baudrate_web/live/report_test.exs) |
| Article.changeset/2 casts a fixed user-field list; ap_id, url and published_at are never among them | [0049](adr/0049-user-facing-changesets-are-allow-lists.md) | `Baudrate.Content.Article.changeset/2` | [`article_test.exs`](../test/baudrate/content/article_test.exs) |
| Comment.changeset/2 never casts ap_id; only remote_changeset/2 accepts a peer-supplied URI | [0049](adr/0049-user-facing-changesets-are-allow-lists.md) | `Baudrate.Content.Comment.changeset/2` | [`comment_test.exs`](../test/baudrate/content/comment_test.exs) |
| Local content accepts only public or unlisted; trusted fields need trusted_changeset/2 | [0049](adr/0049-user-facing-changesets-are-allow-lists.md) | `Baudrate.Content.Article.trusted_changeset/2` | [`article_test.exs`](../test/baudrate/content/article_test.exs) |

## Operations

Running the instance: builds, deploys, backups, keys, retention, and knowing when something is wrong.

| Invariant | Why | Enforced in | Gate |
|---|---|---|---|
| The platform is Elixir/OTP, Phoenix 1.8 and LiveView 1.2 on Bandit; no external job runner, broker or cache | [0001](adr/0001-elixir-phoenix-liveview-platform.md) | — | **none** |
| All rate-limit checks go through the RateLimiter behaviour, and a backend error fails open | [0012](adr/0012-rate-limiting-behaviour-and-failure-modes.md) | `BaudrateWeb.Plugs.RateLimit.call/2`, `BaudrateWeb.RateLimiter.check_rate/3` | [`rate_limit_test.exs`](../test/baudrate_web/plugs/rate_limit_test.exs) |
| RealIp trusts x-forwarded-for only from a configured proxy CIDR; unset means loopback only, [] means nobody | [0012](adr/0012-rate-limiting-behaviour-and-failure-modes.md) | `BaudrateWeb.Plugs.RealIp.peer_trusted?/1`, `BaudrateWeb.Plugs.RealIp.client_ip/2` | [`real_ip_test.exs`](../test/baudrate_web/plugs/real_ip_test.exs) |
| Per-domain AP inbox limiting is 60/min, separate from the 120/min per-IP limit | [0012](adr/0012-rate-limiting-behaviour-and-failure-modes.md) | `BaudrateWeb.Plugs.RateLimitDomain.call/2` | [`rate_limit_domain_test.exs`](../test/baudrate_web/plugs/rate_limit_domain_test.exs) |
| A board mutation through the Content facade refreshes the board cache, so no lookup serves a stale board | [0014](adr/0014-ets-caches-for-settings-and-boards.md) | `Baudrate.Content.create_board/1`, `Baudrate.Content.BoardCache.refresh/0` | [`board_cache_test.exs`](../test/baudrate/content/board_cache_test.exs) |
| Writing a federation-mode or allowlist setting refreshes the domain-block cache without an explicit call | [0014](adr/0014-ets-caches-for-settings-and-boards.md) | `Baudrate.Setup.set_setting/2` | [`domain_block_cache_test.exs`](../test/baudrate/federation/domain_block_cache_test.exs) |
| CI jobs start only in the image digest recorded in image.lock, after attestation verification of that digest | [0027](adr/0027-ci-runs-in-a-pinned-attested-image.md) | `.github/workflows/ci-image-ref.yml` | **none** |
| Every job re-verifies the image's toolchain against the project's own version pins before running | [0027](adr/0027-ci-runs-in-a-pinned-attested-image.md) | `ci/image/verify-toolchain.sh` | **none** |
| Every toolchain download in the CI image carries a SHA-256 checked at image build time | [0027](adr/0027-ci-runs-in-a-pinned-attested-image.md) | `ci/image/Dockerfile` | **none** |
| A backup folder exists only once every step succeeded; a failed run removes what it wrote | [0028](adr/0028-backups-are-complete-folders-with-count-based-retention.md) | `Baudrate.Backup.Snapshots.create/2` | [`snapshots_test.exs`](../test/baudrate/backup/snapshots_test.exs) |
| Retention counts complete backups and prunes only after a new backup succeeded | [0028](adr/0028-backups-are-complete-folders-with-count-based-retention.md) | `Baudrate.Backup.Snapshots.create/2` | [`snapshots_test.exs`](../test/baudrate/backup/snapshots_test.exs) |
| Restoring copies out of a backup, and refuses a folder that is not a complete backup | [0028](adr/0028-backups-are-complete-folders-with-count-based-retention.md) | `Baudrate.Backup.Snapshots.restore/2`, `Baudrate.Release.restore_snapshot/1` | [`snapshots_test.exs`](../test/baudrate/backup/snapshots_test.exs) |
| Baudrate supports exactly one node: no cluster discovery code and no DNS_CLUSTER_QUERY exist | [0033](adr/0033-baudrate-runs-on-one-node.md) | — | **none** |
| The detailed health report listens on 127.0.0.1 only, and its address cannot be configured | [0035](adr/0035-operational-visibility-stays-on-the-host.md) | `BaudrateWeb.HealthDetail` | [`health_detail_test.exs`](../test/baudrate_web/health_detail_test.exs) |
| The health report is 200 only when every check passes, and each check fails rather than hangs | [0035](adr/0035-operational-visibility-stays-on-the-host.md) | `Baudrate.Health.report/1` | [`health_test.exs`](../test/baudrate/health_test.exs) |
| JSON logs carry an allow-list of metadata, one line per event, and the formatter never raises | [0035](adr/0035-operational-visibility-stays-on-the-host.md) | `Baudrate.Logger.JSONFormatter.format/2` | [`json_formatter_test.exs`](../test/baudrate/logger/json_formatter_test.exs) |
| A release tarball is built and started the way production does on every push, before any tag exists | [0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md) | `ci/release/build.sh`, `ci/release/smoke-test.sh` | **none** |
| Any command joining the Erlang distribution refuses the release's shipped placeholder cookie | [0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md) | `rel/env.sh.eex` | **none** |
| A rollback refuses a target release that lacks migrations already applied to the database | [0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md) | `ansible/roles/rollback/tasks/main.yml` | **none** |
| The production release is compiled on the server from the cloned tag, never downloaded from GitHub | [0037](adr/0037-the-deploy-builds-on-the-server-again.md) | `ansible/roles/deploy/tasks/main.yml` | **none** |
| The deploy refuses a host whose Debian release differs from the one CI builds and tests on | [0037](adr/0037-the-deploy-builds-on-the-server-again.md) | `ansible/roles/deploy/tasks/main.yml` | **none** |
| Every ciphertext carries the id of the key that wrote it and is bound to its owning row by the AAD | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) | `Baudrate.Crypto.Vault.encrypt/3`, `Baudrate.Crypto.Keyring.fetch/2` | [`vault_test.exs`](../test/baudrate/crypto/vault_test.exs) |
| Key rotation is resumable and idempotent, and never overwrites a value changed mid-run | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) | `Baudrate.Release.rotate_keys/1` | [`rekey_test.exs`](../test/baudrate/crypto/rekey_test.exs) |
| With no keys configured, both classes fall back to the secret_key_base derivation under the id legacy | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) | `Baudrate.Crypto.Keyring.current/1` | [`keyring_test.exs`](../test/baudrate/crypto/keyring_test.exs) |
| A configured key must be Base64, exactly 32 bytes, uniquely identified, and never named legacy | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) | `config/runtime.exs` | [`runtime_keys_test.exs`](../test/baudrate/crypto/runtime_keys_test.exs) |
| The health report fails while any stored value references a key id configuration no longer has | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) | `Baudrate.Crypto.Rekey.usage/0` | [`health_test.exs`](../test/baudrate/health_test.exs) |
| A backup manifest records the key ids in force, so restoring against the wrong key set is diagnosable | [0038](adr/0038-encryption-keys-are-separate-and-rotatable.md) | `Baudrate.Backup.Snapshots.create/2` | [`snapshots_test.exs`](../test/baudrate/backup/snapshots_test.exs) |
| Retention never deletes a row a report points at, nor any bot syndication ledger row | [0040](adr/0040-retention-deletes-what-nobody-touched.md) | `Baudrate.Retention.run/1` | [`retention_test.exs`](../test/baudrate/retention_test.exs) |
| The worker heartbeat key is :syndication_feed_worker, with no alias for the old :feed_worker | [0041](adr/0041-rss-and-atom-are-syndication.md) | `Baudrate.Health.Heartbeat.beat/1` | [`syndication_feed_worker_test.exs`](../test/baudrate/bots/syndication_feed_worker_test.exs) |
| A check failing two consecutive hourly polls notifies every admin and nobody else | [0044](adr/0044-the-instance-tells-its-admins-when-it-is-unwell.md) | `Baudrate.Health.Alerts.run/2`, `Baudrate.Notification.Hooks.notify_health_alert/1` | [`alerts_test.exs`](../test/baudrate/health/alerts_test.exs) |
| health_alert and health_recovered ignore per-type notification preferences | [0044](adr/0044-the-instance-tells-its-admins-when-it-is-unwell.md) | `Baudrate.Notification.Notification.always_delivered_types/0` | [`alerts_test.exs`](../test/baudrate/health/alerts_test.exs) |
| A healthy, flapping or restarted instance stays quiet; recovery is announced once | [0044](adr/0044-the-instance-tells-its-admins-when-it-is-unwell.md) | `Baudrate.Health.Alerts.run/2`, `BaudrateWeb.Helpers.translate_health_check/1` | [`alerts_test.exs`](../test/baudrate/health/alerts_test.exs) |

## Web

The rendered page: accessibility, localisation, and the CSP.

| Invariant | Why | Enforced in | Gate |
|---|---|---|---|
| Every phx-hook name used in a template is registered with the LiveSocket in assets/js/app.js | [0017](adr/0017-tailwind-daisyui-esbuild-asset-pipeline.md) | — | [`js_hooks_registered_test.exs`](../test/baudrate_web/js_hooks_registered_test.exs) |
| The build depends on no npm package: the repo carries no package.json and no node_modules | [0017](adr/0017-tailwind-daisyui-esbuild-asset-pipeline.md) | — | **none** |
| Every meaningful element in a page template carries a stable, semantic id and/or class | [0018](adr/0018-semantic-ids-and-classes-for-accessibility.md) | — | **none** |
| An id is unique per rendered page, and a :for item derives its id from the record it renders | [0018](adr/0018-semantic-ids-and-classes-for-accessibility.md) | — | [`semantic_anchors_test.exs`](../test/baudrate_web/semantic_anchors_test.exs) |
| Custom CSS targets semantic id/class selectors, never structural or positional ones | [0018](adr/0018-semantic-ids-and-classes-for-accessibility.md) | — | [`semantic_anchors_test.exs`](../test/baudrate_web/semantic_anchors_test.exs) |
| No translation interpolates a binding its msgid does not provide | [0019](adr/0019-gettext-i18n-no-bare-strings.md) | — | [`gettext_interpolation_test.exs`](../test/baudrate_web/gettext_interpolation_test.exs) |
| No user-visible string is written bare; every one goes through gettext() | [0019](adr/0019-gettext-i18n-no-bare-strings.md) | — | **none** |
| A role or status enum value renders through the shared translate_* helper everywhere it appears | [0019](adr/0019-gettext-i18n-no-bare-strings.md) | `BaudrateWeb.Helpers.translate_role/1`, `BaudrateWeb.Helpers.translate_status/1` | [`helpers_test.exs`](../test/baudrate_web/helpers_test.exs) |
| /feed redirects permanently to /timeline with the query string intact | [0039](adr/0039-the-personal-stream-is-a-timeline.md) | `BaudrateWeb.PageController.feed_redirect/2` | [`page_controller_test.exs`](../test/baudrate_web/controllers/page_controller_test.exs) |
| CSP frame-src admits exactly one origin, www.youtube-nocookie.com | [0045](adr/0045-the-video-player-loads-on-a-click.md) | `BaudrateWeb.Router` | [`no_hotlink_test.exs`](../test/baudrate_web/no_hotlink_test.exs) |

## Process

How the project keeps its own records and structure honest.

| Invariant | Why | Enforced in | Gate |
|---|---|---|---|
| Every ADR file on disk has an index row, and each row keeps its record's Status-line ADR refs and verbs | [0000](adr/0000-use-architecture-decision-records.md) | — | [`adr_index_test.exs`](../test/doc/adr_index_test.exs) |
| External callers use the context facade (Auth.f/n, Federation.f/n) and never reach into its sub-modules | [0002](adr/0002-context-facades.md) | — | **none** |
| Every rate-limit check dispatches through the configured RateLimiter implementation, never Hammer directly | [0020](adr/0020-testing-strategy.md) | `BaudrateWeb.RateLimiter.check_rate/3` | [`rate_limits_test.exs`](../test/baudrate_web/rate_limits_test.exs) |
| The two RSS senses are named syndication: parser, worker, controller, XML view and the ledger table | [0041](adr/0041-rss-and-atom-are-syndication.md) | `Baudrate.Bots.BotSyndicationItem` | [`syndication_feed_controller_test.exs`](../test/baudrate_web/controllers/syndication_feed_controller_test.exs) |
| Every context operation that writes state anyone can observe is named on the context facade | [0047](adr/0047-the-facade-lists-every-way-a-context-changes-the-world.md) | `Baudrate.Federation.block_domain/3`, `Baudrate.Federation.suspend_remote_actor/3` | **none** |
| Render helpers, schemas, PubSub topics, web-tier plumbing and admin read models may bypass the facade | [0047](adr/0047-the-facade-lists-every-way-a-context-changes-the-world.md) | `Baudrate.Content.Markdown.to_html/1` | **none** |

## Rules with no automated gate

Listed deliberately. Each is held up by review, by configuration, or
by the absence of code rather than the presence of a check — so each is a
place where drift would be silent.

| Invariant | Why | Why there is no gate |
|---|---|---|
| The platform is Elixir/OTP, Phoenix 1.8 and LiveView 1.2 on Bandit; no external job runner, broker or cache | [0001](adr/0001-elixir-phoenix-liveview-platform.md) | A platform choice, not a rule. Nothing to falsify. |
| External callers use the context facade (Auth.f/n, Federation.f/n) and never reach into its sub-modules | [0002](adr/0002-context-facades.md) | Superseded in practice by [0047](adr/0047-the-facade-lists-every-way-a-context-changes-the-world.md), which narrows the rule and explains why it is a judgement rather than a test. |
| Sanitization, Open Graph parsing and feed parsing are Rust NIFs via Rustler, not pure-Elixir libraries | [0005](adr/0005-rust-nifs-for-untrusted-parsing.md) | A dependency choice. The NIFs either compile or they do not. |
| The build depends on no npm package: the repo carries no package.json and no node_modules | [0017](adr/0017-tailwind-daisyui-esbuild-asset-pipeline.md) | The absence of `package.json` is the invariant; a test asserting a file does not exist would pass vacuously forever. |
| Every meaningful element in a page template carries a stable, semantic id and/or class | [0018](adr/0018-semantic-ids-and-classes-for-accessibility.md) | "Meaningful" is a judgement — it excludes presentational wrappers and leaf components, and no test draws that line. Measured: 23 of 118 `:for` elements carry no class, nearly all legitimately, so an approximating gate would fail the build for correct code. The *uniqueness* and *stylesheet* halves of 0018 are gated; this half is review-held. |
| No user-visible string is written bare; every one goes through gettext() | [0019](adr/0019-gettext-i18n-no-bare-strings.md) | `gettext_interpolation_test.exs` checks only that no translation interpolates a binding its msgid lacks. Nothing detects a bare English string, and there is no locale-parity check. |
| CI jobs start only in the image digest recorded in image.lock, after attestation verification of that digest | [0027](adr/0027-ci-runs-in-a-pinned-attested-image.md) | Enforced by CI workflows and `verify-toolchain.sh`, outside the Elixir suite. |
| Every job re-verifies the image's toolchain against the project's own version pins before running | [0027](adr/0027-ci-runs-in-a-pinned-attested-image.md) | Enforced by CI workflows and `verify-toolchain.sh`, outside the Elixir suite. |
| Every toolchain download in the CI image carries a SHA-256 checked at image build time | [0027](adr/0027-ci-runs-in-a-pinned-attested-image.md) | Enforced by CI workflows and `verify-toolchain.sh`, outside the Elixir suite. |
| Baudrate supports exactly one node: no cluster discovery code and no DNS_CLUSTER_QUERY exist | [0033](adr/0033-baudrate-runs-on-one-node.md) | The invariant is that cluster discovery code does not exist. Enforced by its absence. |
| A release tarball is built and started the way production does on every push, before any tag exists | [0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md) | Enforced by CI workflows, `rel/env.sh.eex` and Ansible, outside the Elixir suite. |
| Any command joining the Erlang distribution refuses the release's shipped placeholder cookie | [0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md) | Enforced by CI workflows, `rel/env.sh.eex` and Ansible, outside the Elixir suite. |
| A rollback refuses a target release that lacks migrations already applied to the database | [0036](adr/0036-production-runs-releases-built-and-attested-in-ci.md) | Enforced by CI workflows, `rel/env.sh.eex` and Ansible, outside the Elixir suite. |
| The production release is compiled on the server from the cloned tag, never downloaded from GitHub | [0037](adr/0037-the-deploy-builds-on-the-server-again.md) | Enforced by Ansible pre-flight asserts, outside the Elixir suite. |
| The deploy refuses a host whose Debian release differs from the one CI builds and tests on | [0037](adr/0037-the-deploy-builds-on-the-server-again.md) | Enforced by Ansible pre-flight asserts, outside the Elixir suite. |
| Every context operation that writes state anyone can observe is named on the context facade | [0047](adr/0047-the-facade-lists-every-way-a-context-changes-the-world.md) | Deliberate. "Changes the world" is a judgement; the record says an approximating test would either fail on render helpers or pass on what it should catch. |
| Render helpers, schemas, PubSub topics, web-tier plumbing and admin read models may bypass the facade | [0047](adr/0047-the-facade-lists-every-way-a-context-changes-the-world.md) | Deliberate. "Changes the world" is a judgement; the record says an approximating test would either fail on render helpers or pass on what it should catch. |

---

137 rows across 50 records, 84 distinct gates, 17 ungated. Generated and verified 2026-09-19.
