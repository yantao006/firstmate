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
  FM_HOME="$HOME_DIR" FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_PUBLISH="$gate" \
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
  pass "source ID, pattern, root traversal, and symlink-root rejection"
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
test_registry_path_traversal_and_root_rejection
test_fts5_diagnostic
