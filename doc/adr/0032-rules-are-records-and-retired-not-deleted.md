# 0032 — Site rules are records, retired rather than deleted, and a report may cite one

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Baudrate maintainers
- **Related:** completes P1-D9, deferred by
  [0031](0031-terms-acceptance-is-recorded-and-versioned.md), which made the
  rules a public page but left them a single document

## Context

The report dialog has offered a `rule_violation` category ("Breaks a rule")
since the moderation work, and it could only ever say *that* a rule was broken,
never which. The rules were one markdown setting, and a blob has no addressable
parts: there was nothing for a report to point at.

That leaves the most specific category the least useful one. A moderator
reading "breaks a rule" plus free text has learned nothing the free text did
not already tell them, and the reporter has no way to say "this is rule 4"
except by typing it and hoping the numbering does not change.

## Decision

### 1. A rule is a record

`rules` rows carry `position`, `title`, an optional markdown `body`, and
`retired_at`. `/rules` renders them numbered, each with a stable `#rule-N`
anchor so a moderator or member can link to the one they mean.

The existing `rules` setting migrates into the first row rather than being
dropped; the migration cannot guess where one rule ends and the next begins, so
an admin who had written a document gets it back as a single rule to split up.

### 2. Position is assigned by the context, never by the form

`create_rule/1` puts the new rule at the end and `move_rule/2` swaps a rule
with its neighbour inside a transaction. `position` is not castable.

An admin typing a number is how two rules come to claim the same place, and
writing one side of a swap and then the other is how a failure leaves them
that way permanently.

The next position counts over every row, retired ones included, so retiring a
rule never hands its number to a different one.

### 3. A rule is retired, never deleted

A retired rule leaves `/rules` and the report dialog, but the row stays. Every
report that cited it still resolves to the rule its author meant.

Hard deletion with `ON DELETE SET NULL` was the alternative, and it is what the
foreign key still does as a backstop. It was rejected as the normal path
because it silently empties the citation on every past report — the moderator
of a six-month-old report loses the one piece of structured information it
carried, and nothing anywhere records that it was ever there.

### 4. Citing a rule is optional, always

`reports.rule_id` is nullable and is never required, not even when the category
is `rule_violation`.

Requiring it would put a validation failure in a dialog that has no inline
error display, and — more importantly — it would make reporting harder for the
person least able to navigate the rules page. Reporting abuse is deliberately
kept open even to members under sanction (ADR 0029) and to members behind on
the terms (ADR 0031); making them first find the right rule number contradicts
that. The category already carries the claim; the citation sharpens it.

The client sends `rule_id` through `SafetyActions.report_details/1`, the one
place report fields come from the client. A value that is not a positive
integer becomes `nil` rather than reaching the changeset, and one naming no
existing rule is refused by the foreign key.

## Consequences

- Rules accumulate. A long-lived instance will have retired rules nobody can
  delete through the UI. That is the trade for never breaking a citation; if it
  ever becomes a problem, purging rules that no report references is a separate,
  safe operation.
- `/rules` no longer has an admin editor on `/admin/settings`; it has its own
  page at `/admin/rules`, linked from there.
- `Setup.get_policy/1` and `update_policy/2` now cover only the terms and the
  privacy policy. The footer still treats rules as one of the three policies,
  asking the table instead of the settings.
- Reordering rules changes the numbers members see, and a report cites a rule
  by id rather than by number, so an old report keeps pointing at the right
  rule even after the list is reordered. The number shown on the report card is
  therefore the rule's *title*, not its position.

## Acceptance gate

`test/baudrate/setup/rules_test.exs`, and the citation path in
`test/baudrate_web/live/report_test.exs`. The test that matters most is that a
report citing a retired rule still names it.
