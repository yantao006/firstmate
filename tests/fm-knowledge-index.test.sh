#!/usr/bin/env bash
# Synthetic E2E coverage for the disposable, physically source-isolated keyword index.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-knowledge-index.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
HOME_DIR="$TMP_ROOT/home"
FIXTURES="$TMP_ROOT/fixtures"
CLI="$ROOT/bin/fm-knowledge-index.sh"
REGISTRY="$HOME_DIR/config/knowledge-sources.json"
PUBLIC="$FIXTURES/public"
REPO_A="$FIXTURES/repo-a"
REPO_B="$FIXTURES/repo-b"
FLEET="$FIXTURES/fleet"
CAPTAIN="$FIXTURES/captain"

mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

sha_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

run_cli() {
  FM_HOME="$HOME_DIR" "$CLI" "$@"
}

search_json() {
  local source=$1 query=$2
  run_cli search --source "$source" --query "$query" --json
}

assert_result_count() {
  local json=$1 expected=$2 message=$3 actual
  actual=$(printf '%s' "$json" | jq '.results | length')
  [ "$actual" -eq "$expected" ] || fail "$message (expected $expected, got $actual)"
}

write_registry() {
  mkdir -p "$HOME_DIR/config"
  jq -n \
    --arg public "$PUBLIC" \
    --arg repo_a "$REPO_A" \
    --arg repo_b "$REPO_B" \
    --arg fleet "$FLEET" \
    --arg captain "$CAPTAIN" \
    '{
      schema:"firstmate.knowledge-sources.v1",
      sources:[
        {id:"public",root:$public,owner:"Public Owner",privacy:"public",markdown_allow:["*.md"],deny:["records/configured-deny.md"]},
        {id:"repo-a",root:$repo_a,owner:"Repo A Owner",privacy:"repo-private",markdown_allow:["*.md"],deny:[],repo:"synthetic/repo-a"},
        {id:"repo-b",root:$repo_b,owner:"Repo B Owner",privacy:"repo-private",markdown_allow:["*.md"],deny:[],repo:"synthetic/repo-b"},
        {id:"fleet",root:$fleet,owner:"Fleet Owner",privacy:"fleet-private",markdown_allow:["*.md"],deny:[]},
        {id:"captain",root:$captain,owner:"Captain Owner",privacy:"captain-private",markdown_allow:["*.md"],deny:[]}
      ]
    }' > "$REGISTRY"
}

write_source() {
  local root=$1 canary=$2 privacy=$3
  mkdir -p \
    "$root/records" "$root/secrets" "$root/generated" "$root/vendor" \
    "$root/build" "$root/data/task" "$root/feedback"
  printf '# Shared slug\nsharedmarker %s %s exactterm prefixretrieval\n' \
    "$canary" "$privacy" > "$root/records/shared.md"
  printf '# Configured deny\nconfigureddenycanary\n' > "$root/records/configured-deny.md"
  printf '# Environment\nenvdenycanary\n' > "$root/.env.md"
  printf '# Secret\nsecretdirdenycanary\n' > "$root/secrets/private.md"
  printf '# Secret file\nsecretfiledenycanary\n' > "$root/secret.md"
  printf '# Generated\ngenerateddenycanary\n' > "$root/generated/feedback.md"
  printf '# Vendor\nvendordenycanary\n' > "$root/vendor/package.md"
  printf '# Build\nbuilddenycanary\n' > "$root/build/output.md"
  printf '# Backlog\nbacklogdenycanary\n' > "$root/data/backlog.md"
  printf '# Captain\ncaptainfiledenycanary\n' > "$root/data/captain.md"
  printf '# Brief\nbriefdenycanary\n' > "$root/data/task/brief.md"
  printf '# Feedback\nfeedbackdirdenycanary\n' > "$root/feedback/note.md"
}

init_repo() {
  local root=$1
  git -C "$root" init -q
  git -C "$root" add .
  git -C "$root" -c user.name='Synthetic Test' -c user.email='synthetic@example.invalid' \
    commit -qm initial
}

setup_fixtures() {
  write_source "$PUBLIC" publiccanary public
  write_source "$REPO_A" repoacanary repo-private
  write_source "$REPO_B" repobcanary repo-private
  write_source "$FLEET" fleetcanary fleet-private
  write_source "$CAPTAIN" captaincanary captain-private
  init_repo "$REPO_A"
  init_repo "$REPO_B"
  printf '# Outside\nsymlinkescapecanary\n' > "$FIXTURES/outside.md"
  ln -s "$FIXTURES/outside.md" "$PUBLIC/records/escape.md"
  mkdir -p "$FIXTURES/outside-dir"
  printf '# Outside directory\nsymlinkdirescapecanary\n' > "$FIXTURES/outside-dir/escape.md"
  ln -s "$FIXTURES/outside-dir" "$PUBLIC/linked"
  write_registry
}

test_registry_validation_and_sync() {
  local validation source sync
  validation=$(run_cli validate --json)
  [ "$(printf '%s' "$validation" | jq -r '.schema')" = \
    fm-knowledge-index.registry-validation.v1 ] || fail "validation schema changed"
  [ "$(printf '%s' "$validation" | jq '.sources | length')" -eq 5 ] \
    || fail "validation did not report all synthetic sources"
  for source in public repo-a repo-b fleet captain; do
    sync=$(run_cli sync --source "$source" --json)
    [ "$(printf '%s' "$sync" | jq -r '.source')" = "$source" ] \
      || fail "sync reported the wrong source for $source"
    [ -f "$HOME_DIR/state/knowledge-indexes/$source.sqlite3" ] \
      || fail "sync did not publish $source database"
  done
  [ "$(mode_of "$HOME_DIR/state/knowledge-indexes")" = 700 ] \
    || fail "index directory is not owner-only"
  for source in public repo-a repo-b fleet captain; do
    [ "$(mode_of "$HOME_DIR/state/knowledge-indexes/$source.sqlite3")" = 600 ] \
      || fail "$source database is not owner-only"
  done
  [ "$(find "$HOME_DIR/state/knowledge-indexes" -name '*.sqlite3' -type f | wc -l | tr -d ' ')" -eq 5 ] \
    || fail "sources do not have one physical database each"
  pass "registry validation and owner-only per-source physical sync"
}

test_explicit_selection_and_retrieval() {
  local out exact prefix first second human
  if run_cli search --query sharedmarker --json >/dev/null 2>&1; then
    fail "search accepted a missing explicit source"
  fi
  if run_cli search --source all --query sharedmarker --json >/dev/null 2>&1; then
    fail "search accepted an all-sources selector"
  fi
  if run_cli search --source '*' --query sharedmarker --json >/dev/null 2>&1; then
    fail "search accepted a wildcard selector"
  fi
  exact=$(search_json repo-a exactterm)
  assert_result_count "$exact" 1 "exact retrieval failed"
  prefix=$(search_json repo-a prefixret)
  assert_result_count "$prefix" 1 "prefix retrieval failed"
  out=$(run_cli search --source repo-b --source public --query sharedmarker --json)
  [ "$(printf '%s' "$out" | jq -r '.sources | join(",")')" = 'repo-b,public' ] \
    || fail "explicit multi-source order changed"
  first=$(printf '%s' "$out" | jq -r '.results[0].source_id')
  second=$(printf '%s' "$out" | jq -r '.results[1].source_id')
  [ "$first,$second" = 'repo-b,public' ] \
    || fail "explicit multi-source results were not independently ordered"
  if run_cli search --source repo-a --source repo-a --query sharedmarker --json >/dev/null 2>&1; then
    fail "search accepted a duplicate explicit source"
  fi
  human=$(run_cli search --source repo-a --query repoacanary)
  assert_contains "$human" '[repo-a] records/shared.md' \
    "human search output omitted selected source and path"
  assert_contains "$human" 'sha256=' \
    "human search output omitted provenance"
  pass "explicit-only exact and prefix retrieval"
}

