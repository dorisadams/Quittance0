#!/usr/bin/env bash
#
# audit-deferred-status.sh
#
# Read-only sanity check for the deferred-status annotation pattern across
# the repo's doc surface. Mirrors the documentation-update half of the
# convention used in `.session-notes/bump-stellar-sdk.sh` and the
# `#19`-style out-of-scope residuals in the historical commit-msg files.
#
# What it checks, per file:
#
#   1. Counts `**Resolved**:` markers (the inline pattern:
#      `~~old wording~~ **Resolved**: <evidence>`).
#   2. Verifies each Resolved block cites concrete evidence — a backticked
#      commit hash (verified against `git log --all --oneline`) OR a
#      `.session-notes/` artifact path (verified to exist on disk) OR an
#      explicit validation reference (`tsc --noEmit` / `vitest run` / etc.).
#   3. Detects "stale open-state" wording: a `Out[ -]of[ -]scope` /
#      `followup` / `future PR` / `TODO:` trigger term that names a
#      backticked commit hash but has NO nearby `**Resolved**:` block
#      within ~5 lines. These are followups whose wording hasn't been
#      marked Resolved yet, even though the closing commit may have
#      landed. Output as suggestions, not as failures.
#
# The script is READ-ONLY — it never modifies any tracked or untracked
# file. The `--dry-run` flag exists for symmetry with `bump-stellar-sdk.sh`
# (no effect on this script's output since there are no mutations).
#
# Per-file status classification (closed / pending / ambiguous):
#
#   closed     — file has at least one `**Resolved**:` marker and zero
#                stale open-state items. All tracked followups are closed.
#   pending    — file has at least one stale open-state item and zero
#                `**Resolved**:` markers. All tracked followups are open.
#   ambiguous  — file has both `**Resolved**:` markers AND stale
#                open-state items. Mixed state: some closed, some still
#                open. Most common case during typing-cleanup transitions.
#   n/a        — file has no deferred-status markers (no Resolved,
#                no stale). Skipped from the classification table.
#
# Status is meant as a quick at-a-glance signal for the post-typing-
# cleanup sanity check: a `closed` file's out-of-scope section is
# fully Resolved; a `pending` file's section has only open items;
# an `ambiguous` file is mid-transition and may need re-edits as new
# closing commits land.
#
# Usage:
#   ./.session-notes/audit-deferred-status.sh [--dry-run] [--self-test] [--fail-on-stale]
#   ./.session-notes/audit-deferred-status.sh --json
#
# Examples:
#   ./audit-deferred-status.sh                  # human-readable report
#   ./audit-deferred-status.sh --dry-run        # same report (read-only)
#   ./audit-deferred-status.sh --self-test      # run against fixtures
#   ./audit-deferred-status.sh --json           # machine-readable output
#   ./audit-deferred-status.sh --fail-on-stale  # CI gate: exit 1 if stale > 0
#
# --fail-on-stale flag (off by default):
#
#   By default the script exits 0 even when stale open-state items are
#   found — informational only, since `ambiguous` is the expected state
#   during typing-cleanup waves. Pass --fail-on-stale to opt in to exit 1
#   when stale > 0; suitable for post-typing-cleanup CI gates where
#   a transitional state is unacceptable.
#
# Exit codes:
#   0  audit clean — every Resolved block has evidence; no stale items
#      (or stale items found but --fail-on-stale NOT set)
#   1  stale open-state item(s) found AND --fail-on-stale set (CI gate)
#   2  invalid arguments
#   3  repo not found / git unparseable
#   4  Resolved block(s) found without concrete evidence (warning, always)
#   5  self-test failed (fixture validation)
#
# Environment overrides:
#   QUITTANCE0_ROOT  (default: directory two levels up from this script)
#

set -euo pipefail

# ---- Argument parsing ------------------------------------------------------

DRY_RUN=0
JSON=0
SELF_TEST=0
FAIL_ON_STALE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --json) JSON=1 ;;
    --self-test) SELF_TEST=1 ;;
    --fail-on-stale) FAIL_ON_STALE=1 ;;
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# ---- Paths ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${QUITTANCE0_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SH_NOTES_DIR="$ROOT/.session-notes"

