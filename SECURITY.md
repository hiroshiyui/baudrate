# Security Policy

Baudrate is a public-facing forum that federates with other servers, and
information security is its top priority. Thank you for helping keep it and
the people who use it safe.

## Reporting a vulnerability

**Please do not open a public issue, pull request or discussion for a
security problem.** Report it privately by email:

**hiroshi@ghostsinthelab.org**

If the report is sensitive, encrypt it with this OpenPGP key:

- Key: [`doc/security-contact.asc`](doc/security-contact.asc)
- Fingerprint: `37A4 5B21 B45E A42E BE6C  E74C 9F35 3471 AF05 D276`
- Valid until 2027-05-25; this file is updated when the key is extended or
  replaced.

Check the fingerprint through a second channel (for example a keyserver or
the maintainer's other profiles) rather than trusting this file alone.

### What to include

- The version (the `software.version` in `/nodeinfo/2.1`) or the commit.
- What an attacker can do, and what they need first: a guest, a member, a
  moderator, an admin, or a remote server.
- Steps to reproduce, or a proof of concept. Please use your own instance
  or a local development setup, never someone else's server.
- Any logs, requests or payloads that show it.

### What happens next

- You get an acknowledgement within **7 days**.
- The maintainer confirms the problem, works out its impact and prepares a
  fix, keeping you informed along the way.
- The fix ships in a release whose `CHANGELOG.md` entry lists it under
  **Security**. You are credited there unless you would rather not be.
- Please keep the details private until that release is out, or for 90 days
  from your report, whichever comes first. If a fix needs longer, we will
  say why and agree a date with you.

## Supported versions

Only the **latest release** receives security fixes. Operators should keep
their instance on it; `doc/sysop.md` describes the upgrade and rollback path.

## Scope

In scope:

- this repository's application code, including the Rust NIF crates in
  `native/`;
- the ActivityPub endpoints and how the instance handles what other servers
  send it;
- the Ansible playbooks and CI configuration in this repository.

Out of scope:

- vulnerabilities in a particular operator's hosting or configuration (report
  those to the operator);
- denial of service by sheer volume, and findings that need a compromised
  admin account or physical access to the server;
- reports from automated scanners with no demonstrated impact.

The invariants the project defends, and the record of why, are indexed in
[`doc/baudrate-spec.md`](doc/baudrate-spec.md). A report that shows one of
them does not hold is especially welcome.
