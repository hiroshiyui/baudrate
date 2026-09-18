# 0044 — The instance tells its admins when it is unwell

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** Baudrate maintainers
- **Amends** [0035](0035-operational-visibility-stays-on-the-host.md),
  decision 5 ("Baudrate does not notify"), which explicitly left this open
  under Phase 2A. Everything else in 0035 stands: the report is still
  loopback-only, still counts and statuses, still the one place to poll.
- **Related:** closes the last open item of Phase 2A; uses the Web Push
  channel from [0038](0038-encryption-keys-are-separate-and-rotatable.md)
  (the VAPID key) and the always-delivered notice class from
  [0022](0022-step-up-reauthentication-for-second-factor-changes.md) and
  [0029](0029-sanctions-are-rows-with-an-explicit-end.md)

## Context

[ADR 0028](0028-backups-are-complete-folders-with-count-based-retention.md)
built backups that verify themselves. [ADR 0035](0035-operational-visibility-stays-on-the-host.md)
built a report that knows when they have stopped. Neither told anyone. The
report answers `503`, `scripts/pull-backups.sh` exits non-zero, and both wait
for a monitor the operator has to build and maintain separately.

Decision 5 of 0035 recorded that as deliberate, on three grounds: the instance
had no email (D3), no push channel, and no stored notification credentials.

**The second of those was not true when it was written.** Web Push — service
worker, `PushManagerHook`, subscription controller, VAPID signing — shipped on
2026-02-27, seven months before 0035 was accepted, and `create_notification/1`
has been delivering through it ever since; Phase 2G only moved its key into the
keyring. So the premise that made "do not ship a notifier" look obligatory was
mistaken, and nobody noticed because nothing had a reason to look. The third
ground never applied to this audience either: the people who need to hear it
already have accounts here. Only the first, no email, still holds — and it is
irrelevant to admins of the instance itself.

So the gap was not really "we have no way to tell anyone". It was that the
only thing standing between a silently dead backup and a person was a piece of
infrastructure the operator had not built — and the failure it guards against
is precisely the one you do not notice until you need the backup.

## Decision

**1. A periodic check raises the alert, not the backup.** It runs hourly from
`SessionCleaner` and reads `Health.report/1`. This is the load-bearing part:
an alert raised *by the backup* can only report a run that failed, never a run
that never happened — a masked timer, a disabled unit, a host that was down at
the scheduled hour. Those are the silent cases, and only something that
measures the age of what is on disk can see them.

**2. It watches every check, not only the backup.** The item that opened this
asked for backups. Narrowing a report of seven checks to one of them would be
an arbitrary line: a full disk, a dead worker or an encryption key this
instance no longer has are each as urgent and were each as silent. The alert
names which checks are failing.

**3. Admins, in-app, and by Web Push for those who subscribed.** No new
channel, no new credential, no third party beyond the push endpoint every
other notification already uses, and nothing to configure — it works on a
fresh install.
Moderators are not told: a moderator cannot fix a full disk, and an alert sent
to people who cannot act on it is how alerts get ignored. This keeps P2-D2
(no error reporting service) and D3 (no email) intact.

**4. Always delivered.** `health_alert` and `health_recovered` join the
account-security and moderation notices in bypassing per-type preferences. The
person who would switch these off is exactly the person who has to act on
them.

**5. Quiet enough to stay believable.** A failing set must survive two
consecutive polls before anything is sent; the same set is then repeated once
a day, not hourly; recovery is announced once, and only if a failure was
announced first. An alert that fires every hour is one an operator learns to
ignore, which a week later is the same as no alert at all.

**6. The notification carries check names; the reasons stay in the report.**
Names translate cleanly and mean the same thing in every locale. The reasons
are English strings written for an operator reading `curl`, and the report
remains the authoritative place to read them — it is also the only place that
can say *how* stale, *how* full. The reasons do go to the log, where
0035's rule that they carry no content, account names or exception text is
what makes that safe.

**7. The state that must not be lost is in the notification rows.** Whether
something has already been said is answered by querying them — nothing else is
stored, and it survives a restart, so a deploy does not re-announce a week-old
problem. The consecutive-poll counter is the one piece held in memory, chosen
that way because losing it delays an alert by an hour, while losing the other
half would repeat one.

## Alternatives considered

- **A notifier hooked into the backup task.** The obvious design, and it
  cannot see the failure that matters (decision 1).
- **Shipping the host-side monitor in Ansible** — a timer polling the loopback
  report with an `OnFailure=` unit. It survives the application being down,
  which this does not, but it does nothing until the operator supplies a
  notifier command, and "no email, no third party" is exactly why they have
  none. It stays documented in `doc/sysop.md` as the complement to this, not
  the replacement for it.
- **Email, a webhook, or a push service of our own.** Declined by D3 and
  P2-D2, and all three need a credential stored on the host.
- **A settings row or a new table for the alert state.** The notification rows
  already are that record, and a second copy of it would be a thing that can
  disagree with what was actually sent.
- **Alerting on the first failing poll.** Simpler, and it makes the two queue
  checks — the only ones that can flap within an hour — into a source of
  notifications nobody reads.
- **Telling all staff rather than admins** (decision 3).

## Consequences

- An instance that is **down** still notifies nobody: this runs inside the
  application it reports on, and the `database` check cannot both fail and be
  written to. This closes "backups stopped and nobody noticed", not "the
  server is gone". `doc/sysop.md` keeps documenting an external monitor for
  that, and it is now the only thing that half needs.
- The alert is at most an hour late by design, plus up to another hour for the
  debounce. For a 26-hour backup threshold and a 90-day retention window that
  is immaterial; it would not be for a check that needed minutes.
- A new health check joins the alert automatically, with no wiring — but it
  needs a label in `BaudrateWeb.Helpers.translate_health_check/1` in all three
  locales, or admins read a bare identifier.
- `SessionCleaner` now carries state. It is one map, and the step is called
  outside the uniform step list with its own isolation, because it is the only
  step that remembers anything.
- Off-host pull failures on the operator's workstation are still outside all
  of this; `doc/sysop.md` shows the user-level systemd timer and `OnFailure=`
  for them.

## Acceptance gate

`test/baudrate/health/alerts_test.exs` — both halves, deliberately: that a
failing check reaches every admin and nobody else, and that a working instance,
a flapping one, a repeat and a restart each stay quiet.