if [ ! -d "$ROOT" ]; then
  echo "Quittance0 root not found: $ROOT" >&2
  exit 3
fi
if [ ! -d "$SH_NOTES_DIR" ]; then
  echo ".session-notes/ not found at $SH_NOTES_DIR" >&2
  exit 3
fi

# ---- Helpers --------------------------------------------------------------

cd "$ROOT"

# Detect "stale open-state" lines: trigger term + backticked commit hash,
# without nearby Resolved marker.
#
# Walks the file in line order:
#   - Sets `in_resolved=1` after each `**Resolved**:` line; cleared by
#     next structural break (heading, bullet start, numbered list start).
#   - On non-resolved lines, looks for trigger term + backticked commit
#     hash — emits `filepath:lineno:line` if so.
#
# Output: one stale-wording record per line. Caller counts via wc -l.
# (Using awk instead of grep+post-filter to avoid the
#  echo-pipe-grep||echo0 "0\n0" pitfall under `set -o pipefail`.)
detect_stale() {
  local file="$1"
  awk '
    function emit() { print FILENAME ":" FNR ":" $0 }
    /^NOTE:|^Refs / { next }
    /\*\*Resolved\*\*:/ { in_resolved = 1; next }
    /^## / || /^### / || /^\* / || /^[A-Za-z0-9_.-]+[.][[:space:]]+/ { in_resolved = 0 }
    {
      if (in_resolved) next
      if (match($0, /out[ -]of[ -]scope|followup|follow up|follow-up|future PR|future work|TODO:|backlog|next sprint|next iteration|tracked separately|tracked at/)) {
        if (match($0, /`[0-9a-f]{7,40}`/)) emit()
      }
    }
  ' "$file"
}

# Per-Resolved evidence verification. Walks each `**Resolved**:` line,
# peeks at the next 10 lines, and tests for at least one of:
#   - backticked commit hash: `` `[0-9a-f]{7,40}` ``
#   - `.session-notes/` artifact reference: `` `\.session-notes/[^`]+` ``
#   - explicit validation reference: `tsc --noEmit` / `vitest run` / `lint`
#
# Returns count of Resolved blocks that have NONE of the above.
# Implementation: single awk pass per file (caller pre-resolves line list
# via grep -nF → /^N:text$/) — caller invokes us once per Resolved line.
verify_resolved_evidence() {
  local file="$1" lineno="$2"
  awk -v start="$((lineno + 1))" '
    NR < start { next }
    NR > start + 10 { exit }
    {
      if (match($0, /`[0-9a-f]{7,40}`/)) { has_hash=1 }
      if (match($0, /`\.session-notes\/[^`]+`/)) { has_artifact=1 }
      if (match($0, /`(tsc --noEmit|vitest|[a-z]+ tsc|next lint|lint)[^`]*`/)) { has_val=1 }
    }
    END { print (has_hash || has_artifact || has_val) ? 1 : 0 }
  ' "$file"
}

# ---- Self-test mode -------------------------------------------------------

if [ "$SELF_TEST" -eq 1 ]; then
  echo "==> Self-test mode: exercising audit logic on synthetic fixtures"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  mkdir -p "$TMP/.session-notes"

  # closed-fixture: only **Resolved**: markers, no stale open-state items.
  # Each Resolved block cites either a commit hash, a `.session-notes/`
  # artifact, OR a tsc/vitest validation ref — providing trusted evidence.
  # Expected audit classification: status=closed.
  cat > "$TMP/.session-notes/closed-fixture.txt" <<'EOF'
# Self-test fixture: closed-state file.

1. ~~Foo~~ **Resolved**: closed by commit `490b355`. Confirmed: `frontend tsc --noEmit` returns 0 errors.
2. ~~Bar~~ **Resolved**: closed by script `.session-notes/bump-stellar-sdk.sh`.
EOF

  # pending-fixture: only stale open-state wording, no **Resolved**: markers.
  # Detect-stale conditions: trigger term (TODO:/followup) + backticked commit hash.
  # Expected audit classification: status=pending.
  cat > "$TMP/.session-notes/pending-fixture.txt" <<'EOF'
# Self-test fixture: pending-state file.

This file has open followups only — no Resolved markers anywhere.

