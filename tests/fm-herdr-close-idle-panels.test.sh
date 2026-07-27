#!/usr/bin/env bash
# Unit/smoke tests for bin/fm-herdr-close-idle-panels.sh.
# Uses a fake herdr client: arg parsing, dry-run, focus/agent/editor/harness
# keep rules, idle close path, and --json summary shape. No real Herdr server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-herdr-close-idle-panels.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-close-idle-panels)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STATE="$TMP_ROOT/herdr-state"
CLOSE_LOG="$TMP_ROOT/closes.log"
mkdir -p "$STATE"
: > "$CLOSE_LOG"

assert_present "$SCRIPT" "bin/fm-herdr-close-idle-panels.sh missing"
[ -x "$SCRIPT" ] || fail "bin/fm-herdr-close-idle-panels.sh must be executable"

# Stateful fake herdr: pane list + process-info from STATE, pane close logged.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_FAKE_HERDR_STATE:?}
# Drop trailing --session <name> if present (script may pass it).
args=("$@")
if [ "${#args[@]}" -ge 2 ]; then
  n=${#args[@]}
  if [ "${args[$((n - 2))]}" = --session ]; then
    unset "args[$((n - 1))]"
    unset "args[$((n - 2))]"
    args=("${args[@]}")
  fi
fi
cmd="${args[0]:-}"
sub="${args[1]:-}"
case "$cmd $sub" in
  "pane list")
    cat "$state/pane-list.json"
    exit 0
    ;;
  "pane process-info")
    pane=
    i=0
    while [ $i -lt ${#args[@]} ]; do
      if [ "${args[$i]}" = --pane ]; then
        pane=${args[$((i + 1))]:-}
        break
      fi
      i=$((i + 1))
    done
    [ -n "$pane" ] || { echo "fake herdr: missing --pane" >&2; exit 2; }
    f="$state/process-${pane}.json"
    if [ -f "$f" ]; then
      cat "$f"
      exit 0
    fi
    echo "fake herdr: no process-info for $pane" >&2
    exit 1
    ;;
  "pane close")
    pane=${args[2]:-}
    [ -n "$pane" ] || { echo "fake herdr: missing pane id" >&2; exit 2; }
    printf '%s\n' "$pane" >> "${FM_FAKE_CLOSE_LOG:?}"
    printf '{"result":{"closed":true}}\n'
    exit 0
    ;;
  *)
    echo "fake herdr: unhandled: ${args[*]}" >&2
    exit 90
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"
export FM_FAKE_HERDR_STATE="$STATE"
export FM_FAKE_CLOSE_LOG="$CLOSE_LOG"

write_pane_list() {
  cat > "$STATE/pane-list.json"
}

write_process() {
  # Usage: write_process <pane_id> <json-body>
  local pane_id=$1 body=$2
  printf '%s\n' "$body" > "$STATE/process-${pane_id}.json"
}

fg_shell() {
  printf '%s\n' '{"result":{"process_info":{"foreground_processes":[{"name":"zsh","cmdline":"-zsh","argv0":"-zsh"}]}}}'
}

fg_named() {
  local name=$1 cmdline=$2 argv0=$3
  jq -nc --arg n "$name" --arg c "$cmdline" --arg a "$argv0" \
    '{result:{process_info:{foreground_processes:[{name:$n,cmdline:$c,argv0:$a}]}}}'
}

# --- arg parsing / help -----------------------------------------------------

code=0
out=$("$SCRIPT" --help 2>&1) || code=$?
expect_code 0 "$code" "--help exit"
assert_contains "$out" "Close idle Herdr panes" "--help shows purpose"
assert_contains "$out" "--dry-run" "--help lists --dry-run"
assert_contains "$out" "--include-focused" "--help lists --include-focused"
assert_contains "$out" "--session" "--help lists --session"
assert_contains "$out" "--json" "--help lists --json"
pass "help and flag documentation"

