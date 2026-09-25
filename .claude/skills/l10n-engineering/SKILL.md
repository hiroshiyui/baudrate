---
name: l10n-engineering
description: Keep i18n/l10n/m17n robust — untranslated strings, raw identifiers, gettext extraction and hand review, terminology, locale and time-zone handling, and the gates. Run after any change to user-visible text, and before a release.
---

Locales: `en` (the source text), `zh_TW`, `ja_JP`.

1. **Find untranslated text** in `lib/baudrate_web` and any context text a person
   reads: bare English in templates, flashes, `aria-label`/`title`/`placeholder`/
   `alt`/`data-confirm`, feed metadata, notification and push text. Wrap in `gettext()`
   (`ngettext()` when counted), with `%{var}`, never `"#{…}"` or concatenation.
   - **Raw identifiers** (`{x.status}`, `{x.kind}`, a reason code) go through a
     translating helper. Fallback helpers (`translate_*`, `*_label/1`,
     `ModerationLogLive.translate_action/1`, `Helpers.health_check_title/1`) cover
     every value of their source of truth (`@statuses`, `@kinds`, `@valid_actions`,
     `Health.check_names/0`, every `target_type:`); add a coverage test where none
     exists (`moderation_log_live_test.exs` is the pattern).
   - Error atoms reaching a flash go through `Helpers.refusal_message/3` or a
     dedicated helper, never `inspect/1`.
2. **Extract:** `mix gettext.extract --merge`; read the new / fuzzy / removed counts.
3. **Zero fuzzy, in every locale and domain** (Gettext serves fuzzy guesses).
   Find them with `grep -n -A3 '^#,.*fuzzy' priv/gettext/*/LC_MESSAGES/*.po` and review
   every new msgid (`git diff priv/gettext/default.pot | grep '^+msgid'`) even if
   unflagged.
   - zh_TW / ja_JP: translate by hand against the msgid, drop `fuzzy` and `#|` lines.
   - en: blank the msgstr and drop the flag; never retype the English.
   - Plurals: zh_TW and ja_JP have `nplurals=1` (`msgstr[0]` only); en has two.
   - A reused msgid reuses its meaning ("Dismiss" is the report sense 駁回 / 却下); use a
     new msgid rather than a translation wrong in one place.
   - A translation that really is the English is written out with a translator comment.
   - Re-running the extract reports nothing new, reworded or removed.
3a. **Fix wrong translations that are not flagged**, in the same run:
   `grep -nE '版面|板塊|用戶|繁體中文|正體中文'` (zh_TW) and `grep -n 'ボード'` (ja_JP;
   ダッシュボード is fine); check msgids containing each table term use the settled
   translation; read short generic msgids near the change; check `%{…}` bindings match;
   blank any non-blank en msgstr. List the fixes (msgid, old, new) in the commit message.
4. **Terminology** (grep the `.po` files for the existing term first):

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

   Extend the table when a recurring term is settled.
5. **Locale names are autonyms; `zh_TW` is 台灣漢語**, never 繁體中文 / 正體中文 (scripts).
   The switcher, `doc/eua.md` and `doc/privacy-policy.md` agree. The code stays `zh_TW`.
6. **Runtime behaviour** near a change: locale resolution and `Locale.known?/1` (a
   preference change goes through `LocaleController`); times through
   `format_datetime/2`, `format_date/1`, `TimeZone.shift/1`, `datetime_attr/1` is UTC;
   nothing translated is frozen into a stored row (render-time fallbacks, ADR 0061;
   notifications store data); NFKC and `\p{Cf}` in matching, bidi overrides stripped
   from remote names, ZWJ kept; CJK and long tokens do not break layout; no
   content-blocker words in control names.
7. **Gates:** `translation_coverage_test.exs` (empty zh_TW/ja_JP, non-blank en, extra
   bindings, any fuzzy), any label-coverage tests touched, the full suite (seed 9527,
   4 partitions), and after template/CSS changes the `js_errors` and `layout` crawls
   (`--include feature`, stale digests cleared).
8. **Document** a newly settled rule here, in `CLAUDE.md` or in `doc/development.md`.
9. **Commit** `.pot`/`.po` changes with their feature; a standalone fix is
   `fix(i18n): …`.
