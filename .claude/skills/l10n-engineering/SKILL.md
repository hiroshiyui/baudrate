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

3. **Fix every fuzzy entry — new or old, in every locale.** A `fuzzy` flag
   means `mix gettext.extract --merge` guessed the translation from a similar
   msgid and nobody checked it, and **Gettext serves it anyway**. There is no
   acceptable number of them: the target is **zero in every locale and
   domain**, and `translation_coverage_test.exs` fails on any.
   - Find them: `grep -n -A3 '^#,.*fuzzy' priv/gettext/*/LC_MESSAGES/*.po`,
     plus every new msgid in `git diff priv/gettext/default.pot | grep '^+msgid'`
     (review those even when not flagged — an entry left with `msgstr ""`
     is new too).
   - **zh_TW / ja_JP:** write the real translation by hand against the msgid
     in front of you, then delete `fuzzy` from the `#,` line (keep the other
     flags) and any `#|` previous-msgid lines. Real guesses the matcher made:
     "Admin Dashboard" → 管理看板 (看板 is *board*), "%{count} waiting" →
     "%{count} minutes ago", "abandoned" → "Job abandoned.".
   - **en:** blank the `msgstr` (Gettext falls back to the msgid, which *is*
     the English) and delete the flag. Never retype the English.
   - **Plurals:** `zh_TW` and `ja_JP` have `nplurals=1` (only `msgstr[0]`);
     `en` has two forms.
   - **A reused msgid reuses its meaning.** If an existing msgid's
     translation does not fit the new place ("Dismiss" is the report sense
     駁回 / 却下; "Posted", "Order", "From", "To"), use a different msgid
     rather than a translation that is wrong in one of the two places.
   - A string whose translation really is the English (an example value in a
     placeholder) is written out in full with a translator comment saying
     so; an empty entry cannot be told from an oversight.
   - Keep orphans out: running `mix gettext.extract --merge` again must
     report nothing new, reworded or removed.

3a. **Fix wrong translations that are not flagged.** The matcher's guesses
   lose their flag the moment someone clears it without reading, and older
   entries predate the gates — so every run also audits what is already
   there, and **fixes what it finds in the same run**, not in a follow-up:
   - **Forbidden terms:**
     `grep -nE '版面|板塊|用戶|繁體中文|正體中文' priv/gettext/zh_TW/LC_MESSAGES/*.po`
     and `grep -n 'ボード' priv/gettext/ja_JP/LC_MESSAGES/*.po` (ダッシュボード
     is fine). Each hit is rewritten with the table's term.
   - **Terms that drifted:** for each row of the table in step 4, grep the
     msgids that contain the English term and check their msgstrs use the
     settled translation — e.g. every msgid with "delivery" says 遞送 / 配信,
     every one with "board" says 看板 / 掲示板.
   - **Meaning that drifted:** read the msgstr beside its msgid for every
     entry near what changed (same file, same feature), and for any entry
     whose msgid is short and generic ("Dismiss", "Close", "Remove",
     "Status", "Open"), where one translation is most likely shared by two
     senses. Check that bindings match (`%{…}` names and count) — the
     coverage test catches extra bindings, not a dropped one.
   - **en entries that are not blank** are wrong by definition (the test
     fails on them); blank them.
   - Report what was fixed, with the msgid and the old and new msgstr, in
     the commit message.

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
     an empty `zh_TW` or `ja_JP` msgstr, on any `en` msgstr that differs from
     its msgid, on a translation that interpolates a binding its message does
     not pass, and on **any entry still marked fuzzy, in any locale**.
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
