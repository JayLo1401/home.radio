#!/usr/bin/env python3
"""Works out the next release from the commits since the last one.

Called by .github/workflows/release.yml. Env:
  BASE_VERSION  version of the last release (tag without "v"), or empty
  BASE_REF      its tag, or empty (then all commits count)
  NOTES_PATH    where to write the release notes (Markdown)

Bump (Conventional Commits, subject line only):
  "type!:" or "BREAKING CHANGE"  -> major
  "feat:"                        -> minor
  anything else                  -> patch
"[major]" / "[minor]" in a subject forces that bump.

Prints only the new version on stdout (it's captured with $(...)); all
diagnostics go to stderr.
"""
import os
import re
import subprocess
import sys

SUBJECT = re.compile(r"^(?P<type>[A-Za-z]+)(?:\([^)]*\))?(?P<bang>!)?:\s*(?P<text>.+)$")
SECTIONS = [("feat", "Neu"), ("fix", "Behoben")]


def log(msg):
    print(msg, file=sys.stderr)


def commits(base_ref):
    rng = f"{base_ref}..HEAD" if base_ref else "HEAD"
    out = subprocess.run(
        ["git", "log", rng, "--no-merges", "--format=%s"], check=True, capture_output=True, text=True
    ).stdout
    # The workflow's own version commits don't count.
    return [s for s in out.splitlines() if s.strip() and "[skip ci]" not in s]


def main():
    base_version = os.environ.get("BASE_VERSION") or "0.0.0"
    base_ref = os.environ.get("BASE_REF") or ""
    notes_path = os.environ["NOTES_PATH"]

    subjects = commits(base_ref)
    log(f"{len(subjects)} commits since {base_ref or 'the beginning'}")

    major, minor, patch = (int(x) for x in base_version.split("."))
    bump = "patch"
    for s in subjects:
        m = SUBJECT.match(s)
        if "[major]" in s or (m and m.group("bang")) or "BREAKING CHANGE" in s:
            bump = "major"
            break
        if "[minor]" in s or (m and m.group("type").lower() == "feat"):
            bump = "minor"
    if bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif bump == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    version = f"{major}.{minor}.{patch}"
    log(f"bump {bump}: {base_version} -> {version}")

    grouped = {key: [] for key, _ in SECTIONS}
    other = []
    for s in subjects:
        m = SUBJECT.match(s)
        text = (m.group("text") if m else s).replace("[major]", "").replace("[minor]", "").strip()
        key = m.group("type").lower() if m else ""
        (grouped[key] if key in grouped else other).append(text)
    lines = []
    for key, title in SECTIONS:
        if grouped[key]:
            lines += [f"### {title}", *[f"- {t}" for t in grouped[key]], ""]
    if other:
        lines += ["### Sonstiges", *[f"- {t}" for t in other], ""]
    with open(notes_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) or "Keine Änderungen.\n")

    print(version)


if __name__ == "__main__":
    main()
