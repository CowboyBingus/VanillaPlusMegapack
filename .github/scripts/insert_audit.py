#!/usr/bin/env python3
"""Upsert the AI audit report into CHANGELOG.md's newest version block and
into the release PR's description.

Idempotent by design: release-please rewrites both the PR body and (on the
branch) CHANGELOG.md every time it re-runs on a new push, so this script
runs again after every such update (see ai-audit.yml) and needs to replace
its own previous insertion rather than pile up duplicates. Marker comments
(HTML in the changelog, hidden in the PR body too) delimit the managed
block in both places.

stdlib-only (urllib for the GitHub API) so the workflow needs no extra
pip install.
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request

START = "<!-- ai-audit:start -->"
END = "<!-- ai-audit:end -->"
VERSION_HEADING = re.compile(r"^## \[", re.MULTILINE)


def upsert_block(text, audit_md):
    """Replace any existing START..END span in `text` with a fresh one built
    from `audit_md`, or return None if there's nowhere sensible to put it."""
    managed = f"{START}\n{audit_md.strip()}\n{END}"
    if START in text and END in text:
        pattern = re.compile(re.escape(START) + r".*?" + re.escape(END), re.DOTALL)
        return pattern.sub(managed, text, count=1)
    return managed  # caller decides where to place a first-time insertion


def update_changelog(path, audit_md):
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        print(f"{path} not found; skipping changelog insertion", file=sys.stderr)
        return False

    if START in content and END in content:
        new_content = upsert_block(content, audit_md)
        if new_content == content:
            return False
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)
        return True

    match = VERSION_HEADING.search(content)
    if not match:
        print(f"No '## [' version heading found in {path}; skipping changelog insertion",
              file=sys.stderr)
        return False
    next_match = VERSION_HEADING.search(content, match.end())
    insert_at = next_match.start() if next_match else len(content)
    block = f"\n{START}\n{audit_md.strip()}\n{END}\n\n"
    new_content = content[:insert_at] + block + content[insert_at:]
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)
    return True


def gh_api(method, url, token, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def update_pr_body(repo, pr_number, token, audit_md):
    url = f"https://api.github.com/repos/{repo}/pulls/{pr_number}"
    current = gh_api("GET", url, token)
    body = current.get("body") or ""
    new_body = upsert_block(body, audit_md)
    if new_body == body:
        print("PR body already up to date")
        return
    try:
        gh_api("PATCH", url, token, {"body": new_body})
        print("PR body updated")
    except urllib.error.HTTPError as e:
        # Non-fatal: the CHANGELOG.md copy (committed to the branch, part of
        # the PR diff either way) is the durable record even if this call
        # fails for some reason.
        print(f"Could not update PR body ({e.code}): {e.read().decode(errors='replace')[:300]}",
              file=sys.stderr)


def git(*args):
    subprocess.run(["git", *args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit", required=True, help="Path to the audit markdown file")
    parser.add_argument("--repo", required=True, help="owner/repo")
    parser.add_argument("--pr", required=True, type=int)
    parser.add_argument("--token", required=True)
    parser.add_argument("--changelog", default="CHANGELOG.md")
    parser.add_argument("--no-commit", action="store_true",
                         help="Update files locally but don't git commit/push (for local testing)")
    args = parser.parse_args()

    audit_md = open(args.audit, "r", encoding="utf-8").read()

    changed = update_changelog(args.changelog, audit_md)
    if changed and not args.no_commit:
        git("config", "user.name", "github-actions[bot]")
        git("config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
        git("add", args.changelog)
        result = subprocess.run(["git", "diff", "--cached", "--quiet"])
        if result.returncode != 0:  # there is something staged to commit
            git("commit", "-m", "chore: add AI audit to changelog [skip ci]")
            git("push")
            print(f"committed AI audit into {args.changelog}")
        else:
            print("changelog content unchanged after formatting; nothing to commit")
    elif not changed:
        print(f"{args.changelog} unchanged")

    update_pr_body(args.repo, args.pr, args.token, audit_md)


if __name__ == "__main__":
    main()