test_zero_foreign_source_leakage_and_provenance() {
  local source canary foreign foreign_prefix out repeated
  local -a sources=(public repo-a repo-b fleet captain)
  local -a canaries=(publiccanary repoacanary repobcanary fleetcanary captaincanary)
  local -a canary_prefixes=(publicc repoac repobc fleetc captainc)
  local i j
  for ((i=0; i<${#sources[@]}; i++)); do
    source=${sources[$i]}
    canary=${canaries[$i]}
    out=$(search_json "$source" "$canary")
    assert_result_count "$out" 1 "$source did not retrieve its own canary"
    [ "$(printf '%s' "$out" | jq -r '.results[0].source_id')" = "$source" ] \
      || fail "$source result carried foreign provenance"
    [ "$(printf '%s' "$out" | jq -r '.results[0].owner | length > 0')" = true ] \
      || fail "$source result omitted owner provenance"
    [ "$(printf '%s' "$out" | jq -r '.results[0].privacy_class | length > 0')" = true ] \
      || fail "$source result omitted privacy provenance"
    [ "$(printf '%s' "$out" | jq -r '.results[0].source_root | length > 0')" = true ] \
      || fail "$source result omitted source root provenance"
    [ "$(printf '%s' "$out" | jq -r '.results[0].relative_path')" = records/shared.md ] \
      || fail "$source result omitted the canonical relative path"
    [ "$(printf '%s' "$out" | jq -r '.results[0].content_sha256 | test("^[0-9a-f]{64}$")')" = true ] \
      || fail "$source result omitted content SHA-256"
    [ "$(printf '%s' "$out" | jq -r '.results[0].indexed_at | length > 0')" = true ] \
      || fail "$source result omitted indexed timestamp"
    for ((j=0; j<${#sources[@]}; j++)); do
      [ "$i" -eq "$j" ] && continue
      foreign=${canaries[$j]}
      foreign_prefix=${canary_prefixes[$j]}
      out=$(search_json "$source" "$foreign")
      assert_result_count "$out" 0 "$source leaked foreign canary $foreign"
      out=$(search_json "$source" "$foreign_prefix")
      assert_result_count "$out" 0 "$source leaked foreign canary prefix $foreign_prefix"
      out=$(search_json "$source" "$foreign\" OR $canary")
      assert_result_count "$out" 0 "$source leaked foreign canary through metacharacters"
      out=$(search_json "$source" "$foreign_prefix\" OR $canary")
      assert_result_count "$out" 0 "$source leaked foreign canary prefix through metacharacters"
    done
  done
  out=$(search_json repo-a repoacanary)
  [ "$(printf '%s' "$out" | jq -r '.results[0].repo_identity')" = synthetic/repo-a ] \
    || fail "repo identity provenance missing"
  [ "$(printf '%s' "$out" | jq -r '.results[0].commit_sha | test("^[0-9a-f]{40,64}$")')" = true ] \
    || fail "full commit provenance missing"
  repeated=$(search_json repo-a repoacanary)
  [ "$out" = "$repeated" ] || fail "unchanged JSON search output is not deterministic"
  pass "zero foreign canary leakage and complete result provenance"
}

test_allow_deny_and_symlink_safety() {
  local token out
  for token in configureddenycanary envdenycanary secretdirdenycanary secretfiledenycanary generateddenycanary \
    vendordenycanary builddenycanary backlogdenycanary captainfiledenycanary \
    briefdenycanary feedbackdirdenycanary symlinkescapecanary symlinkdirescapecanary; do
    out=$(search_json public "$token")
    assert_result_count "$out" 0 "denied or symlinked token leaked: $token"
  done
  [ "$(sqlite3 "$HOME_DIR/state/knowledge-indexes/public.sqlite3" \
    'SELECT count(*) FROM documents;')" -eq 1 ] \
    || fail "allowlist or denies admitted extra public documents"
  pass "configured and non-disableable built-in denies plus symlink escape safety"
}

test_same_slug_isolation_and_idempotency() {
  local source before after count hash
  hash=""
  for source in public repo-a repo-b fleet captain; do
    count=$(sqlite3 "$HOME_DIR/state/knowledge-indexes/$source.sqlite3" \
      "SELECT count(*) FROM documents WHERE relative_path = 'records/shared.md';")
    [ "$count" -eq 1 ] || fail "$source lost its isolated same-slug record"
    before=$(sqlite3 "$HOME_DIR/state/knowledge-indexes/$source.sqlite3" \
      "SELECT content_sha256 FROM documents WHERE relative_path = 'records/shared.md';")
    [ "$before" != "$hash" ] || fail "same-slug content collided across physical sources"
    hash=$before
  done
  before=$(sqlite3 "$HOME_DIR/state/knowledge-indexes/repo-a.sqlite3" \
    'SELECT count(*) FROM documents;')
  run_cli sync --source repo-a --json >/dev/null
  after=$(sqlite3 "$HOME_DIR/state/knowledge-indexes/repo-a.sqlite3" \
    'SELECT count(*) FROM documents;')
  [ "$before" -eq "$after" ] || fail "unchanged sync created duplicate records"
  [ "$(sqlite3 "$HOME_DIR/state/knowledge-indexes/repo-a.sqlite3" \
    'SELECT count(*) = count(DISTINCT relative_path) FROM documents;')" -eq 1 ] \
    || fail "relative paths are not unique after unchanged sync"
  pass "same-slug physical isolation and idempotent unchanged sync"
}

test_sql_fts_metacharacter_safety() {
  local out status
  out=$(search_json repo-a 'repoacanary" OR fleetcanary; DROP TABLE documents; --')
  assert_result_count "$out" 0 "FTS metacharacters changed query scope"
  out=$(search_json repo-a "x'); ATTACH DATABASE 'foreign' AS leak; --")
  assert_result_count "$out" 0 "SQL metacharacters escaped the fixed query"
  out=$(search_json repo-a '[')
  assert_result_count "$out" 0 "malformed FTS punctuation was unsafe"
  status=$(run_cli status --source repo-a --json)
  [ "$(printf '%s' "$status" | jq '.documents')" -ge 1 ] \
    || fail "metacharacter query damaged the selected index"
  [ -f "$HOME_DIR/state/knowledge-indexes/fleet.sqlite3" ] \
    || fail "metacharacter query damaged a foreign index"
  pass "parameterized SQL and safe FTS metacharacter handling"
}

test_atomic_failure_preserves_previous_index() {
  local db before after old new
  db="$HOME_DIR/state/knowledge-indexes/repo-a.sqlite3"
  before=$(sha_of "$db")
  printf '\nnewatomiccanary\n' >> "$REPO_A/records/shared.md"
  if FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_TEST_FAIL_BEFORE_PUBLISH=1 \
    "$CLI" sync --source repo-a --json >/dev/null 2>&1; then
    fail "injected pre-publish sync failure unexpectedly succeeded"
  fi
  after=$(sha_of "$db")
  [ "$before" = "$after" ] || fail "failed sync changed the previous database"
  old=$(search_json repo-a repoacanary)
  assert_result_count "$old" 1 "previous index became unusable after failed sync"
  new=$(search_json repo-a newatomiccanary)
  assert_result_count "$new" 0 "failed sync published new content"
  [ "$(find "$HOME_DIR/state/knowledge-indexes" -name '.repo-a.sqlite3.tmp.*' | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "failed sync left unpublished database files"
  run_cli sync --source repo-a --json >/dev/null
  new=$(search_json repo-a newatomiccanary)
  assert_result_count "$new" 1 "successful retry did not publish new content"
  pass "atomic failed-sync preservation and successful retry"
}

test_deletion_and_rename_propagation() {
  local out
  mv "$REPO_A/records/shared.md" "$REPO_A/records/renamed.md"
  run_cli sync --source repo-a --json >/dev/null
  [ "$(sqlite3 "$HOME_DIR/state/knowledge-indexes/repo-a.sqlite3" \
    "SELECT count(*) FROM documents WHERE relative_path = 'records/shared.md';")" -eq 0 ] \
    || fail "rename left a ghost path"
  out=$(search_json repo-a repoacanary)
  [ "$(printf '%s' "$out" | jq -r '.results[0].relative_path')" = records/renamed.md ] \
    || fail "renamed file did not replace the old projection"
  mv "$REPO_A/records/renamed.md" "$REPO_A/records/excluded.txt"
  run_cli sync --source repo-a --json >/dev/null
  out=$(search_json repo-a repoacanary)
  assert_result_count "$out" 0 "file moved out of the Markdown allowlist left a ghost result"
  mv "$REPO_A/records/excluded.txt" "$REPO_A/records/renamed.md"
  run_cli sync --source repo-a --json >/dev/null
  out=$(search_json repo-a repoacanary)
  assert_result_count "$out" 1 "file restored to the allowlist did not return"
  rm "$REPO_A/records/renamed.md"
  run_cli sync --source repo-a --json >/dev/null
  out=$(search_json repo-a repoacanary)
  assert_result_count "$out" 0 "canonical deletion left a ghost result"
  pass "deterministic sync deletion and rename propagation"
}

test_safe_source_removal() {
  local before_registry out
  before_registry=$(sha_of "$REGISTRY")
  if run_cli remove --source repo-b --confirm wrong --json >/dev/null 2>&1; then
    fail "source removal accepted the wrong confirmation"
  fi
  [ -f "$HOME_DIR/state/knowledge-indexes/repo-b.sqlite3" ] \
    || fail "failed confirmation removed the index"
  out=$(run_cli remove --source repo-b --confirm repo-b --json)
  [ "$(printf '%s' "$out" | jq -r '.removed')" = true ] \
    || fail "confirmed source removal did not report success"
  [ ! -e "$HOME_DIR/state/knowledge-indexes/repo-b.sqlite3" ] \
    || fail "confirmed source removal left the database"
  [ -d "$REPO_B" ] || fail "source removal changed the canonical root"
  [ "$before_registry" = "$(sha_of "$REGISTRY")" ] \
    || fail "source removal changed the registry"
  [ -f "$HOME_DIR/state/knowledge-indexes/public.sqlite3" ] \
    || fail "source removal changed a foreign database"
  if search_json repo-b repobcanary >/dev/null 2>&1; then
    fail "removed source still returned a ghost result"
  fi
  pass "fail-closed exact-source disposable index removal"
}

test_sync_remove_source_coordination() {
  local gate="$TMP_ROOT/repo-b-sync-remove" sync_pid remove_pid remove_out
  run_cli sync --source repo-b --json >/dev/null
  printf '\ncoordinationcanary\n' >> "$REPO_B/records/shared.md"
  FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_LOCKED_SOURCE=repo-b \
    FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_PUBLISH="$gate" \
    "$CLI" sync --source repo-b --json > "$TMP_ROOT/repo-b-sync.out" 2> "$TMP_ROOT/repo-b-sync.err" &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "sync exited before reaching the publication gate"
    sleep 0.01
  done
  run_cli remove --source repo-b --confirm repo-b --json > "$TMP_ROOT/repo-b-remove.out" &
  remove_pid=$!
  sleep 0.1
  kill -0 "$remove_pid" 2>/dev/null \
    || fail "same-source remove returned while an earlier sync could still publish"
  : > "$gate.release"
  wait "$sync_pid" || fail "coordinated sync failed"
  wait "$remove_pid" || fail "coordinated remove failed"
  remove_out=$(cat "$TMP_ROOT/repo-b-remove.out")
  [ "$(printf '%s' "$remove_out" | jq -r '.removed')" = true ] \
    || fail "coordinated source removal did not remove the published index"
  [ ! -e "$HOME_DIR/state/knowledge-indexes/repo-b.sqlite3" ] \
    || fail "an earlier same-source sync republished after remove returned"
  pass "source-scoped sync and remove coordination"
}

test_source_operation_lock_rejects_symlink() {
  local lock_dir="$HOME_DIR/state/knowledge-indexes"
  local lock_path="$lock_dir/.repo-b.operation.lock"
  local foreign_lock="$TMP_ROOT/foreign-operation.lock" out
  rm -f "$lock_path"
  : > "$foreign_lock"
  ln -s "$foreign_lock" "$lock_path"
  out=$(run_cli sync --source repo-b --json 2>&1) \
    || fail "replaceable legacy lock path blocked directory coordination"
  [ ! -s "$foreign_lock" ] || fail "source operation wrote through a symlink lock"
  rm "$lock_path"
  pass "source operation coordination ignores replaceable pathname locks"
}

test_bash_32_parse_compatibility() {
  /bin/bash -n "$CLI" || fail "knowledge index CLI does not parse with system Bash"
  pass "knowledge index CLI retains system Bash parse compatibility"
}

test_forged_index_directory_fd_is_rejected() {
  local index_dir="$HOME_DIR/state/knowledge-indexes" out before after forged_work
  mkdir -p "$index_dir"
  exec 9< "$index_dir"
  if out=$(FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_DIR_FD=9 \
    "$CLI" sync --source repo-b --json 2>&1); then
    exec 9<&-
    fail "sync accepted a forged index directory descriptor"
  fi
  exec 9<&-
  assert_contains "$out" 'refusing unverified index supervisor environment' \
    "forged index directory descriptor failure was not reported"
  run_cli sync --source repo-a --json >/dev/null
  before=$(sha_of "$index_dir/repo-a.sqlite3")
  forged_work="$TMP_ROOT/forged-supervisor-work"
  mkdir -p "$forged_work"
  python3 - "$CLI" "$HOME_DIR" "$index_dir" "$forged_work" <<'PY'
import os
import subprocess
import sys

script, home, index, work = sys.argv[1:]
directory_fd = os.open(index, os.O_RDONLY | os.O_DIRECTORY)
control_read, control_write = os.pipe()
environment = os.environ.copy()
environment.update({
    "FM_HOME": home,
    "FM_KNOWLEDGE_INDEX_DIR_FD": str(directory_fd),
    "FM_KNOWLEDGE_INDEX_CONTROL_FD": str(control_read),
    "FM_KNOWLEDGE_INDEX_SUPERVISED": "1",
    "FM_KNOWLEDGE_INDEX_SUPERVISOR_PID": str(os.getpid()),
})
completed = subprocess.run(
    [script, "sync", "--source", "repo-a", "--json"],
    cwd=work,
    env=environment,
    pass_fds=(directory_fd, control_read),
    stdout=subprocess.PIPE,
    check=False,
)
os.close(control_read)
os.close(control_write)
os.close(directory_fd)
if completed.stdout:
    raise SystemExit("forged wrapper received caller-visible success output")
PY
  after=$(sha_of "$index_dir/repo-a.sqlite3")
  [ "$after" = "$before" ] || fail "forged supervisor wrapper published a database"
  [ ! -e "$index_dir/.prepared-repo-a.sqlite3" ] \
    || fail "forged supervisor wrapper wrote a prepared database into the index"
  pass "forged supervisor environment has no commit or output authority"
}

test_index_locator_environment_is_ignored() {
  local outside="$TMP_ROOT/outside-indexes" out
  mkdir -p "$outside"
  INDEX_LOCATOR="$outside" FM_HOME="$HOME_DIR" \
    "$CLI" sync --source repo-a --json >/dev/null
  [ ! -e "$outside/repo-a.sqlite3" ] \
    || fail "caller INDEX_LOCATOR redirected index storage"
  out=$(INDEX_LOCATOR="$outside" FM_HOME="$HOME_DIR" \
    "$CLI" status --source repo-a --json)
  [ "$(printf '%s' "$out" | jq -r '.database')" = "$HOME_DIR/state/knowledge-indexes/repo-a.sqlite3" ] \
    || fail "caller INDEX_LOCATOR changed database provenance"
  pass "index locator is derived from the selected state area"
}

test_relative_home_resolves_from_invocation_directory() {
  local relative_parent="$TMP_ROOT/relative-parent" relative_home="home" source_root
  local out
  source_root="$FIXTURES/public"
  mkdir -p "$relative_parent/$relative_home/config"
  jq -n --arg root "$source_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"relative",root:$root,owner:"Relative Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$relative_parent/$relative_home/config/knowledge-sources.json"
  (
    cd "$relative_parent"
    FM_HOME="$relative_home" "$CLI" sync --source relative --json >/dev/null
  )
  out=$(
    cd "$relative_parent"
    FM_HOME="$relative_home" "$CLI" status --source relative --json
  )
  [ "$(printf '%s' "$out" | jq -r '.database')" = "$relative_parent/$relative_home/state/knowledge-indexes/relative.sqlite3" ] \
    || fail "relative FM_HOME resolved against the supervised child directory"
  pass "relative Firstmate home remains bound to the invocation directory"
}

test_registry_path_traversal_and_root_rejection() {
  local invalid_home="$TMP_ROOT/invalid-home" invalid_registry="$TMP_ROOT/invalid-home/config/knowledge-sources.json"
  mkdir -p "$invalid_home/config"
  jq -n --arg first "$PUBLIC" --arg second "$FLEET" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"duplicate",root:$first,owner:"Owner A",privacy:"public",markdown_allow:["*.md"],deny:[]},
      {id:"duplicate",root:$second,owner:"Owner B",privacy:"fleet-private",markdown_allow:["*.md"],deny:[]}
    ]}' > "$invalid_registry"
  if FM_HOME="$invalid_home" "$CLI" validate --json >/dev/null 2>&1; then
    fail "registry accepted colliding source IDs"
  fi
  jq -n --arg root "$PUBLIC" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[{id:"../escape",root:$root,owner:"Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}]}' \
    > "$invalid_registry"
  if FM_HOME="$invalid_home" "$CLI" validate --json >/dev/null 2>&1; then
    fail "registry accepted a traversal source id"
  fi
  jq -n --arg root "$PUBLIC" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[{id:"safe",root:$root,owner:"Owner",privacy:"public",markdown_allow:["../*.md"],deny:[]}]}' \
    > "$invalid_registry"
  if FM_HOME="$invalid_home" "$CLI" validate --json >/dev/null 2>&1; then
    fail "registry accepted a traversal allowlist"
  fi
  jq -n --arg root "$FIXTURES/../fixtures/public" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[{id:"safe",root:$root,owner:"Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}]}' \
    > "$invalid_registry"
  if FM_HOME="$invalid_home" "$CLI" validate --json >/dev/null 2>&1; then
    fail "registry accepted a non-canonical root"
  fi
  ln -s "$PUBLIC" "$FIXTURES/public-root-link"
  jq -n --arg root "$FIXTURES/public-root-link" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[{id:"safe",root:$root,owner:"Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}]}' \
    > "$invalid_registry"
  if FM_HOME="$invalid_home" "$CLI" validate --json >/dev/null 2>&1; then
    fail "registry accepted a symlinked canonical root"
  fi
  mkdir -p "$PUBLIC/nested-private"
  printf '# Nested private\nnestedprivatecanary\n' > "$PUBLIC/nested-private/private.md"
  jq -n --arg outer "$PUBLIC" --arg inner "$PUBLIC/nested-private" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"outer-public",root:$outer,owner:"Public Owner",privacy:"public",markdown_allow:["*.md"],deny:[]},
      {id:"inner-private",root:$inner,owner:"Private Owner",privacy:"captain-private",markdown_allow:["*.md"],deny:[]}
    ]}' > "$invalid_registry"
  if FM_HOME="$invalid_home" "$CLI" validate --json >/dev/null 2>&1; then
    fail "registry accepted an outer source containing a private source root"
  fi
  if FM_HOME="$invalid_home" "$CLI" sync --source outer-public --json >/dev/null 2>&1; then
    fail "sync accepted an outer source containing a private source root"
  fi
  [ ! -e "$invalid_home/state/knowledge-indexes/outer-public.sqlite3" ] \
    || fail "overlapping outer source indexed nestedprivatecanary"
  jq -n --arg outer "$PUBLIC" --arg inner "$PUBLIC/nested-private" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"inner-private",root:$inner,owner:"Private Owner",privacy:"captain-private",markdown_allow:["*.md"],deny:[]},
      {id:"outer-public",root:$outer,owner:"Public Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$invalid_registry"
  if FM_HOME="$invalid_home" "$CLI" validate --json >/dev/null 2>&1; then
    fail "registry accepted a private source nested inside a later outer source"
  fi
  if FM_HOME="$invalid_home" "$CLI" sync --source outer-public --json >/dev/null 2>&1; then
    fail "sync accepted a later outer source containing a private source root"
  fi
  [ ! -e "$invalid_home/state/knowledge-indexes/outer-public.sqlite3" ] \
    || fail "later overlapping outer source indexed nestedprivatecanary"
  ln -s "$PUBLIC/nested-private" "$FIXTURES/nested-private-alias"
  jq -n --arg outer "$PUBLIC" --arg alias "$FIXTURES/nested-private-alias" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"outer-public",root:$outer,owner:"Public Owner",privacy:"public",markdown_allow:["*.md"],deny:[]},
      {id:"aliased-private",root:$alias,owner:"Private Owner",privacy:"captain-private",markdown_allow:["*.md"],deny:[]}
    ]}' > "$invalid_registry"
  if FM_HOME="$invalid_home" "$CLI" sync --source outer-public --json >/dev/null 2>&1; then
    fail "sync accepted a foreign source aliased inside the selected root"
  fi
  [ ! -e "$invalid_home/state/knowledge-indexes/outer-public.sqlite3" ] \
    || fail "aliased private source leaked nestedprivatecanary into the outer index"
  rm "$FIXTURES/nested-private-alias"
  rm -rf "$PUBLIC/nested-private"
  pass "source ID, pattern, root traversal, and symlink-root rejection"
}

test_directory_replacement_does_not_escape_root() {
  local race_home="$TMP_ROOT/race-home" race_root="$FIXTURES/race-root"
  local outside="$FIXTURES/race-outside" gate="$TMP_ROOT/race-snapshot" sync_pid
  mkdir -p "$race_home/config" "$race_root/records" "$outside"
  printf '# Safe\nsafesnapshotcanary\n' > "$race_root/records/race.md"
  printf '# Foreign\nraceforeigncanary\n' > "$outside/race.md"
  jq -n --arg root "$race_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"race",root:$root,owner:"Race Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$race_home/config/knowledge-sources.json"
  FM_HOME="$race_home" FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_SNAPSHOT="$gate" \
    "$CLI" sync --source race --json > "$TMP_ROOT/race-sync.out" 2> "$TMP_ROOT/race-sync.err" &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "race sync exited before reaching the snapshot gate"
    sleep 0.01
  done
  mv "$race_root/records" "$race_root/records-original"
  ln -s "$outside" "$race_root/records"
  : > "$gate.release"
  if wait "$sync_pid"; then
    fail "sync followed a replaced intermediate directory outside its source root"
  fi
  [ ! -e "$race_home/state/knowledge-indexes/race.sqlite3" ] \
    || fail "failed race sync published an index"
  assert_contains "$(cat "$TMP_ROOT/race-sync.out")" 'cannot safely snapshot source tree' \
    "race sync did not report a safe snapshot failure"
  pass "root-bound snapshot rejects concurrent intermediate-directory replacement"
}

test_root_replacement_rejects_stale_provenance() {
  local race_home="$TMP_ROOT/root-race-home" race_parent="$FIXTURES/root-race-parent"
  local race_root="$race_parent/source" outside="$FIXTURES/root-race-outside"
  local gate="$TMP_ROOT/root-race-publish" sync_pid before_sha after_sha out
  mkdir -p "$race_home/config" "$race_root/records" "$outside/records"
  printf '# Safe\nrootboundsafecanary\n' > "$race_root/records/race.md"
  printf '# Foreign\nrootboundforeigncanary\n' > "$outside/records/race.md"
  jq -n --arg root "$race_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"root-race",root:$root,owner:"Race Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$race_home/config/knowledge-sources.json"
  FM_HOME="$race_home" "$CLI" sync --source root-race --json >/dev/null
  before_sha=$(sha_of "$race_home/state/knowledge-indexes/root-race.sqlite3")
  printf '# Updated safe\nrootboundupdatedcanary\n' > "$race_root/records/race.md"
  FM_HOME="$race_home" FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_PUBLISH="$gate" \
    "$CLI" sync --source root-race --json > "$TMP_ROOT/root-race-sync.out" 2> "$TMP_ROOT/root-race-sync.err" &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "root race sync exited before reaching the snapshot gate"
    sleep 0.01
  done
  mv "$race_parent" "$FIXTURES/root-race-parent-original"
  mkdir -p "$race_parent"
  cp -R "$outside" "$race_root"
  : > "$gate.release"
  if wait "$sync_pid"; then
    fail "sync published provenance for a replaced registered root"
  fi
  after_sha=$(sha_of "$race_home/state/knowledge-indexes/root-race.sqlite3")
  [ "$after_sha" = "$before_sha" ] \
    || fail "root replacement changed the previous database"
  out=$(FM_HOME="$race_home" "$CLI" search --source root-race --query rootboundsafecanary --json)
  assert_result_count "$out" 1 "root-bound sync lost content from the opened root"
  out=$(FM_HOME="$race_home" "$CLI" search --source root-race --query rootboundupdatedcanary --json)
  assert_result_count "$out" 0 "failed root replacement sync published stale provenance"
  out=$(FM_HOME="$race_home" "$CLI" search --source root-race --query rootboundforeigncanary --json)
  assert_result_count "$out" 0 "root replacement redirected reads to foreign content"
  assert_contains "$(cat "$TMP_ROOT/root-race-sync.out")" 'source root changed before publishing' \
    "root replacement did not report a pre-publish identity failure"
  pass "root replacement rejects stale provenance and preserves the previous index"
}

test_commit_provenance_uses_opened_root() {
  local race_home="$TMP_ROOT/commit-race-home" race_parent="$FIXTURES/commit-race-parent"
  local race_root="$race_parent/source" replacement="$FIXTURES/commit-race-replacement"
  local gate="$TMP_ROOT/commit-race-snapshot" sync_pid before_sha after_sha original_commit
  mkdir -p "$race_home/config" "$race_root/records" "$replacement/records"
  printf '# Original\ncommitrootoriginalcanary\n' > "$race_root/records/race.md"
  git -C "$race_root" init -q
  git -C "$race_root" add records/race.md
  git -C "$race_root" -c user.name=Test -c user.email=test@example.invalid commit -qm original
  original_commit=$(git -C "$race_root" rev-parse HEAD)
  printf '# Replacement\ncommitrootreplacementcanary\n' > "$replacement/records/race.md"
  git -C "$replacement" init -q
  git -C "$replacement" add records/race.md
  git -C "$replacement" -c user.name=Test -c user.email=test@example.invalid commit -qm replacement
  jq -n --arg root "$race_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"commit-race",root:$root,owner:"Race Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$race_home/config/knowledge-sources.json"
  FM_HOME="$race_home" "$CLI" sync --source commit-race --json >/dev/null
  before_sha=$(sha_of "$race_home/state/knowledge-indexes/commit-race.sqlite3")
  FM_HOME="$race_home" FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_SNAPSHOT="$gate" \
    "$CLI" sync --source commit-race --json > "$TMP_ROOT/commit-race-sync.out" 2>&1 &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "commit race sync exited before reaching the snapshot gate"
    sleep 0.01
  done
  mv "$race_parent" "$FIXTURES/commit-race-parent-original"
  mkdir -p "$race_parent"
  cp -R "$replacement" "$race_root"
  : > "$gate.release"
  if wait "$sync_pid"; then
    fail "commit race published after replacing the opened root"
  fi
  after_sha=$(sha_of "$race_home/state/knowledge-indexes/commit-race.sqlite3")
  [ "$after_sha" = "$before_sha" ] || fail "commit race changed the previous database"
  [ "$(sqlite3 -readonly "$race_home/state/knowledge-indexes/commit-race.sqlite3" \
    "SELECT value FROM metadata WHERE key = 'commit_sha';")" = "$original_commit" ] \
    || fail "commit provenance did not come from the opened source root"
  pass "commit provenance stays bound to the opened source root"
}

test_commit_provenance_ignores_git_environment_routing() {
  local routed_home="$TMP_ROOT/git-routing-home" source_root="$FIXTURES/git-routing-source"
  local outside_root="$FIXTURES/git-routing-outside" source_commit outside_commit out
  mkdir -p "$routed_home/config" "$source_root/records" "$outside_root"
  printf '# Source\ngitroutingsourcecanary\n' > "$source_root/records/source.md"
  printf '# Outside\ngitroutingoutsidecanary\n' > "$outside_root/outside.md"
  init_repo "$source_root"
  init_repo "$outside_root"
  source_commit=$(git -C "$source_root" rev-parse HEAD)
  outside_commit=$(git -C "$outside_root" rev-parse HEAD)
  [ "$source_commit" != "$outside_commit" ] || fail "synthetic routing commits unexpectedly match"
  jq -n --arg root "$source_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"git-routing",root:$root,owner:"Routing Owner",privacy:"repo-private",markdown_allow:["*.md"],deny:[]}
    ]}' > "$routed_home/config/knowledge-sources.json"
  GIT_DIR="$outside_root/.git" GIT_WORK_TREE="$outside_root" \
    GIT_COMMON_DIR="$outside_root/.git" GIT_INDEX_FILE="$outside_root/.git/index" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    FM_HOME="$routed_home" "$CLI" sync --source git-routing --json >/dev/null
  out=$(FM_HOME="$routed_home" "$CLI" search --source git-routing --query gitroutingsourcecanary --json)
  assert_result_count "$out" 1 "Git routing environment changed indexed source content"
  [ "$(printf '%s' "$out" | jq -r '.results[0].commit_sha')" = "$source_commit" ] \
    || fail "Git routing environment forged commit provenance"
  [ "$(printf '%s' "$out" | jq -r '.results[0].source_root')" = "$source_root" ] \
    || fail "Git routing environment changed source-root provenance"
  out=$(FM_HOME="$routed_home" "$CLI" search --source git-routing --query gitroutingoutsidecanary --json)
  assert_result_count "$out" 0 "Git routing environment leaked outside repository content"
  pass "commit provenance ignores caller Git repository routing"
}

test_registry_replacement_preserves_previous_index() {
  local race_home="$TMP_ROOT/registry-race-home" source_root="$FIXTURES/registry-race-source"
  local foreign_root="$FIXTURES/registry-race-foreign" gate="$TMP_ROOT/registry-race-publish"
  local sync_pid before_sha after_sha out replacement
  mkdir -p "$race_home/config" "$source_root/records" "$foreign_root/records"
  printf '# Original\nregistryoriginalcanary\n' > "$source_root/records/source.md"
  printf '# Foreign\nregistryforeigncanary\n' > "$foreign_root/records/foreign.md"
  jq -n --arg root "$source_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"registry-race",root:$root,owner:"Original Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$race_home/config/knowledge-sources.json"
  FM_HOME="$race_home" "$CLI" sync --source registry-race --json >/dev/null
  before_sha=$(sha_of "$race_home/state/knowledge-indexes/registry-race.sqlite3")
  printf '# Updated\nregistryupdatedcanary\n' > "$source_root/records/source.md"
  FM_HOME="$race_home" FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_PUBLISH="$gate" \
    "$CLI" sync --source registry-race --json > "$TMP_ROOT/registry-race-sync.out" 2>&1 &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "registry race sync exited before the publish gate"
    sleep 0.01
  done
  replacement="$race_home/config/knowledge-sources.replacement.json"
  jq -n --arg root "$foreign_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"registry-race",root:$root,owner:"Foreign Owner",privacy:"captain-private",markdown_allow:["records/*.md"],deny:[]}
    ]}' > "$replacement"
  mv "$replacement" "$race_home/config/knowledge-sources.json"
  : > "$gate.release"
  if wait "$sync_pid"; then
    fail "sync published after atomic registry replacement"
  fi
  after_sha=$(sha_of "$race_home/state/knowledge-indexes/registry-race.sqlite3")
  [ "$after_sha" = "$before_sha" ] || fail "registry replacement changed the previous database"
  out=$(FM_HOME="$race_home" "$CLI" search --source registry-race --query registryoriginalcanary --json)
  assert_result_count "$out" 1 "registry replacement lost the previous index"
  [ "$(printf '%s' "$out" | jq -r '.results[0].owner')" = "Original Owner" ] \
    || fail "registry replacement mixed owner provenance into the previous index"
  out=$(FM_HOME="$race_home" "$CLI" search --source registry-race --query registryforeigncanary --json)
  assert_result_count "$out" 0 "registry replacement leaked foreign source content"
  assert_contains "$(cat "$TMP_ROOT/registry-race-sync.out")" 'registry changed before publishing' \
    "registry replacement did not report a pre-publish failure"
  pass "sync binds validation and provenance to one registry snapshot"
}

test_bare_repository_has_no_commit_provenance() {
  local bare_home="$TMP_ROOT/bare-home" bare_root="$FIXTURES/bare-source" out
  mkdir -p "$bare_home/config"
  git init --bare -q "$bare_root"
  printf '# Bare\nbarecommitcanary\n' > "$bare_root/README.md"
  jq -n --arg root "$bare_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"bare",root:$root,owner:"Bare Owner",privacy:"repo-private",markdown_allow:["*.md"],deny:[]}
    ]}' > "$bare_home/config/knowledge-sources.json"
  FM_HOME="$bare_home" "$CLI" sync --source bare --json >/dev/null
  out=$(FM_HOME="$bare_home" "$CLI" search --source bare --query barecommitcanary --json)
  assert_result_count "$out" 1 "bare repository fixture was not indexed"
  [ "$(printf '%s' "$out" | jq -r '.results[0].commit_sha')" = null ] \
    || fail "bare repository incorrectly reported commit provenance"
  pass "bare repositories do not report worktree commit provenance"
}

test_post_verify_replacement_fails_closed() {
  local race_home="$TMP_ROOT/publish-race-home" race_parent="$FIXTURES/publish-race-parent"
  local race_root="$race_parent/source"
  local gate="$TMP_ROOT/publish-race-verified" sync_pid index_dir
  local registry
  mkdir -p "$race_home/config" "$race_root/records"
  printf '# Original\npublishidentityoriginalcanary\n' > "$race_root/records/race.md"
  registry="$race_home/config/knowledge-sources.json"
  jq -n --arg root "$race_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"publish-race",root:$root,owner:"Race Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$registry"
  FM_HOME="$race_home" FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_PUBLICATION_VERIFY="$gate" \
    "$CLI" sync --source publish-race --json > "$TMP_ROOT/publish-race-sync.out" 2>&1 &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "publish race sync exited before identity verification"
    sleep 0.01
  done
  index_dir="$race_home/state/knowledge-indexes"
  mv "$index_dir" "$race_home/state/knowledge-indexes.detached"
  mkdir -m 700 "$index_dir"
  : > "$gate.release"
  if wait "$sync_pid"; then
    fail "sync published after its source and index locator were replaced"
  fi
  [ ! -e "$race_home/state/knowledge-indexes/publish-race.sqlite3" ] \
    || fail "failed locator race published a database"
  [ ! -e "$race_home/state/knowledge-indexes.detached/publish-race.sqlite3" ] \
    || fail "failed locator race published into the detached index directory"
  pass "publication fails closed after locator replacement"
}

test_remove_replacement_preserves_replacement_database() {
  local gate="$TMP_ROOT/remove-race" db="$HOME_DIR/state/knowledge-indexes/repo-a.sqlite3"
  local original="$TMP_ROOT/repo-a-original.sqlite3" remove_pid replacement_sha
  run_cli sync --source repo-a --json >/dev/null
  FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_REMOVE_VERIFY="$gate" \
    "$CLI" remove --source repo-a --confirm repo-a --json > "$TMP_ROOT/remove-race.out" 2>&1 &
  remove_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$remove_pid" 2>/dev/null || fail "remove exited before pathname replacement gate"
    sleep 0.01
  done
  mv "$db" "$original"
  cp "$original" "$db"
  replacement_sha=$(sha_of "$db")
  : > "$gate.release"
  if wait "$remove_pid"; then
    fail "remove accepted a database pathname replacement"
  fi
  [ -f "$db" ] || fail "remove deleted the replacement database"
  [ "$(sha_of "$db")" = "$replacement_sha" ] \
    || fail "remove changed the replacement database"
  pass "exact removal preserves a concurrently replaced database"
}

test_status_fails_closed_during_index_directory_replacement() {
  local gate="$TMP_ROOT/status-directory-race" index_dir="$HOME_DIR/state/knowledge-indexes"
  local detached="$HOME_DIR/state/knowledge-indexes.detached-status" status_pid
  run_cli sync --source fleet --json >/dev/null
  FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_DATABASE_OPEN="$gate" \
    "$CLI" status --source fleet --json > "$TMP_ROOT/status-directory-race.out" 2>&1 &
  status_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$status_pid" 2>/dev/null || fail "status exited before directory replacement gate"
    sleep 0.01
  done
  mv "$index_dir" "$detached"
  mkdir -m 700 "$index_dir"
  : > "$gate.release"
  if wait "$status_pid"; then
    fail "status reported success after index locator replacement"
  fi
  [ ! -s "$TMP_ROOT/status-directory-race.out" ] \
    || fail "status emitted a success payload before locator verification"
  [ -z "$(find "$index_dir" -mindepth 1 -print -quit)" ] \
    || fail "status wrote temporary data through the replacement locator"
  rmdir "$index_dir"
  mv "$detached" "$index_dir"
  pass "status fails closed after index locator replacement"
}

test_forged_supervised_mode_does_not_follow_output_symlink() {
  local work="$TMP_ROOT/forged-output-work" target="$TMP_ROOT/forged-output-target" out
  mkdir -p "$work"
  printf 'preserve-me\n' > "$target"
  ln -s "$target" "$work/.knowledge-worker-output"
  if out=$(cd "$work" && FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_SUPERVISED=1 \
    FM_KNOWLEDGE_INDEX_SUPERVISOR_PID=$$ "$CLI" status --source repo-a --json 2>&1); then
    fail "forged supervised mode was accepted"
  fi
  [ "$(cat "$target")" = preserve-me ] \
    || fail "forged supervised mode truncated a symlink target"
  assert_contains "$out" 'cannot verify index operation supervisor' \
    "forged supervised mode failure was not reported"
  pass "forged supervised mode cannot redirect worker output"
}

test_unsafe_source_is_rejected_before_supervisor_file_access() {
  local outside="$HOME_DIR/state/escape.sqlite3" before out
  printf 'outside-database-sentinel\n' > "$outside"
  before=$(sha_of "$outside")
  if out=$(FM_HOME="$HOME_DIR" "$CLI" status --source ../escape --json 2>&1); then
    fail "unsafe source id reached supervisor database handling"
  fi
  [ "$(sha_of "$outside")" = "$before" ] \
    || fail "unsafe source id changed an outside file"
  assert_contains "$out" 'invalid source id' \
    "unsafe source id was not rejected before supervisor access"
  pass "supervisor validates source IDs before database access"
}

test_supervisor_revalidates_provenance_and_state_before_commit() {
  local race_home="$TMP_ROOT/supervisor-race-home" source_root="$FIXTURES/supervisor-race-source"
  local gate="$TMP_ROOT/supervisor-commit" sync_pid replacement detached
  mkdir -p "$race_home/config" "$source_root"
  printf '# Supervisor\nsupervisorcommitcanary\n' > "$source_root/source.md"
  jq -n --arg root "$source_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"supervisor-race",root:$root,owner:"Supervisor Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$race_home/config/knowledge-sources.json"
  FM_HOME="$race_home" FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_SUPERVISOR_COMMIT="$gate" \
    "$CLI" sync --source supervisor-race --json > "$TMP_ROOT/supervisor-race.out" 2>&1 &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "sync exited before supervisor commit gate"
    sleep 0.01
  done
  replacement="$race_home/config/knowledge-sources.replacement.json"
  jq -n --arg root "$source_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"supervisor-race",root:$root,owner:"Replacement Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$replacement"
  mv "$replacement" "$race_home/config/knowledge-sources.json"
  detached="$race_home/state.detached"
  mv "$race_home/state" "$detached"
  mkdir -m 700 "$race_home/state"
  : > "$gate.release"
  if wait "$sync_pid"; then
    fail "supervisor committed after registry and state locator replacement"
  fi
  [ ! -e "$race_home/state/knowledge-indexes/supervisor-race.sqlite3" ] \
    || fail "supervisor published into the replacement state locator"
  [ ! -e "$detached/knowledge-indexes/supervisor-race.sqlite3" ] \
    || fail "supervisor published into the detached state locator"
  pass "supervisor revalidates provenance and state before commit"
}

test_supervisor_rolls_back_post_verify_provenance_change() {
  local race_home="$TMP_ROOT/supervisor-post-verify-home"
  local source_root="$FIXTURES/supervisor-post-verify-source"
  local gate="$TMP_ROOT/supervisor-post-verify" sync_pid replacement before after out
  mkdir -p "$race_home/config" "$source_root"
  printf '# Original\nsupervisororiginalcanary\n' > "$source_root/source.md"
  jq -n --arg root "$source_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"post-verify",root:$root,owner:"Original Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$race_home/config/knowledge-sources.json"
  FM_HOME="$race_home" "$CLI" sync --source post-verify --json >/dev/null
  before=$(sha_of "$race_home/state/knowledge-indexes/post-verify.sqlite3")
  printf '# Updated\nsupervisorupdatedcanary\n' > "$source_root/source.md"
  FM_HOME="$race_home" FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_SUPERVISOR_VERIFY="$gate" \
    "$CLI" sync --source post-verify --json > "$TMP_ROOT/supervisor-post-verify.out" 2>&1 &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "sync exited before post-verify supervisor gate"
    sleep 0.01
  done
  replacement="$race_home/config/knowledge-sources.replacement.json"
  jq -n --arg root "$source_root" \
    '{schema:"firstmate.knowledge-sources.v1",sources:[
      {id:"post-verify",root:$root,owner:"Replacement Owner",privacy:"public",markdown_allow:["*.md"],deny:[]}
    ]}' > "$replacement"
  mv "$replacement" "$race_home/config/knowledge-sources.json"
  : > "$gate.release"
  if wait "$sync_pid"; then
    fail "supervisor published after post-verification registry replacement"
  fi
  after=$(sha_of "$race_home/state/knowledge-indexes/post-verify.sqlite3")
  [ "$after" = "$before" ] || fail "post-verification race did not preserve the old database"
  out=$(FM_HOME="$race_home" "$CLI" search --source post-verify --query supervisororiginalcanary --json)
  assert_result_count "$out" 1 "post-verification rollback lost the old database"
  out=$(FM_HOME="$race_home" "$CLI" search --source post-verify --query supervisorupdatedcanary --json)
  assert_result_count "$out" 0 "post-verification race published the new database"
  pass "supervisor rolls back post-verification provenance changes"
}

test_atomic_replace_never_removes_canonical_database() {
  local gate="$TMP_ROOT/atomic-replace-gate" sync_pid supervisor_pid index before after
  index="$HOME_DIR/state/knowledge-indexes/repo-a.sqlite3"
  run_cli sync --source repo-a --json >/dev/null
  before=$(sha_of "$index")
  printf '\natomicreplacecanary\n' >> "$REPO_A/records/shared.md"
  FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_BACKUP_LINK="$gate" \
    "$CLI" sync --source repo-a --json > "$TMP_ROOT/atomic-replace.out" 2>&1 &
  sync_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$sync_pid" 2>/dev/null || fail "sync exited before atomic replace gate"
    sleep 0.01
  done
  [ -f "$index" ] || fail "canonical database disappeared before atomic replace"
  after=$(sha_of "$index")
  [ "$after" = "$before" ] || fail "canonical database changed before atomic replace"
  supervisor_pid=$(pgrep -P "$sync_pid" | head -1)
  [ -n "$supervisor_pid" ] || fail "could not identify sync supervisor for interruption"
  kill -9 "$supervisor_pid" 2>/dev/null || true
  wait "$sync_pid" 2>/dev/null || true
  [ -f "$index" ] || fail "interrupted publish left no canonical database"
  after=$(sha_of "$index")
  [ "$after" = "$before" ] || fail "interrupted publish changed the canonical database"
  run_cli status --source repo-a --json >/dev/null
  if find "$HOME_DIR/state/knowledge-indexes/.transactions" -type f -name 'sync-repo-a.sqlite3' | grep -q .; then
    fail "interrupted publish recovery reference survived the next locked operation"
  fi
  pass "sync publication keeps the canonical database through interruption"
}

test_interrupted_remove_recovers_without_old_content_residue() {
  local gate="$TMP_ROOT/interrupted-remove" remove_pid supervisor_pid index out
  index="$HOME_DIR/state/knowledge-indexes/repo-b.sqlite3"
  run_cli sync --source repo-b --json >/dev/null
  FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_REMOVE_QUARANTINE="$gate" \
    "$CLI" remove --source repo-b --confirm repo-b --json > "$TMP_ROOT/interrupted-remove.out" 2>&1 &
  remove_pid=$!
  while [ ! -e "$gate.ready" ]; do
    kill -0 "$remove_pid" 2>/dev/null || fail "remove exited before quarantine interruption gate"
    sleep 0.01
  done
  supervisor_pid=$(pgrep -P "$remove_pid" | head -1)
  [ -n "$supervisor_pid" ] || fail "could not identify remove supervisor for interruption"
  kill -9 "$supervisor_pid" 2>/dev/null || true
  wait "$remove_pid" 2>/dev/null || true
  [ ! -e "$index" ] || fail "interrupted remove did not quarantine the canonical database"
  out=$(run_cli remove --source repo-b --confirm repo-b --json)
  [ "$(printf '%s' "$out" | jq -r '.removed')" = true ] \
    || fail "next locked remove did not recover and complete interrupted removal"
  [ ! -e "$index" ] || fail "recovered removal left the canonical database"
  if find "$HOME_DIR/state/knowledge-indexes/.transactions" -type f -name 'remove-repo-b.sqlite3' | grep -q .; then
    fail "completed removal retained old index content in transaction recovery"
  fi
  pass "interrupted removal recovers and clears old index content"
}

test_fts5_diagnostic() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/fts5-missing")
  cat > "$fakebin/sqlite3" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/sqlite3"
  if out=$(PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$CLI" validate 2>&1); then
    fail "CLI silently accepted SQLite without FTS5"
  fi
  assert_contains "$out" 'SQLite FTS5 is unavailable' \
    "missing FTS5 diagnostic is not actionable"
  pass "actionable SQLite FTS5 capability diagnostic"
}

setup_fixtures
test_registry_validation_and_sync
test_explicit_selection_and_retrieval
test_zero_foreign_source_leakage_and_provenance
test_allow_deny_and_symlink_safety
test_same_slug_isolation_and_idempotency
test_sql_fts_metacharacter_safety
test_atomic_failure_preserves_previous_index
test_deletion_and_rename_propagation
test_safe_source_removal
test_sync_remove_source_coordination
test_source_operation_lock_rejects_symlink
test_bash_32_parse_compatibility
test_forged_index_directory_fd_is_rejected
test_index_locator_environment_is_ignored
test_relative_home_resolves_from_invocation_directory
test_registry_path_traversal_and_root_rejection
test_directory_replacement_does_not_escape_root
test_root_replacement_rejects_stale_provenance
test_commit_provenance_uses_opened_root
test_commit_provenance_ignores_git_environment_routing
test_registry_replacement_preserves_previous_index
test_bare_repository_has_no_commit_provenance
test_post_verify_replacement_fails_closed
test_remove_replacement_preserves_replacement_database
test_status_fails_closed_during_index_directory_replacement
test_forged_supervised_mode_does_not_follow_output_symlink
test_unsafe_source_is_rejected_before_supervisor_file_access
test_supervisor_revalidates_provenance_and_state_before_commit
test_supervisor_rolls_back_post_verify_provenance_change
test_atomic_replace_never_removes_canonical_database
test_interrupted_remove_recovers_without_old_content_residue
test_fts5_diagnostic