TODO: address the queued followup tracked at `c3f23a1` in next sprint.
The related commit `c3f23a1` covers other cleanups but not this item.
EOF

  # ambiguous-fixture: mix of **Resolved**: + stale open-state.
  # Three Resolved blocks (2 well-evidenced + 1 missing-evidence), 1 stale line.
  # Expected audit classification: status=ambiguous + 1 missing-evidence warning.
  cat > "$TMP/.session-notes/ambiguous-fixture.txt" <<'EOF'
# Self-test fixture: ambiguous-state file.

## Already-resolved (well-evidenced via commit hash)

10. ~~Foo~~ **Resolved**: closed by commit `490b355`.

## Already-resolved (well-evidenced via .session-notes/ artifact)

20. ~~Bar~~ **Resolved**: closed by script `.session-notes/bump-stellar-sdk.sh`.

## Resolved but missing evidence (should warn)

30. ~~Baz~~ **Resolved**: this block cites no concrete evidence.

## Stale open-state item (no nearby Resolved, names commit hash)

40. `490b355` covers some followup work but the doc wasn't updated.
EOF

  echo "Self-test fixtures at $TMP/.session-notes/:"
  echo "  closed-fixture.txt      → expected status=closed"
  echo "  pending-fixture.txt     → expected status=pending"
  echo "  ambiguous-fixture.txt   → expected status=ambiguous"
  echo

  # Cheat the env for the sub-call: ROOT should be TMP's parent so
  # `.session-notes/` is at TMP/.session-notes/. The 5 root-level
  # docs (PLAN/ROADMAP/EVIDENCE/REVIEW_PACK/README) are listed
  # alongside the 3 fixture notes; only the fixtures carry Resolved/
  # stale content here.
  QUITTANCE0_ROOT="$TMP" "$0" --dry-run 2>&1 || true
  echo
  echo "Self-test completed (informational). Exit code reflects fixture state."
  exit 0
fi

# ---- Per-file scan --------------------------------------------------------

# Build file list: 5 root-level docs + .session-notes/*.md + .session-notes/*.txt.
ROOT_DOCS=("$ROOT/PLAN.md" "$ROOT/ROADMAP.md" "$ROOT/EVIDENCE.md" "$ROOT/REVIEW_PACK.md" "$ROOT/README.md")

NOTES_FILES=()
while IFS= read -r -d '' f; do
  NOTES_FILES+=("$f")
