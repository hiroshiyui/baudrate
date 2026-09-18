#!/usr/bin/env python3
"""Validate BAUDRATE_AUTH_KEYS / BAUDRATE_SIGNING_KEYS without disclosing them.

Reads a SOPS-decrypted inventory on stdin and reports only *derived* facts:
the key ids (already public — they are stored in the clear in every BK1
ciphertext blob), the decoded byte length, and a truncated SHA-256
fingerprint. There is deliberately no code path that prints a key, a base64
blob, or an input line: every print statement below emits an id, an integer,
a fingerprint or a fixed string. `--selftest` checks that property against
synthetic keys, because a regression in it is a key disclosure.

Do not inspect the decrypted inventory with `grep`, `cat` or `head` instead:
those print whole lines, and a line holds the key. That is how this
instance's keys were once disclosed.

Python rather than shell to match `pull-backups.sh`'s neighbourhood without
its quoting hazards; python3 is already required on any machine that runs the
Ansible deploy.

Usage:
    cd ansible && sops --decrypt inventory/group_vars/all.sops.yml \\
      | ../scripts/check-keyring.py
    scripts/check-keyring.py --selftest
"""

import base64
import hashlib
import re
import sys

CLASSES = ("auth_keys", "signing_keys")
ID_FORMAT = re.compile(r"^[A-Za-z0-9_-]{1,16}$")
RESERVED_ID = "legacy"


def entries(value):
    for item in value.split(","):
        item = item.strip()
        if item:
            yield item.split(":", 1) if ":" in item else [item, ""]


def fingerprint(raw):
    return hashlib.sha256(raw).hexdigest()[:8]


def check(name, value):
    print(f"{name}:")
    seen, ok = [], True

    for position, (key_id, b64) in enumerate(entries(value)):
        problems = []

        if not ID_FORMAT.match(key_id):
            problems.append("id fails [A-Za-z0-9_-]{1,16}")
        if key_id == RESERVED_ID:
            problems.append("id is reserved for the SECRET_KEY_BASE fallback")
        if key_id in seen:
            problems.append("duplicate id")
        seen.append(key_id)

        try:
            raw = base64.b64decode(b64, validate=True)
        except Exception:
            print(f"  [{position}] id={key_id}  FAIL: not valid base64")
            ok = False
            continue

        if len(raw) != 32:
            problems.append(f"decodes to {len(raw)} bytes, want 32")

        role = "current" if position == 0 else "retained for reading"
        verdict = "; ".join(problems) if problems else "ok"
        if problems:
            ok = False

        print(
            f"  [{position}] id={key_id:<16} {len(raw):>2} bytes  "
            f"fp={fingerprint(raw)}  ({role})  {verdict}"
        )

    if not seen:
        print("  no entries — this class falls back to SECRET_KEY_BASE")
        ok = False

    return ok


def selftest():
    """Assert that no secret reaches stdout, and that bad input is rejected."""
    import io
    import os
    import contextlib

    secrets = [base64.b64encode(os.urandom(32)).decode() for _ in range(3)]
    inventory = (
        f"postgres_db_password: irrelevant\n"
        f"auth_keys: \"202703:{secrets[0]},202609:{secrets[1]}\"\n"
        f"signing_keys: '202703:{secrets[2]}'\n"
    )

    captured = io.StringIO()
    with contextlib.redirect_stdout(captured):
        sys.stdin = io.StringIO(inventory)
        good = main() == 0
    out = captured.getvalue()

    failures = []
    for secret in secrets:
        if secret in out or secret.rstrip("=") in out:
            failures.append("a key value reached stdout")
        raw = base64.b64decode(secret)
        if raw.hex() in out or hashlib.sha256(raw).hexdigest() in out:
            failures.append("raw or full-hash key material reached stdout")
    if not good:
        failures.append("valid input was reported as a problem")
    for expected in ("id=202703", "id=202609", "32 bytes", "all checks passed"):
        if expected not in out:
            failures.append(f"expected {expected!r} in output")

    for name, bad in (
        ("reserved id", 'auth_keys: "legacy:{k}"\nsigning_keys: "a:{k}"\n'),
        ("short key", 'auth_keys: "a:AAAA"\nsigning_keys: "b:{k}"\n'),
        ("duplicate id", 'auth_keys: "a:{k},a:{k}"\nsigning_keys: "b:{k}"\n'),
        ("absent class", 'auth_keys: "a:{k}"\n'),
    ):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            sys.stdin = io.StringIO(bad.format(k=secrets[0]))
            if main() == 0:
                failures.append(f"{name} was not rejected")

    for failure in dict.fromkeys(failures):
        print("SELFTEST FAIL:", failure)
    if not failures:
        print("SELFTEST PASS: no key material reaches stdout; bad input rejected")
    return 1 if failures else 0


def main():
    found = {}
    for line in sys.stdin:
        for name in CLASSES:
            if line.startswith(name + ":"):
                found[name] = line.split(":", 1)[1].strip().strip("\"'")

    all_ok = True
    for name in CLASSES:
        if name in found:
            all_ok &= check(name, found[name])
        else:
            print(f"{name}:\n  ABSENT — class falls back to SECRET_KEY_BASE")
            all_ok = False
        print()

    print("RESULT:", "all checks passed" if all_ok else "problems found (above)")
    return 0 if all_ok else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(main())
