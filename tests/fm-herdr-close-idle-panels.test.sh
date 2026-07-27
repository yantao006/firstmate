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
printf '%s\n' "$*" >> "$state/calls.log"
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
  "api snapshot")
    snapshot_count=$(cat "$state/snapshot-count")
    snapshot_count=$((snapshot_count + 1))
    printf '%s\n' "$snapshot_count" > "$state/snapshot-count"
    focused=$(cat "$state/focused-pane")
    focused_tab=$(cat "$state/focused-tab")
    focus_switch_count=$(cat "$state/focus-switch-count")
    if [ "$snapshot_count" -ge "$focus_switch_count" ] && [ -f "$state/focused-pane-after-first" ]; then
      focused=$(cat "$state/focused-pane-after-first")
    fi
    printf '{"result":{"snapshot":{"focused_workspace_id":"w1","focused_tab_id":"%s","focused_pane_id":"%s"}}}\n' "$focused_tab" "$focused"
    exit 0
    ;;
  "agent get")
    pane=${args[2]:-}
    f="$state/agent-${pane}.json"
    if [ -f "$f" ]; then
      cat "$f"
      exit 0
    fi
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
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
    [ ! -f "$state/close-fail-$pane" ] || exit 1
    printf '%s\n' "$pane" >> "${FM_FAKE_CLOSE_LOG:?}"
    if [ -f "$state/focus-steal-$pane" ]; then
      cat "$state/focus-steal-$pane" > "$state/focused-pane"
    fi
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
printf '%s\n' p-captain > "$STATE/focused-pane"
printf '%s\n' t-focus > "$STATE/focused-tab"
: > "$STATE/calls.log"
printf '%s\n' 0 > "$STATE/snapshot-count"
printf '%s\n' 2 > "$STATE/focus-switch-count"

write_pane_list() {
  cat > "$STATE/pane-list.json"
}

write_process() {
  # Usage: write_process <pane_id> <json-body>
  local pane_id=$1 body=$2
  printf '%s\n' "$body" > "$STATE/process-${pane_id}.json"
}

fg_shell() {
  local pane_id=$1
  jq -nc --arg pane "$pane_id" \
    '{result:{type:"pane_process_info",process_info:{pane_id:$pane,foreground_processes:[{name:"zsh",cmdline:"-zsh",argv0:"-zsh"}]}}}'
}

fg_named() {
  local pane_id=$1 name=$2 cmdline=$3 argv0=$4
  jq -nc --arg pane "$pane_id" --arg n "$name" --arg c "$cmdline" --arg a "$argv0" \
    '{result:{type:"pane_process_info",process_info:{pane_id:$pane,foreground_processes:[{name:$n,cmdline:$c,argv0:$a}]}}}'
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
[ ! -s "$STATE/calls.log" ] || fail "--help must not invoke herdr or load stateful backend helpers"
pass "help and flag documentation"

code=0
out=$("$SCRIPT" --not-a-flag 2>&1) || code=$?
expect_code 2 "$code" "unknown flag exit"
assert_contains "$out" "unknown argument" "unknown flag message"
pass "unknown argument refuses"

code=0
out=$("$SCRIPT" --session --dry-run 2>&1) || code=$?
expect_code 2 "$code" "missing --session value exit"
assert_contains "$out" "--session requires a value" "missing --session value message"
pass "--session refuses an option as its value"

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
      {"pane_id":"p-idle","tab_id":"t1","cwd":"/tmp/idle"},
      {"pane_id":"p-focused","tab_id":"t1","cwd":"/tmp/focus"},
      {"pane_id":"p-agent","tab_id":"t2","cwd":"/tmp/agent"},
      {"pane_id":"p-editor","tab_id":"t2","cwd":"/tmp/edit"},
      {"pane_id":"p-harness","tab_id":"t3","cwd":"/tmp/harness"},
      {"pane_id":"p-nonshell","tab_id":"t3","cwd":"/tmp/node"}
    ]
  }
}
JSON
printf '%s\n' p-focused > "$STATE/focused-pane"
printf '%s\n' '{"result":{"agent":{"agent":"claude","agent_status":"running"}}}' > "$STATE/agent-p-agent.json"
write_process p-idle "$(fg_shell p-idle)"
write_process p-focused "$(fg_shell p-focused)"
write_process p-agent "$(fg_shell p-agent)"
write_process p-editor "$(fg_named p-editor nvim nvim /usr/bin/nvim)"
write_process p-harness "$(fg_named p-harness claude 'claude --dangerously-skip-permissions' /opt/homebrew/bin/claude)"
write_process p-nonshell "$(fg_named p-nonshell node 'node app.js' /usr/local/bin/node)"

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
      {"pane_id":"p-a","tab_id":"t1","cwd":"/tmp/a|line\nnext"},
      {"pane_id":"p-b","tab_id":"t1","cwd":"/tmp/b"}
    ]
  }
}
JSON
printf '%s\n' p-captain > "$STATE/focused-pane"
printf '%s\n' t1 > "$STATE/focused-tab"
rm -f "$STATE/agent-p-agent.json"
printf '%s\n' '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}' > "$STATE/agent-p-b.json"
write_process p-a "$(fg_shell p-a)"
write_process p-b "$(fg_shell p-b)"
: > "$CLOSE_LOG"
code=0
out=$("$SCRIPT" --json 2>&1) || code=$?
expect_code 0 "$code" "live close exit"
echo "$out" | jq -e '.dry_run == false and .counts.closed == 1 and .closed[0].pane_id == "p-a" and .closed[0].action == "closed"' >/dev/null \
  || fail "live close json: $out"
