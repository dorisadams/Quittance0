#!/usr/bin/env bash
#
# bump-stellar-sdk.sh
#
# Reproducible 5-step sequence to consume a future @stellar/stellar-sdk
# release that contains the stream-overload fix (closes followup #4
# from Quittance0 commit fec5f0a):
#
#   1. Apply .session-notes/stream-payments-drop-cast.diff to
#      frontend/lib/stellar.ts (drops the `as unknown as OperationRecord`
#      cast; native discriminator narrowing on `record.type === 'payment'`).
#   2. Bump `@stellar/stellar-sdk` from `^12.1.0` to the new version in
#      both frontend/package.json and backend/package.json (idempotent).
#   3. Run package-manager install + frontend tsc --noEmit + vitest run.
#      Skipped when `--no-test` is passed.
#   4. Apply the two pre-staged item-replacement patches
#      `.session-notes/commit-msg-*-item{3,4}-resolved.diff` (sed-substitute
#      `<VERSION>` first, then `git apply`) to swap "open SDK followup"
#      wording in the commit-msg planning files for "Resolved: SDK released
#      <VERSION>" wording. Always runs (independent of `--no-test`).
#   5. Run `.session-notes/audit-deferred-status.sh --json` and verify that
#      each target file derived from Step 4's `PATCHES` array (basename of
#      `+++ b/...` header line in each patch) transitioned to `status=closed`.
#      Always runs; ignored under `--dry-run`. Closes the deferred-status
#      loop: Step 4's wording patches should resolve the open followups that
#      Step 5's audit then validates. Audit exit codes 0 (clean) / 1 (stale
#      with `--fail-on-stale`) / 4 (missing_evidence) are absorbed as
#      informational (release-driven commit doesn't block on unrelated
#      doc-surface warnings); audit exit codes 2 (invalid args) / 3 (repo not
#      found) / 5 (self-test failure) propagate as hard failures (exit 6)
#      with per-cause error messages surfaced to stderr.
#
# Usage:
#   ./.session-notes/bump-stellar-sdk.sh <new-version> [--dry-run] [--no-test]
#
# Examples:
#   ./bump-stellar-sdk.sh 12.4.0           # real run, applies + bumps + tests + resolve
#   ./bump-stellar-sdk.sh 12.4.0 --dry-run # preview without changes
#   ./bump-stellar-sdk.sh 12.4.0 --no-test # skip Step 3; Steps 1/2/4 still run
#
# Exit codes:
#   0  success
#   1  invalid arguments / version
#   2  git apply --check failed for stream-payments-drop-cast.diff
#   3  package.json bump failed (no match found)
#   4  install / tsc / vitest failed
#   5  git apply failed for a commit-msg item-replacement patch
#   6  audit-deferred-status.sh validation failed: one or more Step-4 target
#      files did not transition to `status=closed`. The same exit code is
#      also used when audit-deferred-status.sh itself returns hard-failure
#      codes 2 (invalid arguments), 3 (repo not found / git unparseable),
#      or 5 (self-test failure); the per-cause message is printed to stderr
#      for diagnostic clarity. Other audit exit codes (0 clean, 1 stale
#      with --fail-on-stale, 4 missing_evidence > 0) are absorbed as
#      informational since the release-driven commit does not block on
#      stale or missing-evidence warnings elsewhere in the doc surface.
#
# Environment overrides:
#   QUITTANCE0_ROOT  (default: directory two levels up from this script)
#   SDK_PKG_NAME     (default: @stellar/stellar-sdk)
#

set -euo pipefail

# ---- Argument parsing ------------------------------------------------------

if [ $# -lt 1 ]; then
  echo "Usage: $0 <new-version> [--dry-run] [--no-test]" >&2
  echo "Example: $0 12.4.0 --dry-run" >&2
  exit 1
fi

NEW_VERSION="$1"
shift

DRY_RUN=0
NO_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-test) NO_TEST=1 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# Validate version (loose semver: major.minor.patch with optional pre-release)
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$ ]]; then
  echo "Invalid version: $NEW_VERSION (expected semver MAJOR.MINOR.PATCH)" >&2
  exit 1
fi

# ---- Paths ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${QUITTANCE0_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DIFF="$ROOT/.session-notes/stream-payments-drop-cast.diff"
SDK_PKG="${SDK_PKG_NAME:-@stellar/stellar-sdk}"

