# Dialyzer baseline (Phase 8A). Reviewed 2026-09-25: 404 warnings became 54.
#
#   * 344 were specs naming `Schema.t()` on schemas that defined no `t/0`;
#     each schema now does.
#   * Real defects fixed rather than listed: specs that left out an error the
#     function returns (`Recovery.set_verification/3` and `:no_live_challenge`,
#     `DeliveryStats.paginate_actionable_jobs/1` and `:per_page`), a spec so
#     narrow it made a correct guard look impossible
#     (`Validator.validate_object_origin/2`), and a flash for an
#     `:account_too_new` refusal that invite generation stopped returning in
#     March.
#   * What is left is listed below by file and kind, never by line, so an
#     unrelated edit does not fail CI. It is defensive code Dialyzer can prove
#     unreachable (guards on settings that are always strings, catch-alls
#     after exhaustive clauses, compile-time flags), and opaque-type notices
#     about `MapSet` and `Ecto.Multi` that Dialyzer raises for correct code.
#
# CI fails on any warning not covered here. Remove an entry when its warnings
# are gone (`list_unused_filters` reports the stale ones); never add one
# without reading the warning first.
[
  {"lib/baudrate/auth/challenge.ex", :guard_fail},
  {"lib/baudrate/auth/challenge.ex", :pattern_match_cov},
  {"lib/baudrate/auth/trust.ex", :guard_fail},
  {"lib/baudrate/auth/trust.ex", :pattern_match_cov},
  {"lib/baudrate/bots/favicon_fetcher.ex", :call_without_opaque},
  {"lib/baudrate/bots/fetcher.ex", :pattern_match_cov},
  {"lib/baudrate/bots/syndication_feed_worker.ex", :pattern_match},
  {"lib/baudrate/bots/syndication_feed_worker.ex", :pattern_match_cov},
  {"lib/baudrate/content/articles.ex", :call_without_opaque},
  {"lib/baudrate/content/bookmarks.ex", :contract_with_opaque},
  {"lib/baudrate/content/comments.ex", :call_without_opaque},
  {"lib/baudrate/content/likes.ex", :contract_with_opaque},
  {"lib/baudrate/content/link_preview/fetcher.ex", :pattern_match},
  {"lib/baudrate/content/link_preview/fetcher.ex", :pattern_match_cov},
  {"lib/baudrate/content/polls.ex", :call_without_opaque},
  {"lib/baudrate/data_portability.ex", :pattern_match_cov},
  {"lib/baudrate/federation/http_client.ex", :pattern_match},
  {"lib/baudrate/federation/http_client.ex", :pattern_match_cov},
  {"lib/baudrate/federation/inbox_handler.ex", :call_with_opaque},
  {"lib/baudrate/federation/inbox_handler.ex", :guard_fail},
  {"lib/baudrate/federation/inbox_handler.ex", :pattern_match_cov},
  {"lib/baudrate/media/cache.ex", :pattern_match},
  {"lib/baudrate/messaging.ex", :call_without_opaque},
  {"lib/baudrate/moderation/held_posts.ex", :guard_fail},
  {"lib/baudrate/moderation/held_posts.ex", :pattern_match_cov},
  {"lib/baudrate/setup.ex", :call_without_opaque},
  {"lib/baudrate_web/gettext.ex", :call_without_opaque},
  {"lib/baudrate_web/live/admin/boards_live.ex", :pattern_match_cov},
  {"lib/baudrate_web/live/admin/settings_live.ex", :call_without_opaque},
  {"lib/baudrate_web/live/article_edit_live.ex", :guard_fail},
  {"lib/baudrate_web/live/article_live.ex", :guard_fail},
  {"lib/baudrate_web/live/article_new_live.ex", :guard_fail},
  {"lib/baudrate_web/live/profile_security_live.ex", :pattern_match_cov},
  {"lib/baudrate_web/live/setup_live.ex", :guard_fail},
  {"lib/baudrate_web/live/timeline_live.ex", :guard_fail}
]