echo "$out" | jq -e '.closed[0].cwd == "/tmp/a|line\nnext" and .closed[0].tab_id == "t1"' >/dev/null \
  || fail "live close JSON must preserve delimiter characters: $out"
echo "$out" | jq -e '.kept[0].pane_id == "p-b"' >/dev/null || fail "agent kept on live close: $out"
closes=$(cat "$CLOSE_LOG")
[ "$closes" = "p-a" ] || fail "close log expected only p-a, got: $closes"
pass "live close closes only idle panes"
printf '%s\n' t-focus > "$STATE/focused-tab"

snapshot_calls=$(grep -c '^api snapshot$' "$STATE/calls.log")
agent_calls=$(grep -c '^agent get p-a$' "$STATE/calls.log")
process_calls=$(grep -c '^pane process-info --pane p-a$' "$STATE/calls.log")
[ "$snapshot_calls" -ge 2 ] || fail "live close must recheck snapshot"
[ "$agent_calls" -eq 2 ] || fail "live close must recheck agent state"
[ "$process_calls" -eq 2 ] || fail "live close must recheck process state"
pass "live close revalidates all safety state"

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-race","tab_id":"t1","cwd":"/tmp/race"}]}}
JSON
printf '%s\n' p-captain > "$STATE/focused-pane"
printf '%s\n' p-race > "$STATE/focused-pane-after-first"
printf '%s\n' 0 > "$STATE/snapshot-count"
printf '%s\n' 3 > "$STATE/focus-switch-count"
write_process p-race "$(fg_shell p-race)"
: > "$CLOSE_LOG"
code=0
out=$("$SCRIPT" --json 2>&1) || code=$?
expect_code 0 "$code" "focus race exit"
echo "$out" | jq -e '.counts.closed == 0 and .kept[0].pane_id == "p-race" and (.kept[0].reason | test("changed before close: focused"))' >/dev/null \
  || fail "newly focused pane must be kept: $out"
[ ! -s "$CLOSE_LOG" ] || fail "newly focused pane must not be closed"
rm "$STATE/focused-pane-after-first"
printf '%s\n' 2 > "$STATE/focus-switch-count"
pass "live close keeps a pane focused during scanning"

# --- malformed process-info fails closed ------------------------------------

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-malformed","tab_id":"t1","cwd":"/tmp/malformed","focused":false,"agent":""}]}}
JSON
write_process p-malformed '{"result":{"type":"pane_process_info","process_info":{"pane_id":"p-other","foreground_processes":[]}}}'
: > "$CLOSE_LOG"
code=0
out=$("$SCRIPT" --dry-run --json 2>&1) || code=$?
expect_code 0 "$code" "malformed process-info dry-run exit"
echo "$out" | jq -e '.counts.closed == 0 and .kept[0].pane_id == "p-malformed" and (.kept[0].reason | test("invalid process-info"))' >/dev/null \
  || fail "malformed process-info must be kept: $out"
pass "malformed process-info fails closed"

# --- empty focus state fails closed -----------------------------------------

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-empty-focus","tab_id":"t1","cwd":"/tmp/empty-focus"}]}}
JSON
: > "$STATE/focused-pane"
write_process p-empty-focus "$(fg_shell p-empty-focus)"
code=0
out=$("$SCRIPT" --dry-run --json 2>&1) || code=$?
expect_code 0 "$code" "empty focus dry-run exit"
echo "$out" | jq -e '.counts.closed == 0 and .kept[0].pane_id == "p-empty-focus" and (.kept[0].reason | test("invalid snapshot"))' >/dev/null \
  || fail "empty focused pane id must fail closed: $out"
printf '%s\n' p-captain > "$STATE/focused-pane"
pass "empty focused pane id fails closed"

# --- unidentified foreground process fails closed ---------------------------

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-unknown","tab_id":"t1","cwd":"/tmp/unknown","focused":false,"agent":""}]}}
JSON
write_process p-unknown '{"result":{"type":"pane_process_info","process_info":{"pane_id":"p-unknown","foreground_processes":[{"pid":42}]}}}'
: > "$CLOSE_LOG"
code=0
out=$("$SCRIPT" --dry-run --json 2>&1) || code=$?
expect_code 0 "$code" "unidentified process dry-run exit"
echo "$out" | jq -e '.counts.closed == 0 and .kept[0].pane_id == "p-unknown" and (.kept[0].reason | test("invalid process-info"))' >/dev/null \
  || fail "unidentified process must be kept: $out"
