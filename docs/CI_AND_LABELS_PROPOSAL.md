# CI & label proposal

Opened as a PR rather than pushed directly, since this is a fork proposing
changes, not a request for write access. Everything here is additive and
disabled-by-default where it could affect existing workflow (nothing merges
or is force-pushed anywhere; releases are drafts, not publishes).

## Where this comes from

The [public roadmap board](https://cowboybingus.notion.site/3df0699880f780049525f3b93acfe213)
tracks every mod (including the ones bundled here) through six stages:
Exploring -> Planned -> In progress -> On hold -> Completed -> Discontinued.
The label set below mirrors that so issues/PRs here can carry the same
status the board already uses, plus a small area breakdown so the ~20
bundled components stay filterable without one label per component.

## Labels (`.github/labels.yml`)

- `status: exploring / planned / in progress / on hold / completed / discontinued`
  - same six stages and colors as the roadmap board
- `area: vehicles-movement / weapons-stratagems / enemies-ai / ui-menus / lobby-social / build-packaging`
  - grouped from `components/` so the label list stays short; happy to
    regroup if a different split makes more sense
- Existing default labels (`bug`, `enhancement`, `documentation`, etc.) are
  untouched.

`.github/workflows/labels-sync.yml` applies `labels.yml` to the repo on every
push to `main` that touches it (via `EndBug/label-sync`, `delete-other-labels:
false` so nothing existing gets removed). It's a normal GitHub Actions
workflow, not something that needs running by hand - once this PR is on
`main`, the labels above appear automatically. A GitHub Projects (v2) board
using `status` as its column field would reproduce the current Kanban view
natively if useful, but creating one is an account-level action outside what
a PR can do, so it's left as a suggestion rather than something in this diff.

## CI - what's actually runnable, and what isn't

This repo's own docs are unusually explicit that most of the test suite
needs things a hosted CI runner fundamentally can't have (a Steam install to
extract `HD2_INPUT_CONFIG`, live game builds). Rather than pretend around
that, the workflows here are split by what's honestly possible:

**`lint.yml` (Ubuntu, every PR, fast, no toolchain setup):**
- `scripts/privacy_audit.py` (no `--git`/`--zip`) - this script already
  exists in the repo and is a genuinely strong check; running it on every PR
  costs nothing and catches leaked paths/emails/credentials before merge.
  The `--git` full-history mode stays a maintainer-run check since it asserts
  every commit is authored by `CowboyBingus`'s noreply address specifically,
  which would fail on any contributor PR by design.
- `ruff` over the Python scripts
- a LuaJIT syntax parse + `luacheck` over every `.lua` file (parsing doesn't
  need Windows/FFI, only *running* the FFI-based tests does)
- JSON validity for the lock/dependency/publication manifests
- `.editorconfig` conformance

**`test-windows.yml` (Windows, every PR):** builds the pinned LuaJIT commit
with `msvcbuild.bat nogc64` (exactly per CONTRIBUTING.md, from the public
LuaJIT repo, cached by commit hash) and runs `ArcThrowerRevamped/check.py` -
its native-binding, work-budget and recovery suites are fully synthetic and
don't touch a live game. This is deliberately scoped to one component for
this PR; the same pattern extends to the other components' `tests/*.lua`
files that take just a source path (most of them), and `BingusSharedLoader`
is public too, so `tests/test_loader.lua` / `test_duplicates.lua` /
`test_package.py` could plausibly run in CI as a follow-up - just didn't want
to bundle a much bigger, harder-to-review change into this PR before this
shape gets a look. The full `scripts/build.py` package build and the
Arsenal/HD2MM manager harnesses need real Steam/manager files and stay
manual, as CONTRIBUTING.md already says.

**`pr-title.yml`:** enforces Conventional Commits on PR titles. Worth noting
the existing commit history is *already* consistently `feat:`/`fix:`/`perf:`/
`docs:`/`build:`/`test:` - this just makes the convention explicit/enforced
rather than changing anything.

## Release automation

Asked to look at `release-plz` for this - it's Cargo/crates.io-specific
(it reads `Cargo.toml` to decide versions and publishes to crates.io), so it
doesn't apply to a Lua/Python repo with no Rust in it. `release-please`
(Google's equivalent, `release-please-config.json` /
`.release-please-manifest.json` here) does the same conceptual job -
conventional-commit-driven changelog drafting and GitHub Release creation -
for arbitrary repos.

Two things worth deciding before this part is turned on for real:

1. **Versioning scheme.** `release-please` is semver-based (`feat` -> minor,
   `fix` -> patch, breaking -> major). This pack currently just increments
   one number per release (v33, v34, v35, tracked in `scripts/build.py`'s
   `VERSION` constant) regardless of what changed. The manifest here starts
   at `35.0.0` as a placeholder; the release PR's version is editable by hand
   before merging either way, so this doesn't have to be resolved before
   trying it out.