if [ ! -d "$ROOT" ]; then
  echo "Quittance0 root not found: $ROOT" >&2; exit 1
fi
if [ ! -f "$DIFF" ]; then
  echo "Diff not found: $DIFF" >&2; exit 1
fi

echo "==> Bumping $SDK_PKG to $NEW_VERSION in $ROOT (dry-run=$DRY_RUN, no-test=$NO_TEST)"

# ---- Helpers --------------------------------------------------------------

run_or_echo() {
  # Echo the command if dry-run, otherwise execute.
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

bump_package_json() {
  local pkg_path="$1"
  local file="$ROOT/$pkg_path"

  if [ ! -f "$file" ]; then
    echo "    (skip) $pkg_path does not exist" >&2
    return 0
  fi

  # Idempotent: only modify if the current value differs.
  local current
  current=$(grep -oE "\"$SDK_PKG\":\s*\"[^\"]+\"" "$file" | grep -oE '"[^"]+"$' | tr -d '"' || true)

  if [ -z "$current" ]; then
    echo "    (skip) $pkg_path does not pin $SDK_PKG" >&2
    return 0
  fi

  if [ "$current" = "$NEW_VERSION" ]; then
    echo "    (skip) $pkg_path already at $NEW_VERSION"
    return 0
  fi

  echo "    $pkg_path: $current -> $NEW_VERSION"
  if [ "$DRY_RUN" -eq 0 ]; then
    # In-place sed with extended regex. Matches the SDK pin line in either
    # dependencies or devDependencies sections.
    sed -i.bak -E "s/\"$SDK_PKG\":[[:space:]]*\"[^\"]+\"/\"$SDK_PKG\": \"$NEW_VERSION\"/" "$file"
    rm -f "$file.bak"
  fi
}

detect_package_manager() {
  # Walk both frontend/ and backend/; if any subdir has a lockfile, pick
  # the matching manager. Defaults to npm if none found.
  if find "$ROOT" -maxdepth 3 -name 'pnpm-lock.yaml' -print -quit 2>/dev/null | grep -q .; then
    echo pnpm
  elif find "$ROOT" -maxdepth 3 -name 'yarn.lock' -print -quit 2>/dev/null | grep -q .; then
    echo yarn
  else
    echo npm
  fi
}

# ---- Step 1: apply the deferred diff --------------------------------------

echo "==> Step 1: applying $DIFF"

cd "$ROOT"

# Idempotency guard: if the diff is already applied, `git apply --reverse
# --check` succeeds (because the diff's hunks can be cleanly reversed). Skip
# the apply in that case so re-runs with the same version are no-ops.
if [ "$DRY_RUN" -eq 0 ] && git apply --reverse --check "$DIFF" 2>/dev/null; then
  echo "    (skip) diff already applied (reverse --check succeeded)"
else
  run_or_echo git apply --check "$DIFF"
  APPLY_CHECK_EXIT=$?

  if [ "$APPLY_CHECK_EXIT" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "git apply --check failed (exit $APPLY_CHECK_EXIT) — diff does not apply cleanly" >&2
    exit 2
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    run_or_echo git apply "$DIFF"
  fi
fi

# ---- Step 2: bump package.json(s) -----------------------------------------

echo "==> Step 2: bumping $SDK_PKG in package.json files"

bump_package_json "frontend/package.json"
bump_package_json "backend/package.json"

# ---- Step 3: install + validate -------------------------------------------

# Wrapped in if/else (not early-exit) so that Step 4 still runs when
# `--no-test` is passed. Step 4 is documentation cleanup and is independent
# of test execution.
if [ "$NO_TEST" -eq 1 ]; then
  echo "==> Step 3: skipped (--no-test)"
else
  echo "==> Step 3: package-manager install + tsc + vitest"

  PM=$(detect_package_manager)
  echo "    Detected package manager: $PM"

  # Install in both frontend and backend if those dirs exist.
  for sub in frontend backend; do
    if [ -d "$ROOT/$sub" ]; then
      echo "    [install] $sub/ ($PM install)"
      run_or_echo bash -c "cd '$ROOT/$sub' && $PM install"
    fi
  done

  # Validate frontend.
  if [ -d "$ROOT/frontend" ]; then
    echo "    [validate] frontend tsc --noEmit"
    run_or_echo bash -c "cd '$ROOT/frontend' && npx tsc --noEmit"
    echo "    [validate] frontend vitest run"
    run_or_echo bash -c "cd '$ROOT/frontend' && npx vitest run"
  fi

  # Validate backend (if it has tests).
  if [ -d "$ROOT/backend" ] && [ -f "$ROOT/backend/vitest.config.ts" ]; then
    echo "    [validate] backend vitest run"
    run_or_echo bash -c "cd '$ROOT/backend' && npx vitest run"
  fi
fi

# ---- Step 4: resolve SDK followups in commit-note planning files ----------

# Apply the two pre-staged .diff patches that swap item #4 / item #3 wording
# in `.session-notes/commit-msg-stellar-retypes.txt` and
# `.session-notes/commit-msg-payment-monitor-typed.txt` from "open SDK
# followup" wording to "Resolved: SDK released <VERSION>" wording.
#
# Each patch's `+` lines contain `<VERSION>` as a literal placeholder. We
# pipe `sed` into `git apply` (NOT `sed -i` + `git apply`) so the patch
# files themselves are never mutated — this keeps the patches reusable
# across version bumps (e.g. 12.4.0 → 12.5.0 without restoring the
# originals). Apply order is enforced by the pipe: `sed` runs at pipe-time
# inside the same command, before `git apply` consumes stdin.
#
# Cross-version idempotency: detect "already resolved" by grepping the
# target .txt file for the resolved-state marker. This is faster than
# running a full reverse-apply check AND it works regardless of which
# version was previously applied (a re-run for, say, 12.5.0 after 12.4.0
# finds the marker and skips; it does not depend on version-string match).

echo "==> Step 4: resolve SDK followups in commit-note planning files"

# Marker is `Resolved` (not `Resolved: SDK released`) because the on-disk
# patched text uses markdown bold: `**Resolved**: SDK released` — the `**`
# between `Resolved` and `:` breaks the broader substring as a contiguous
# match. `Resolved` alone is unambiguous: present in both patches' resolved-
# state wording and absent from the original (open-state) wording in the
# corresponding .txt planning files.
RESOLVED_MARKER="Resolved"
PATCHES=(
  "commit-msg-stellar-retypes-item4-resolved.diff"
  "commit-msg-payment-monitor-typed-item3-resolved.diff"
)

for PATCH_NAME in "${PATCHES[@]}"; do
  PATCH_FILE="$ROOT/.session-notes/$PATCH_NAME"

  if [ ! -f "$PATCH_FILE" ]; then
    echo "    (warning) $PATCH_NAME not found in .session-notes/ — skipping"
    continue
  fi

  # Identify the target .txt file by parsing the `+++ b/...` line of the
  # patch header (avoids hard-coding relative paths here).
  TARGET_REL=$(grep -oE '\+\+\+ b/[^ ]+' "$PATCH_FILE" | sed 's|+++ b/||')
  TARGET_FILE="$ROOT/$TARGET_REL"

  if [ ! -f "$TARGET_FILE" ]; then
    echo "    (warning) target file $TARGET_REL not found — skipping"
    continue
  fi

  # Cross-version idempotency: if the resolved-state marker is already in
  # the target file, this patch's wording has already landed (regardless
  # of which version string wrote it). Skip — re-runs are no-ops once
  # resolved, even across different versions.
  if grep -q "$RESOLVED_MARKER" "$TARGET_FILE"; then
    echo "    (skip) $TARGET_REL already resolved"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [dry-run] sed 's|<VERSION>|$NEW_VERSION|g' $PATCH_NAME | git apply"
    echo "    [dry-run]   ↳ would write resolved-state to $TARGET_REL"
  else
    if ! sed "s|<VERSION>|$NEW_VERSION|g" "$PATCH_FILE" | git apply --check; then
      echo "git apply --check failed for $PATCH_NAME — patch does not apply cleanly to $TARGET_REL" >&2
      exit 5
    fi
    sed "s|<VERSION>|$NEW_VERSION|g" "$PATCH_FILE" | git apply
    echo "    applied $PATCH_NAME → $TARGET_REL"
  fi
done

# ---- Step 5: post-validate deferred status loop closing ------------------

# Run the audit script and verify that Step 4's wording patches
# successfully transitioned each target commit-msg planning file from
# "pending" (open followup) to "closed" (resolved). Target list is
# derived from Step 4's `PATCHES` array (basename of each patch's
# `+++ b/...` header line) — single source of truth, so future edits to
# PATCHES flow through automatically.
#
# Audit exit-code mapping (Step 5 overrides the audit script's default
# policy for this release-driven commit):
#   0 (clean)            — proceed
#   1 (stale + --fail-on-stale) — proceed (default off; informational)
#   4 (missing_evidence) — proceed (informational; release commit doesn't
#                          block on doc-surface missing-evidence warnings)
#   2 (invalid args)     — hard fail (exit 6); env is broken
#   3 (repo not found)   — hard fail (exit 6)
#   5 (self-test fail)   — hard fail (exit 6); audit script is broken
#   * (anything else)    — hard fail (exit 6); unexpected
#
# `--dry-run`: skip the assertion entirely (audit would see pre-Step-4
# state and produce false failures). Announce the dry-run skip.

echo "==> Step 5: post-validate deferred status loop closing"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "    [dry-run] skipped Step 4 + Step 5 verification (files unchanged on disk)"
else
  # Capture both stdout and exit status without tripping `set -e`. We
  # map the audit-script exit code explicitly below.
  set +e
  AUDIT_JSON=$("$ROOT/.session-notes/audit-deferred-status.sh" --json)
  AUDIT_RC=$?
  set -e

  case "$AUDIT_RC" in
    0|1|4) ;;  # proceed — informational per Step 5 spec
    2)
      echo "    audit-deferred-status.sh returned exit 2 (invalid arguments)" >&2
      exit 6
      ;;
    3)
      echo "    audit-deferred-status.sh returned exit 3 (repo not found / git unparseable)" >&2
      exit 6
      ;;
    5)
      echo "    audit-deferred-status.sh returned exit 5 (self-test failure)" >&2
      exit 6
      ;;
    *)
      echo "    audit-deferred-status.sh returned unexpected exit $AUDIT_RC" >&2
      exit 6
      ;;
  esac

  # Derive target-file list from Step 4's `PATCHES` array (single source
  # of truth). Each patch names its target via `+++ b/<path>`; basename
  # gives the filename that audit-deferred-status.sh reports in its
  # JSON output's `files[].path` field (also reduced via split('/')[-1]).
  TARGETS=()
  for patch_name in "${PATCHES[@]}"; do
    patch_file="$ROOT/.session-notes/$patch_name"
    if [ -f "$patch_file" ]; then
      target_rel=$(grep -oE '\+\+\+ b/[^ ]+' "$patch_file" | sed 's|+++ b/||')
      if [ -n "$target_rel" ]; then
        TARGETS+=("$(basename "$target_rel")")
      fi
    fi
  done

  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "    [skip] no targets derived from PATCHES — nothing to verify" >&2
    exit 6
  fi

  # Pass targets to python via env var (comma-separated). Avoids quote
  # hazards that would arise from interpolating shell vars into the
  # python source code.
  TARGETS_LIST=$(IFS=,; echo "${TARGETS[*]}")

  if ! printf '%s' "$AUDIT_JSON" | TARGETS="$TARGETS_LIST" python3 -c "
import json, os, sys
data = json.load(sys.stdin)
files = {f['path'].split('/')[-1]: f for f in data['files']}
targets = os.environ['TARGETS'].split(',')
ok = True
for t in targets:
    s = files.get(t, {}).get('status', 'missing')
    if s == 'closed':
        print(f'    [verify] {t} -> closed')
    else:
        print(f'    [error] {t} status: {s!r} (expected closed)', file=sys.stderr)
        ok = False
sys.exit(0 if ok else 1)
"; then
    echo "    audit validation failed: target files did not transition to status=closed" >&2
    exit 6
  fi

  # Per-target verification succeeded — surface the totals for visibility.
  printf '%s' "$AUDIT_JSON" | python3 -c "
import json, sys
t = json.load(sys.stdin)['totals']
print(f\"    summary: closed={t['closed']} pending={t['pending']} ambiguous={t['ambiguous']}\")
"
fi

echo "==> Done."
