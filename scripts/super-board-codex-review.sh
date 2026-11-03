#!/usr/bin/env bash
# super-board-codex-review.sh — optional local Codex review of a branch, run by the Builder
# before it pushes, so most findings are fixed before the PR exists instead of after a
# PR-side Codex review round-trip.
#
# OPTIONAL BY DESIGN. It never blocks the Builder. It runs only when:
#   - SUPER_BOARD_CODEX_REVIEW is not 0/false/off (manual opt-out),
#   - the `codex` CLI is on PATH,
#   - Codex is signed in and the account still has usage.
# Codex has no command that reports remaining usage, and its session logs do not carry it
# reliably, so usage is checked by running the review: an exhausted or signed-out account
# fails fast (no tokens spent) and the failure text is classed below as a skip.
#
# Usage: super-board-codex-review.sh --base <branch> [--output <file>] [--timeout <seconds>]
#   Run from inside the worktree. --base is the PR base (e.g. main); origin/<base> is used
#   when it exists so the diff matches what the PR will show.
#
# Stdout, exactly one line:
#   codex-review: ran <output-file>       findings (if any) are in <output-file>
#   codex-review: skipped <reason>        reason ∈ disabled | not-installed | no-usage |
#                                         not-signed-in | timeout | error <log-file>
# Exit 0 for both (advisory). Exit 64 for bad arguments only.
set -uo pipefail

base='' output='' limit="${SUPER_BOARD_CODEX_REVIEW_TIMEOUT:-900}"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --timeout) limit="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
[ -n "$base" ] || { echo "--base <branch> is required" >&2; exit 64; }
case "$limit" in ''|*[!0-9]*) echo "--timeout needs whole seconds" >&2; exit 64 ;; esac

skip() { echo "codex-review: skipped $1"; exit 0; }

case "$(printf '%s' "${SUPER_BOARD_CODEX_REVIEW:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|off|no) skip disabled ;;
esac
command -v codex >/dev/null 2>&1 || skip not-installed

# Prefer the remote base: a stale local base would pull unrelated commits into the review.
ref="$base"
git rev-parse --verify --quiet "origin/$base" >/dev/null && ref="origin/$base"

[ -n "$output" ] || output="$(mktemp "${TMPDIR:-/tmp}/super-board-codex-review.XXXXXX")"
log="$output.log"

# Bound the run. `timeout` ships with GNU coreutils (Linux, Git Bash); macOS has it as
# `gtimeout` via Homebrew coreutils. Without either the review runs unbounded.
runner=()
if command -v timeout >/dev/null 2>&1; then runner=(timeout "$limit")
elif command -v gtimeout >/dev/null 2>&1; then runner=(gtimeout "$limit"); fi

rc=0
${runner[@]+"${runner[@]}"} codex review --base "$ref" -c 'approval_policy="never"' >"$output" 2>"$log" </dev/null || rc=$?

if [ "$rc" -eq 0 ]; then
  rm -f "$log"
  echo "codex-review: ran $output"
  exit 0
fi

# Failure: class it. Patterns are the codex-cli / OpenAI API error texts for each case.
text="$(cat "$output" "$log" 2>/dev/null)"
[ "$rc" -eq 124 ] && skip timeout
if printf '%s' "$text" | grep -qiE 'usage.?limit|usage_limit_reached|rate.?limit|429|too many requests|quota|insufficient_quota|try again (at|in)'; then
  skip no-usage
fi
if printf '%s' "$text" | grep -qiE 'not logged in|codex login|401|unauthori[sz]ed|authentication|api key'; then
  skip not-signed-in
fi
skip "error $log"
