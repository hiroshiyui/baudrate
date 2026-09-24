---
name: l10n-engineering
description: Keep internationalisation, localisation and multilingual support (i18n/l10n/m17n) robust — untranslated strings, raw identifiers, gettext extraction and review, terminology, locale and time-zone handling, and the gates. Run after any change that adds or alters user-visible text, and before a release.
---

When performing l10n engineering, always follow these steps. The locales are
`en` (the source text), `zh_TW` and `ja_JP`.

1. **Find user-visible text that is not translated.** Sweep `lib/baudrate_web`
   (templates, LiveViews, controllers, components) and any context function
   that returns text a person reads:
   - Bare English in templates, flash messages, and the attributes a person
     reads or hears (`aria-label`, `title`, `placeholder`, `alt`,
     `data-confirm`), feed metadata and notification or push text. Wrap it in
     `gettext()`, or `ngettext()` for anything counted.
   - Dynamic values use `%{var}` inside the `gettext` string, never `"#{…}"`
     interpolation or concatenating a translated fragment with a variable.
     Word order differs between the locales.
   - **Raw identifiers shown to people.** A template that renders an enum
     field directly (`{x.status}`, `{x.kind}`, `{x.target_type}`,
     `{x.reason}` for a reason code) is a bug. Route it through a
     translating helper.
   - **Fallback helpers** (`translate_*(other), do: other`, `kind_label/1`,
     `status_label/1`, `action_label/1`, `ModerationLogLive.translate_action/1`
     and `translate_target_type/1`, `Helpers.health_check_title/1`) must
     cover every value of the enumeration they label. Check them against the
     source of truth: `@statuses`, `@kinds`, `@actions`, `@valid_actions`,
     `Health.check_names/0`, and every `target_type:` literal. Where no test
     enforces that coverage, add one (`moderation_log_live_test.exs` shows the
     pattern).
   - Error atoms that reach a flash go through
     `BaudrateWeb.Helpers.refusal_message/3` or a dedicated message helper,
     never `inspect/1`.

2. **Extract and merge:** `mix gettext.extract --merge`. Read the summary:
   the number of new messages, how many were "reworded (fuzzy)", and how many
   were removed.

3. **Review every new or reworded msgid by hand.** Start from
   `git diff priv/gettext/default.pot | grep '^+msgid'`, not only the entries
   left with `msgstr ""`.
   - **The fuzzy matcher mistranslates silently.** It attaches a plausible,
     wrong translation from a similar string. Real examples: "Admin Dashboard"
     → 管理看板 (看板 means *board*), "%{count} waiting" → "%{count} minutes
     ago", "abandoned" → "Job abandoned.", "Dismiss" reused as the report
     sense 駁回 / 却下. Rewrite every fuzzy entry and remove its `fuzzy` flag.
   - **`en` stays blank.** Every `en` msgstr is empty so Gettext falls back
     to the msgid; blank it, never retype the English. `en` must keep exactly
     its existing count of `fuzzy` flags (109 at the time of writing) —
     `grep -c fuzzy priv/gettext/en/LC_MESSAGES/default.po` before and after.
   - **Plurals:** `zh_TW` and `ja_JP` have `nplurals=1` (only `msgstr[0]`);
     `en` has two forms.
   - **A reused msgid reuses its meaning.** If an existing msgid's translation
     does not fit the new place ("Dismiss", "Posted", "Order", "From", "To"),
     use a different msgid rather than a translation that is wrong in one of
     the two places.
   - A string whose translation really is the English (an example value in a
     placeholder) is written out in full, with a translator comment saying
     so; an empty entry cannot be told from an oversight.
   - Keep orphans out: messages the merge reports as removed must not linger,
     and `mix gettext.extract --merge` run again must report nothing new.

4. **Terminology is consistent across locales.** Before translating, look up
   how the concept is already translated (`grep -A1 '^msgid "X"$'` in both
   `.po` files) and match it. The established terms:

   | Concept | zh_TW | ja_JP |
   |---|---|---|
   | Board | 看板 (never 版面, 板塊) | 掲示板 (never ボード) |
   | User | 使用者 (never 用戶) | ユーザー |
   | Moderator | 版主 | モデレーター |
   | Moderation Log | 管理日誌 | モデレーションログ |
   | Delivery | 遞送 | 配信 |
   | Federation | 聯邦 | 連合 |
   | Timeline | 時間軸 | タイムライン |
   | Report (abuse) | 檢舉 | 通報 |
   | Held post | 待審貼文 | 保留中の投稿 |

   Extend this table in the skill when a new recurring term is settled.

5. **Locale names are autonyms, and `zh_TW` is 台灣漢語** — never 繁體中文 and
   never 正體中文, which name a script. The switcher, `doc/eua.md` and
   `doc/privacy-policy.md` (their governing-language clauses) must agree.
   The Gettext locale code stays `zh_TW`.

6. **m17n and runtime behaviour.** Check any change near these:
   - **Locale resolution** is the `locale` cookie, then
     `session[:preferred_locales]`, then `Accept-Language`, then `en`, and
     every value passes `BaudrateWeb.Locale.known?/1` before
     `Gettext.put_locale/1`. A LiveView cannot write the session, so a
     preference change goes through `LocaleController`.
   - **Time zones:** timestamps render through `format_datetime/2`,
     `format_date/1` and `BaudrateWeb.TimeZone.shift/1`, never
     `DateTime.shift_zone!/2`. `datetime_attr/1` is UTC with a `Z`. The zone
     is cleared on every request (`Plugs.ClearTimeZone`).
   - **Nothing translated is frozen into a stored row.** Text written at
     ingest or in a background process must not carry that process's locale
     (image-alt fallbacks are filled at render time, ADR 0061). Notifications
     store data and are rendered in the reader's locale.
   - **Text from users and remote servers in any script:** Unicode
     normalisation for matching (the filters' NFKC and `\p{Cf}` stripping),
     bidi overrides stripped from remote names, and zero-width joiners kept.
   - **Layout holds for CJK and long tokens:** `break-words` on
     user or remote text, `minmax(0,1fr)` in arbitrary grid tracks, and
     `min-w-0` on flex content columns. `features/layout_test.exs` checks
     widths down to 500 px.
   - **Names a content blocker hides:** never name a control `accept`,
     `consent`, `cookie`, `gdpr`, `ccpa`, `banner`, `promo`, `popup`,
     `overlay` or `sponsor`. Notices use `-notice`.

7. **Run the gates.**
   - `mix test test/baudrate_web/translation_coverage_test.exs`. It fails on
     an empty `zh_TW` or `ja_JP` msgstr and on any `en` msgstr that differs
     from its msgid.
   - Any label-coverage tests touched in step 1.
   - The full suite with seed 9527 in 4 partitions.
   - When templates or CSS changed, the browser crawls:
     `mix test --include feature test/baudrate_web/features/js_errors_test.exs test/baudrate_web/features/layout_test.exs`,
     after clearing stale digest assets.

8. **Document.** If a new terminology rule, locale behaviour or naming rule
   was settled, record it where it belongs: this skill's table, `CLAUDE.md`
   (Project Conventions / While Coding), or `doc/development.md`.

9. **Commit.** `.pot` and `.po` changes go with the feature they belong to. A
   standalone translation fix is `fix(i18n): …`. Never mix it with unrelated
   work.