2. **Changelog style.** The existing `CHANGELOG.md`/`docs/RELEASE_NOTES.md`
   are hand-written narrative prose (see `docs/TECHNICAL.md` for the level of
   detail). `release-please`'s draft entries are terser bullet points from
   commit subjects. Set to `draft: true` here on purpose: it opens a release
   PR with a scaffold, not a finished changelog, so the existing writing
   style can still be layered on before merging - it saves the bookkeeping
   (bumping the version, opening the tag, publishing the GitHub Release),
   not the writing.

If either tradeoff isn't wanted, both workflows are self-contained and easy
to drop without touching anything else in this PR.

## AI audit on every release PR (optional, off by default)

`.github/workflows/ai-audit.yml` sends the source diff since the last
release tag to Claude or GPT (whichever secret is set) and inserts the
resulting report - a security/malware-pattern review, code-quality notes,
and a short improvement list - into both `CHANGELOG.md` (as a section of
the current version's entry) and the release PR's own description, so it's
part of the permanent release record rather than a one-off comment.

**To enable it:** add one of these under Settings -> Secrets and variables
-> Actions -> Secrets - either works, Anthropic is checked first if both are
set:
- `ANTHROPIC_API_KEY` (Claude)
- `OPENAI_API_KEY` (GPT)

Optionally set the `AI_AUDIT_MODEL` repo/environment *variable* (not
secret) to pin an exact model - see `.github/scripts/ai_audit.py` for the
built-in defaults if you leave it unset. If neither secret is present, the
workflow logs a notice and exits cleanly - nothing else in this PR depends
on it.

It only ever runs against release-please's own PRs (checked via the branch
name), never a contributor's PR, since it calls a paid third-party API with
a source diff.

**Worth knowing before turning it on:**
- The diff is sent to whichever provider's API you configure - i.e. leaves
  this repo. It's already public source, so this is about API-provider
  terms/cost, not confidentiality.
- The prompt explicitly tells the model that this project's Windows-FFI
  memory read/write is a normal, declared mechanism (not a red flag by
  itself) and asks it to judge changes against that stated purpose - see
  the prompt in `ai_audit.py` if you want to adjust the framing.
- It's a second, context-aware pass alongside the existing
  `scripts/privacy_audit.py` (which is pattern-matching, not judgment) -
  not a replacement for either that or human review, and the report says so.
- Cost is bounded per release (diff truncated to 200 KB, ~1500 output
  tokens) but is real API spend on every release, however small.

**Verified on the fork**, same as everything else here - and this one
actually caught a real bug worth calling out: the first version placed the
audit at the very end of `CHANGELOG.md` (after 20+ versions of history)
instead of right after the release being audited, because the boundary
regex only recognized release-please's own `## [x.y.z]` heading style and
this repo's older entries use plain `## v34` / `# v19` headings with no
brackets - so it never found a second match and fell through to end-of-file.
Fixed and re-verified against a real release-please PR/branch on the fork;
the block now lands exactly between the current release's content and the
next version's heading. Also surfaced, separately: `scripts/privacy_audit.py`'s
`--git` mode aside, this is the only workflow in this whole PR that talks to
a service outside GitHub, which is why it's the one gated behind explicit
opt-in secrets rather than ever running by default.

**One-time repo setting needed for release-please:** GitHub blocks Actions
from creating PRs by default. Under Settings -> Actions -> General ->
Workflow permissions, "Allow GitHub Actions to create and approve pull
requests" needs to be checked, or `release-please.yml` will fail at the last
step with `GitHub Actions is not permitted to create or approve pull
requests`. Everything up to that point (branch, commit, tree) still runs
fine either way - this only blocks the final PR. Confirmed this is genuinely
just that toggle by enabling it on the fork and re-running.

## Verified on the fork before opening this PR

Rather than propose untested workflow files, all of the above was pushed to
this fork's own `main` and run for real first. First pass caught three real
issues, now fixed here:
- a hardcoded `vcvars64.bat` path that didn't match the actual `windows-latest`
  image's VS install layout -> switched to `ilammy/msvc-dev-cmd`, which
  resolves this correctly regardless of VS SKU/version
- one genuine unused import (`components/SentryAimRetention/scripts/source_release.py`)
  that `ruff` caught - fixed as part of this PR, not left failing
- `luacheck`'s default strictness surfaced ~150-400 pre-existing style
  warnings (shadowed locals, unused test variables) across the legacy test
  suite; rather than chase every warning code, the workflow now only fails
  on luacheck's actual-error exit codes (2+), so real mistakes still block
  merges without relitigating existing test style
- the release-please workflow needs the repo setting above; confirmed by
  toggling it on the fork and re-running successfully
EOF
wc -l /home/claude/fork/docs/CI_AND_LABELS_PROPOSAL.md