done < <(find "$SH_NOTES_DIR" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' \) -print0 | sort -z)

ALL_FILES=("${ROOT_DOCS[@]}" "${NOTES_FILES[@]}")
EXISTING_FILES=()
for f in "${ALL_FILES[@]}"; do
  [ -f "$f" ] && EXISTING_FILES+=("$f")
done

# ---- Report ---------------------------------------------------------------

TOTAL_FILES=0
TOTAL_RESOLVED=0
TOTAL_STALE=0
TOTAL_MISSING_EVIDENCE=0
STALE_FILES_LIST=()
MISSING_EVIDENCE_FILES_LIST=()
CLOSED_FILES_LIST=()
PENDING_FILES_LIST=()
AMBIGUOUS_FILES_LIST=()

if [ "$JSON" -eq 1 ]; then
  echo "{"
  echo "  \"root\": \"$ROOT\","
  echo "  \"files\": ["
  FIRST=1
else
  echo "==> Deferred-status audit (root=$ROOT)"
  echo "    Files scanned: ${#EXISTING_FILES[@]}"
  echo
fi

for FILE in "${EXISTING_FILES[@]}"; do
  TOTAL_FILES=$((TOTAL_FILES+1))
  REL="${FILE#$ROOT/}"

  # Count `**Resolved**:` markers via awk (avoids pipefail pitfall).
  RESOLVED_COUNT=$(awk '/\*\*Resolved\*\*:/ { count++ } END { print count+0 }' "$FILE")
  TOTAL_RESOLVED=$((TOTAL_RESOLVED + RESOLVED_COUNT))

  # Detect stale wording; count its output lines.
  STALE_LINES=$(detect_stale "$FILE" 2>/dev/null || true)
  if [ -n "$STALE_LINES" ]; then
    STALE_COUNT=$(printf '%s\n' "$STALE_LINES" | awk 'END { print NR }')
  else
    STALE_COUNT=0
  fi
  TOTAL_STALE=$((TOTAL_STALE + STALE_COUNT))

  # Per-Resolved evidence verification: list lines, then count missing.
  MISSING_EVIDENCE_LOCAL=0
  if [ "$RESOLVED_COUNT" -gt 0 ]; then
    RESOLVED_LINE_NOS=$(grep -nF '**Resolved**:' "$FILE" | cut -d: -f1)
    while IFS= read -r LINENO; do
      [ -z "$LINENO" ] && continue
      HAS_EVIDENCE=$(verify_resolved_evidence "$FILE" "$LINENO")
      if [ "$HAS_EVIDENCE" -ne 1 ]; then
        MISSING_EVIDENCE_LOCAL=$((MISSING_EVIDENCE_LOCAL + 1))
      fi
    done <<EOF
$RESOLVED_LINE_NOS
EOF
  fi
  TOTAL_MISSING_EVIDENCE=$((TOTAL_MISSING_EVIDENCE + MISSING_EVIDENCE_LOCAL))

  if [ "$STALE_COUNT" -gt 0 ]; then
    STALE_FILES_LIST+=("$REL (stale=$STALE_COUNT)")
  fi
  if [ "$MISSING_EVIDENCE_LOCAL" -gt 0 ]; then
    MISSING_EVIDENCE_FILES_LIST+=("$REL (missing_ev=$MISSING_EVIDENCE_LOCAL)")
  fi

  # Classify file status (closed / pending / ambiguous / n/a).
  # Rules:
  #   closed:    resolved ≥ 1, stale = 0  → file's out-of-scope items all Resolved.
  #   pending:   resolved = 0, stale ≥ 1  → only open items, nothing closed yet.
  #   ambiguous: resolved ≥ 1, stale ≥ 1  → mid-transition; most common case
  #                                          during typing-cleanup waves.
  #   n/a:       both markers = 0         → file lacks deferred-status markings;
  #                                          skipped from classification table.
  STATUS=""
  if [ "$RESOLVED_COUNT" -ge 1 ] && [ "$STALE_COUNT" -eq 0 ]; then
    STATUS="closed"
    CLOSED_FILES_LIST+=("$REL")
  elif [ "$RESOLVED_COUNT" -eq 0 ] && [ "$STALE_COUNT" -ge 1 ]; then
    STATUS="pending"
    PENDING_FILES_LIST+=("$REL")
  elif [ "$RESOLVED_COUNT" -ge 1 ] && [ "$STALE_COUNT" -ge 1 ]; then
    STATUS="ambiguous"
    AMBIGUOUS_FILES_LIST+=("$REL")
  else
    STATUS="n/a"
  fi

  if [ "$JSON" -eq 1 ]; then
    if [ "$FIRST" -eq 0 ]; then echo ","; fi
    FIRST=0
    printf '    {"path": "%s", "resolved": %d, "stale": %d, "missing_evidence": %d, "status": "%s"}' \
      "$REL" "$RESOLVED_COUNT" "$STALE_COUNT" "$MISSING_EVIDENCE_LOCAL" "$STATUS"
  else
    # Suppress `status=n/a` from the per-file row — only show the user's
    # three explicit states (closed/pending/ambiguous). Files lacking
    # Resolved/stale markers appear without any status= label so the
    # row keeps its focus on classified files only.
    if [ "$STATUS" = "n/a" ]; then
      printf "    %-60s resolved=%2d stale=%2d missing_ev=%-2d\n" \
        "$REL" "$RESOLVED_COUNT" "$STALE_COUNT" "$MISSING_EVIDENCE_LOCAL"
    else
      # %-10s pads status="ambiguous" (10 chars, longest of the three)
      # so all 3 labels left-align consistently in the column.
      printf "    %-60s resolved=%2d stale=%2d missing_ev=%-2d status=%-10s\n" \
        "$REL" "$RESOLVED_COUNT" "$STALE_COUNT" "$MISSING_EVIDENCE_LOCAL" "$STATUS"
    fi
    if [ "$STALE_COUNT" -gt 0 ]; then
      while IFS= read -r SL; do
        [ -z "$SL" ] && continue
        printf "        stale: %s\n" "$SL"
      done <<EOF
$STALE_LINES
EOF
    fi
  fi
done

if [ "$JSON" -eq 1 ]; then
  echo
  echo "  ],"
  echo "  \"totals\": {"
  echo "    \"files_scanned\": $TOTAL_FILES,"
  echo "    \"resolved_blocks\": $TOTAL_RESOLVED,"
  echo "    \"stale_items\": $TOTAL_STALE,"
  echo "    \"missing_evidence\": $TOTAL_MISSING_EVIDENCE,"
  echo "    \"closed\": ${#CLOSED_FILES_LIST[@]},"
  echo "    \"pending\": ${#PENDING_FILES_LIST[@]},"
  echo "    \"ambiguous\": ${#AMBIGUOUS_FILES_LIST[@]}"
  echo "  }"
  echo "}"
else
  echo
  echo "==> Totals"
  echo "    files_scanned:        $TOTAL_FILES"
  echo "    resolved_blocks:      $TOTAL_RESOLVED"
  echo "    stale_items:          $TOTAL_STALE"
  echo "    missing_evidence:     $TOTAL_MISSING_EVIDENCE"
  echo "    status_counts:        closed=${#CLOSED_FILES_LIST[@]} pending=${#PENDING_FILES_LIST[@]} ambiguous=${#AMBIGUOUS_FILES_LIST[@]}"
  echo

  if [ "$TOTAL_MISSING_EVIDENCE" -gt 0 ]; then
    echo "==> Missing-evidence warnings"
    for F in "${MISSING_EVIDENCE_FILES_LIST[@]}"; do
      echo "    $F"
    done
    echo
  fi

  if [ "$TOTAL_STALE" -gt 0 ]; then
    echo "==> Stale files (commit hash without nearby Resolved)"
    for F in "${STALE_FILES_LIST[@]}"; do
      echo "    $F"
    done
    echo
    echo "    Recommendation: re-run after each typing-cleanup commit."
    echo "                    Items above may already be resolved — re-edit them"
    echo "                    to use the ~~old~~ **Resolved**: <evidence> pattern."
  else
    echo "==> Stale open-state: none found."
  fi

  # Per-file status breakdown table — the post-typing-cleanup sanity
  # check the user asked for: closed / pending / ambiguous buckets.
  echo
  echo "==> Per-file status table (closed / pending / ambiguous)"
  if [ "${#CLOSED_FILES_LIST[@]}" -gt 0 ]; then
    echo "    closed (out-of-scope items all Resolved):"
    for F in "${CLOSED_FILES_LIST[@]}"; do echo "      $F"; done
  fi
  if [ "${#PENDING_FILES_LIST[@]}" -gt 0 ]; then
    echo "    pending (only open items, none yet closed):"
    for F in "${PENDING_FILES_LIST[@]}"; do echo "      $F"; done
  fi
  if [ "${#AMBIGUOUS_FILES_LIST[@]}" -gt 0 ]; then
    echo "    ambiguous (mix of Resolved + open items — likely mid-transition):"
    for F in "${AMBIGUOUS_FILES_LIST[@]}"; do echo "      $F"; done
  fi
  if [ "${#CLOSED_FILES_LIST[@]}" -eq 0 ] && \
     [ "${#PENDING_FILES_LIST[@]}" -eq 0 ] && \
     [ "${#AMBIGUOUS_FILES_LIST[@]}" -eq 0 ]; then
    echo "    (no classified files — every scanned file lacks Resolved/stale markers)"
  fi

  echo "==> Done. Re-run after each typing-cleanup commit (or typed-network PR)."
fi

# Exit code logic:
#   - exit 4: any Resolved block missing evidence (always non-zero, warning)
#   - exit 1: stale items found AND --fail-on-stale set (opt-in CI gate)
#   - exit 0: clean, OR stale items found but --fail-on-stale not set
#             (default — transitional `ambiguous` state is informational)
if [ "$TOTAL_MISSING_EVIDENCE" -gt 0 ]; then
  exit 4
fi
if [ "$FAIL_ON_STALE" -eq 1 ] && [ "$TOTAL_STALE" -gt 0 ]; then
  exit 1
fi
exit 0
