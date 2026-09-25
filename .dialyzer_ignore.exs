# Dialyzer baseline (Phase 8A). Reviewed 2026-09-25: 404 warnings became 54,
# then 44 with OTP 29 and Elixir 1.20, then 20 when the rest of the baseline
# was reviewed under CLAUDE.md's "Follow the type checker".
#
#   * 344 were specs naming `Schema.t()` on schemas that defined no `t/0`;
#     each schema now does.
#   * Real defects fixed rather than listed: specs that left out an error the
#     function returns (`Recovery.set_verification/3` and `:no_live_challenge`,
#     `DeliveryStats.paginate_actionable_jobs/1` and `:per_page`, and the
#     three image-description setters, whose sanction and filter refusals
#     made the flash that reports them look unreachable), a spec so narrow it
#     made a correct guard look impossible
#     (`Validator.validate_object_origin/2`), and a flash for an
#     `:account_too_new` refusal that invite generation stopped returning in
#     March.
#   * Code Dialyzer proves unreachable is deleted, never listed: guards on
#     settings that are always strings, catch-alls after exhaustive clauses,
#     `||` fallbacks for values that are never nil.
#   * What is left cannot be fixed in this code, and is listed by file and
#     kind, never by line, so an unrelated edit does not fail CI:
#       - `call_without_opaque` / `call_with_opaque`: Dialyzer's opaque-type
#         check on `Ecto.Multi` (whose `names` field is a `MapSet`), on a
#         `MapSet` carried in the reply-chain walk's state, and in the
#         plural functions Gettext generates. The code is correct; a spec on
#         the helper that builds the Multi does not change the warning.
#       - `pattern_match` at line 1 of `http_client.ex` and `media/cache.ex`:
#         compile-time flags (`Application.compile_env`) that are false in
#         the build Dialyzer checks and true in the test build.
#
# CI fails on any warning not covered here. Remove an entry when its warnings
# are gone (`list_unused_filters` reports the stale ones); never add one
# without reading the warning first, and never to hide dead code.
[
  {"lib/baudrate/content/articles.ex", :call_without_opaque},
  {"lib/baudrate/content/comments.ex", :call_without_opaque},
  {"lib/baudrate/content/polls.ex", :call_without_opaque},
  {"lib/baudrate/federation/http_client.ex", :pattern_match},
  {"lib/baudrate/federation/inbox_handler.ex", :call_with_opaque},
  {"lib/baudrate/media/cache.ex", :pattern_match},
  {"lib/baudrate/messaging.ex", :call_without_opaque},
  {"lib/baudrate/setup.ex", :call_without_opaque},
  {"lib/baudrate_web/gettext.ex", :call_without_opaque}
]
