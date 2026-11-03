#!/usr/bin/env bash
# Tests super-board-codex-review.sh — the Builder's optional local Codex review. Every outcome
# but bad arguments exits 0 with one `codex-review: ran|skipped <reason>` line on stdout.
# A fake `codex` on PATH stands in for the real CLI, so no tokens are spent.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
S="$KIT/scripts/super-board-codex-review.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; BIN="$TMP/bin"; mkdir -p "$REPO" "$BIN"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# The fake records its arguments, then behaves as FAKE_CODEX says.
cat >"$BIN/codex" <<'EOF'
#!/usr/bin/env bash
echo "$*" >"$FAKE_ARGS"
case "$FAKE_CODEX" in
  ok)       echo "[P1] off-by-one in loop.ts:12" ;;
  usage)    echo "ERROR: You've hit your usage limit. Try again at 3:00 PM." >&2; exit 1 ;;
  ratelim)  echo "stream error: 429 Too Many Requests" >&2; exit 1 ;;
  auth)     echo "Not logged in. Run codex login." >&2; exit 1 ;;
  boom)     echo "panic: something else" >&2; exit 2 ;;
  slow)     sleep 5 ;;
esac
EOF
chmod +x "$BIN/codex"
export FAKE_ARGS="$TMP/args"

# Bash's own dir stays on PATH (git, mktemp, timeout); the fake codex dir comes first.
# A PATH without the fake must not see a real codex installed alongside bash.
SYS="$(dirname "$(command -v git)"):$(dirname "$(command -v mktemp)"):/usr/bin:/bin"
run() { (cd "$REPO" && env PATH="$BIN:$SYS" "$@" bash "$S" --base main --output "$TMP/out"); }

out=$(run FAKE_CODEX=ok); [ "$out" = "codex-review: ran $TMP/out" ] || fail "ok run: '$out'"
grep -q 'off-by-one' "$TMP/out" || fail 'findings land in --output'
grep -q -- '--base main' "$FAKE_ARGS" || fail "no origin/main → local base, got '$(cat "$FAKE_ARGS")'"

[ "$(run FAKE_CODEX=usage)" = 'codex-review: skipped no-usage' ] || fail 'usage limit → no-usage'
[ "$(run FAKE_CODEX=ratelim)" = 'codex-review: skipped no-usage' ] || fail '429 → no-usage'
[ "$(run FAKE_CODEX=auth)" = 'codex-review: skipped not-signed-in' ] || fail 'signed out → not-signed-in'
out=$(run FAKE_CODEX=boom); [ "$out" = "codex-review: skipped error $TMP/out.log" ] || fail "other error: '$out'"
grep -q panic "$TMP/out.log" || fail 'error log kept for the report'
[ "$(run FAKE_CODEX=ok SUPER_BOARD_CODEX_REVIEW=0)" = 'codex-review: skipped disabled' ] || fail 'opt-out'
[ "$(run FAKE_CODEX=ok SUPER_BOARD_CODEX_REVIEW=off)" = 'codex-review: skipped disabled' ] || fail 'opt-out off'
if command -v timeout >/dev/null 2>&1; then
  [ "$(run FAKE_CODEX=slow SUPER_BOARD_CODEX_REVIEW_TIMEOUT=1)" = 'codex-review: skipped timeout' ] || fail 'timeout'
fi

# Not installed: a PATH with no codex on it at all.
rm "$BIN/codex"
if (env PATH="$SYS" bash -c 'command -v codex' >/dev/null 2>&1); then
  echo "note: a real codex sits next to git; not-installed case skipped"
else
  [ "$(run)" = 'codex-review: skipped not-installed' ] || fail 'no codex → not-installed'
fi

# origin/<base> wins when it exists.
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
cat >"$BIN/codex" <<'EOF'
#!/usr/bin/env bash
echo "$*" >"$FAKE_ARGS"
EOF
chmod +x "$BIN/codex"
run FAKE_CODEX=ok >/dev/null
grep -q -- '--base origin/main' "$FAKE_ARGS" || fail "origin/main preferred, got '$(cat "$FAKE_ARGS")'"

rc=0; (cd "$REPO" && bash "$S" >/dev/null 2>&1) || rc=$?; [ "$rc" = 64 ] || fail "no --base exits 64, got $rc"
rc=0; (cd "$REPO" && bash "$S" --base main --timeout x >/dev/null 2>&1) || rc=$?; [ "$rc" = 64 ] || fail "bad --timeout exits 64"

# A flag with no value must exit 64, not loop (`shift 2` fails silently without set -e).
for flag in --base --output --timeout; do
  rc=0; (cd "$REPO" && timeout 5 bash "$S" --base main "$flag" >/dev/null 2>&1) || rc=$?
  [ "$rc" = 64 ] || fail "trailing $flag exits 64, got $rc"
done

echo "PASS: test-codex-review.sh"