pass "unidentified foreground process fails closed"

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-cmdline","tab_id":"t1","cwd":"/tmp/cmdline"}]}}
JSON
write_process p-cmdline '{"result":{"type":"pane_process_info","process_info":{"pane_id":"p-cmdline","foreground_processes":[{"cmdline":"node app.js"}]}}}'
code=0
out=$("$SCRIPT" --dry-run --json 2>&1) || code=$?
expect_code 0 "$code" "cmdline-only process dry-run exit"
echo "$out" | jq -e '.counts.closed == 0 and .kept[0].pane_id == "p-cmdline"' >/dev/null \
  || fail "cmdline-only process must be kept: $out"
pass "cmdline-only foreground process fails closed"

# --- empty leading process fields remain aligned ----------------------------

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-empty-name","tab_id":"t1","cwd":"/tmp/empty-name"}]}}
JSON
write_process p-empty-name '{"result":{"type":"pane_process_info","process_info":{"pane_id":"p-empty-name","foreground_processes":[{"name":"","cmdline":"-zsh","argv0":"/bin/zsh"}]}}}'
code=0
out=$("$SCRIPT" --dry-run --json 2>&1) || code=$?
expect_code 0 "$code" "empty process name dry-run exit"
echo "$out" | jq -e '.counts.closed == 1 and .closed[0].pane_id == "p-empty-name"' >/dev/null \
  || fail "empty process name must not shift argv0 fields: $out"
pass "empty process fields remain aligned"

# --- JSON reports close failures with nonzero status ------------------------

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-fail","tab_id":"t1","cwd":"/tmp/fail","focused":false,"agent":""}]}}
JSON
write_process p-fail "$(fg_shell p-fail)"
: > "$STATE/close-fail-p-fail"
code=0
out=$("$SCRIPT" --json 2>&1) || code=$?
expect_code 1 "$code" "JSON close failure exit"
echo "$out" | jq -e '.counts.errors == 1 and .errors[0].pane_id == "p-fail"' >/dev/null \
  || fail "JSON close failure summary: $out"
rm "$STATE/close-fail-p-fail"
pass "JSON close failures return nonzero"

# --- closed pane is reported when focus restoration fails ------------------

write_pane_list <<'JSON'
{"result":{"panes":[
  {"pane_id":"p-restore-fail","tab_id":"t1","cwd":"/tmp/restore-fail"},
  {"pane_id":"p-after-fail","tab_id":"t2","cwd":"/tmp/after-fail"}
]}}
JSON
write_process p-restore-fail "$(fg_shell p-restore-fail)"
write_process p-after-fail "$(fg_shell p-after-fail)"
printf '%s\n' p-other > "$STATE/focus-steal-p-restore-fail"
: > "$CLOSE_LOG"
code=0
out=$("$SCRIPT" --json 2>&1) || code=$?
expect_code 1 "$code" "focus restoration failure exit"
echo "$out" | jq -e '
  .counts.closed == 1
  and .closed[0].pane_id == "p-restore-fail"
  and .counts.errors == 1
  and (.errors[0].error | test("focus restoration failed"))
  and .counts.aborted == 1
  and .aborted[0].pane_id == "p-after-fail"
' >/dev/null || fail "closed pane and focus failure must both be reported: $out"
[ "$(cat "$CLOSE_LOG")" = p-restore-fail ] || fail "closing must stop after focus restoration failure"
rm "$STATE/focus-steal-p-restore-fail"
printf '%s\n' p-captain > "$STATE/focused-pane"
pass "focus restoration failure stops further closes"

# --- human summary preserves empty cwd --------------------------------------

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-empty-cwd","tab_id":"t-empty","cwd":""}]}}
JSON
write_process p-empty-cwd "$(fg_shell p-empty-cwd)"
code=0
out=$("$SCRIPT" --dry-run 2>&1) || code=$?
expect_code 0 "$code" "human empty-cwd exit"
assert_contains "$out" 'pane_id="p-empty-cwd"  action="dry-run"  tab="t-empty"  cwd="?"' "human empty-cwd fields"
pass "human summary preserves empty cwd fields"

# --- human summary escapes control characters -------------------------------

write_pane_list <<'JSON'
{"result":{"panes":[{"pane_id":"p-control","tab_id":"t-control","cwd":"/tmp/line\n\u001b[31mred"}]}}
JSON
write_process p-control "$(fg_shell p-control)"
code=0
out=$("$SCRIPT" --dry-run 2>&1) || code=$?
expect_code 0 "$code" "human control-character exit"
assert_contains "$out" 'cwd="/tmp/line\n\u001b[31mred"' "human control characters escaped"
assert_not_contains "$out" $'\033' "human output contains no raw escape"
pass "human summary escapes control characters"

# --- malformed pane list is rejected ----------------------------------------

printf '%s\n' '{"result":{"panes":{}}}' > "$STATE/pane-list.json"
code=0
out=$("$SCRIPT" --dry-run --json 2>&1) || code=$?
expect_code 1 "$code" "malformed pane-list exit"
assert_contains "$out" "pane list returned an invalid response" "malformed pane-list message"
pass "malformed pane list is rejected"

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