code=0
out=$("$SCRIPT" --not-a-flag 2>&1) || code=$?
expect_code 2 "$code" "unknown flag exit"
assert_contains "$out" "unknown argument" "unknown flag message"
pass "unknown argument refuses"

# --- missing herdr ----------------------------------------------------------

empty_bin=$(fm_fakebin "$TMP_ROOT/no-herdr")
# Keep real jq (and base utils); do not inherit fakebin that contains herdr.
jq_dir=$(dirname "$(command -v jq)")
miss_out=$(
  PATH="$empty_bin:$jq_dir:/usr/bin:/bin"
  # If a real herdr is still reachable, skip this assertion rather than false-fail.
  if command -v herdr >/dev/null 2>&1; then
    printf 'SKIP_HERDR_PRESENT\n'
    exit 0
  fi
  out=$("$SCRIPT" --dry-run 2>&1) && c=0 || c=$?
  printf 'code=%s\n' "$c"
  printf '%s\n' "$out"
)
if [[ "$miss_out" == SKIP_HERDR_PRESENT* ]]; then
  pass "missing-herdr check skipped (real herdr on host PATH)"
else
  echo "$miss_out" | grep -q '^code=1$' || fail "missing herdr should exit 1: $miss_out"
  assert_contains "$miss_out" "herdr CLI not found" "missing herdr message"
  pass "refuses when herdr is not on PATH"
fi

# --- dry-run: idle shell closes, focused/agent/editor/harness kept ----------

write_pane_list <<'JSON'
{
  "result": {
    "panes": [
      {"pane_id":"p-idle","tab_id":"t1","cwd":"/tmp/idle","focused":false,"agent":"","agent_status":""},
      {"pane_id":"p-focused","tab_id":"t1","cwd":"/tmp/focus","focused":true,"agent":"","agent_status":""},
      {"pane_id":"p-agent","tab_id":"t2","cwd":"/tmp/agent","focused":false,"agent":"claude","agent_status":"running"},
      {"pane_id":"p-editor","tab_id":"t2","cwd":"/tmp/edit","focused":false,"agent":"","agent_status":""},
      {"pane_id":"p-harness","tab_id":"t3","cwd":"/tmp/harness","focused":false,"agent":"","agent_status":""},
      {"pane_id":"p-nonshell","tab_id":"t3","cwd":"/tmp/node","focused":false,"agent":"","agent_status":""}
    ]
  }
}
JSON
write_process p-idle "$(fg_shell)"
write_process p-focused "$(fg_shell)"
write_process p-agent "$(fg_shell)"
write_process p-editor "$(fg_named nvim nvim /usr/bin/nvim)"
write_process p-harness "$(fg_named claude 'claude --dangerously-skip-permissions' /opt/homebrew/bin/claude)"
write_process p-nonshell "$(fg_named node 'node app.js' /usr/local/bin/node)"

: > "$CLOSE_LOG"
code=0
out=$("$SCRIPT" --dry-run --json 2>&1) || code=$?
expect_code 0 "$code" "dry-run --json exit"
echo "$out" | jq -e '.dry_run == true' >/dev/null || fail "dry_run flag in json: $out"
echo "$out" | jq -e '.counts.closed == 1' >/dev/null || fail "exactly one idle closed: $out"
echo "$out" | jq -e '.closed[0].pane_id == "p-idle"' >/dev/null || fail "idle pane closed: $out"
echo "$out" | jq -e '.closed[0].action == "dry-run"' >/dev/null || fail "dry-run action label: $out"
echo "$out" | jq -e '[.kept[].pane_id] | sort == ["p-agent","p-editor","p-focused","p-harness","p-nonshell"]' >/dev/null \
  || fail "kept panes mismatch: $out"
echo "$out" | jq -e '[.kept[] | select(.pane_id=="p-focused") | .reason][0] | test("focused")' >/dev/null \
  || fail "focused keep reason: $out"
