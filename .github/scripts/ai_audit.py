#!/usr/bin/env python3
"""Send a release's source diff to an LLM and write a structured audit report.

Used by .github/workflows/ai-audit.yml, which only invokes this on
release-please's own release PRs. Supports two providers - whichever repo
secret is configured wins (Anthropic checked first):

    ANTHROPIC_API_KEY   -> Claude (default model: claude-sonnet-4-5)
    OPENAI_API_KEY      -> GPT    (default model: gpt-4o)

Either default can be overridden without touching this file via the
AI_AUDIT_MODEL repo/environment variable (Settings -> Secrets and
variables -> Actions -> Variables) - useful once a newer model than the
ones hardcoded here is available.

Deliberately stdlib-only (urllib), so the workflow doesn't need an extra
pip install step just for this.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_MODELS = {
    "anthropic": "claude-sonnet-4-5",
    "openai": "gpt-4o",
}

# Kept deliberately short and structured: this becomes part of a public
# changelog/release note, not an internal review thread, so it needs to be
# skimmable and it needs a predictable heading shape for insert_audit.py to
# find and replace on the next run.
PROMPT_TEMPLATE = """You are reviewing a source diff for VanillaPlusMegapack, an open-source \
Helldivers 2 cosmetic/quality-of-life mod pack (Lua/LuaJIT, with Python build tooling). \
The mods legitimately read and write specific, documented locations in the game's own \
process via Windows FFI (ReadProcessMemory/WriteProcessMemory, GetAsyncKeyState, SendInput, \
etc.) to implement things like remembered settings, hotkeys and UI tweaks - that is this \
project's normal, declared mechanism, not a red flag by itself. Judge the diff against that \
stated purpose, not against the mere presence of those APIs.

Produce a concise Markdown report, and output ONLY the report (no preamble, no meta-commentary \
about being an AI), starting exactly with the heading below and using exactly these three \
subheadings in this order:

## AI Audit
### Security / malware-pattern review
One short paragraph or bullet list. Flag anything that looks like it exceeds the mod's stated \
purpose: unexpected network calls, obfuscated/encoded strings, process or DLL injection into \
processes other than the game, keylogging or input capture unrelated to declared hotkey \
handling, filesystem access outside expected paths, self-modifying or eval'd code, or data \
exfiltration patterns. If a change plausibly leaks a path, username, email or credential, say \
so specifically (scripts/privacy_audit.py also checks for this mechanically; you're a second, \
context-aware pass). If nothing suspicious, say so plainly in one line - don't pad the section.

### Code quality
Real, specific issues only: correctness risks, missing error handling, likely performance \
regressions. Skip pure style nitpicks (lint already covers those). If nothing notable, say so \
in one line.

### Improvement suggestions
A short, prioritized bullet list (3 items max). Skip this section entirely (omit the heading \
too) if the diff is too small/mechanical to suggest anything meaningful.

Keep the whole report under roughly 400 words. Be specific and cite file names from the diff; \
don't speculate about intent you can't see in the diff. This is informational for maintainers \
and contributors, not a substitute for human review, and should say so is not necessary - the \
surrounding changelog context already makes that clear.

Diff to review:
```diff
{diff}
```
"""


def call_anthropic(diff, model, api_key):
    body = json.dumps({
        "model": model,
        "max_tokens": 1536,
        "messages": [{"role": "user", "content": PROMPT_TEMPLATE.format(diff=diff)}],
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        result = json.load(resp)
    return "".join(block.get("text", "") for block in result.get("content", []))


def call_openai(diff, model, api_key):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": PROMPT_TEMPLATE.format(diff=diff)}],
        "max_tokens": 1536,
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        result = json.load(resp)
    return result["choices"][0]["message"]["content"]


DRY_RUN_REPORT = """## AI Audit
### Security / malware-pattern review
Dry run - no diff was actually sent to a model. Nothing to report.

### Code quality
Dry run - no diff was actually sent to a model. Nothing to report.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=["anthropic", "openai"])
    parser.add_argument("--diff", required=True, help="Path to a text file containing the diff")
    parser.add_argument("--out", required=True, help="Where to write the resulting markdown")
    parser.add_argument("--model", default=None, help="Overrides AI_AUDIT_MODEL/the built-in default")
    parser.add_argument("--dry-run", action="store_true",
                         help="Skip the API call; write a placeholder report (for testing the "
                              "changelog/PR-insertion plumbing without spending API credits)")
    args = parser.parse_args()

    if args.dry_run:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(DRY_RUN_REPORT)
        print("dry run: wrote placeholder report")
        return 0

    diff_text = open(args.diff, "r", encoding="utf-8", errors="replace").read().strip()
    if not diff_text:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write("## AI Audit\nNo reviewable source changes in this release (diff was empty).\n")
        print("empty diff: skipped the API call")
        return 0

    model = args.model or os.environ.get("AI_AUDIT_MODEL") or DEFAULT_MODELS[args.provider]
    api_key = os.environ.get("ANTHROPIC_API_KEY" if args.provider == "anthropic" else "OPENAI_API_KEY")
    if not api_key:
        sys.exit(f"No API key found for provider '{args.provider}'")

    try:
        if args.provider == "anthropic":
            text = call_anthropic(diff_text, model, api_key)
        else:
            text = call_openai(diff_text, model, api_key)
    except urllib.error.HTTPError as e:
        # Don't fail the whole release over the audit - write a visible note
        # instead so the release PR still merges cleanly, and log the real
        # error for the workflow run's own logs.
        detail = e.read().decode(errors="replace")[:500]
        print(f"AI audit call failed ({e.code}): {detail}", file=sys.stderr)
        text = (f"## AI Audit\nAudit skipped - the {args.provider} API call failed "
                f"({e.code}). See the workflow run logs for details.\n")

    if not text.lstrip().startswith("## AI Audit"):
        text = "## AI Audit\n" + text.lstrip()

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text.strip() + "\n")
    print(f"wrote audit report ({len(text)} chars) using {args.provider}:{model}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