echo "$out" | jq -e '[.kept[] | select(.pane_id=="p-agent") | .reason][0] | test("agent harness")' >/dev/null \
  || fail "agent keep reason: $out"
echo "$out" | jq -e '[.kept[] | select(.pane_id=="p-editor") | .reason][0] | test("editor")' >/dev/null \
  || fail "editor keep reason: $out"
echo "$out" | jq -e '[.kept[] | select(.pane_id=="p-harness") | .reason][0] | test("harness")' >/dev/null \
  || fail "harness keep reason: $out"
echo "$out" | jq -e '[.kept[] | select(.pane_id=="p-nonshell") | .reason][0] | test("non-shell")' >/dev/null \
  || fail "non-shell keep reason: $out"
[ ! -s "$CLOSE_LOG" ] || fail "dry-run must not call pane close; log=$(cat "$CLOSE_LOG")"
pass "dry-run keeps focused/agent/editor/harness/non-shell and lists idle"

# --- --include-focused allows focused idle shell ----------------------------

: > "$CLOSE_LOG"
code=0
out=$("$SCRIPT" --dry-run --include-focused --json 2>&1) || code=$?
expect_code 0 "$code" "include-focused dry-run exit"
echo "$out" | jq -e '[.closed[].pane_id] | sort == ["p-focused","p-idle"]' >/dev/null \
  || fail "include-focused should mark focused idle: $out"
pass "--include-focused marks focused idle shell for close"

# --- live close path (still fake herdr) -------------------------------------

write_pane_list <<'JSON'
{
  "result": {
    "panes": [
      {"pane_id":"p-a","tab_id":"t1","cwd":"/tmp/a","focused":false,"agent":"","agent_status":""},
      {"pane_id":"p-b","tab_id":"t1","cwd":"/tmp/b","focused":false,"agent":"codex","agent_status":"idle"}
    ]
  }
}
JSON
write_process p-a "$(fg_shell)"
write_process p-b "$(fg_shell)"
: > "$CLOSE_LOG"
code=0
out=$("$SCRIPT" --json 2>&1) || code=$?
expect_code 0 "$code" "live close exit"
echo "$out" | jq -e '.dry_run == false and .counts.closed == 1 and .closed[0].pane_id == "p-a" and .closed[0].action == "closed"' >/dev/null \
  || fail "live close json: $out"
echo "$out" | jq -e '.kept[0].pane_id == "p-b"' >/dev/null || fail "agent kept on live close: $out"
closes=$(cat "$CLOSE_LOG")
[ "$closes" = "p-a" ] || fail "close log expected only p-a, got: $closes"
pass "live close closes only idle panes"

# --- --session is forwarded -------------------------------------------------

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_STATE}/argv.log"
# Minimal valid empty list so the script exits cleanly after seeing --session.
if [[ " $* " == *" pane list "* ]] || [[ "$*" == pane\ list* ]]; then
  printf '{"result":{"panes":[]}}\n'
  exit 0
fi
echo "unexpected: $*" >&2
exit 90
SH
chmod +x "$FAKEBIN/herdr"
: > "$STATE/argv.log"
code=0
out=$("$SCRIPT" --session labsess --dry-run --json 2>&1) || code=$?
expect_code 0 "$code" "--session dry-run exit"
assert_grep "--session labsess" "$STATE/argv.log" "herdr must receive --session labsess"
echo "$out" | jq -e '.session == "labsess"' >/dev/null || fail "json session field: $out"
pass "--session is forwarded to herdr and reported in json"

# --- human dry-run mode line ------------------------------------------------

write_pane_list <<'JSON'
{"result":{"panes":[]}}
JSON
code=0
out=$("$SCRIPT" --dry-run 2>&1) || code=$?
expect_code 0 "$code" "human dry-run exit"
assert_contains "$out" "mode: dry-run" "human dry-run mode line"
assert_contains "$out" "idle: none" "empty idle summary"
pass "human dry-run summary"

pass "fm-herdr-close-idle-panels tests complete"
