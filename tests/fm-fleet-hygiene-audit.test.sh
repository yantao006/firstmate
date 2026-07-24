#!/usr/bin/env bash
# Behavior tests for the read-only Fleet hygiene P0 audit.
#
# Synthetic homes and treehouse pools pin the Age/Size OR, Size-only keep-two
# quota, live metadata exclusion, Layer B 30/45-day thresholds, and conservative
# open-PR handling without reading or mutating the operator's real home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-fleet-hygiene-tests)
HOME_DIR="$TMP_ROOT/home"
TREEHOUSE="$TMP_ROOT/treehouse"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NOW=2000000000
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" "$TREEHOUSE"

set_tree_age() {
  local path=$1 seconds=$2 epoch
  epoch=$((NOW - seconds))
  find "$path" -print0 | perl -0 -e '
    $epoch = shift @ARGV;
    local $/ = "\0";
    while (<STDIN>) { chomp; utime $epoch, $epoch, $_ or die "utime $_: $!\n"; }
  ' "$epoch"
}

new_slot() {
  local pool=$1 slot=$2 age_seconds=$3 path
  path="$TREEHOUSE/$pool/$slot"
  fm_git_init_commit "$path"
  set_tree_age "$path" "$age_seconds"
}

cat > "$FAKEBIN/du" <<'SH'
#!/usr/bin/env bash
path=${!#}
case "$(basename "$path")" in
  age-small) kib=51200 ;;
  age-large) kib=2097152 ;;
  size-oldest|size-middle|size-newest|live-size-old|live-size-new|single-size) kib=1572864 ;;
  *) kib=10240 ;;
esac
printf '%s\t%s\n' "$kib" "$path"
SH
chmod +x "$FAKEBIN/du"

new_slot pool-a age-small 604800
new_slot pool-a age-large 864000
new_slot pool-a size-oldest 259200
new_slot pool-a size-middle 172800
new_slot pool-a size-newest 86400
new_slot pool-live live-size-old 172800
new_slot pool-live live-size-new 86400
mkdir -p "$TREEHOUSE/pool-live/live-slot/repository"
set_tree_age "$TREEHOUSE/pool-live/live-slot" 3600
new_slot pool-single single-size 86400

cat > "$HOME_DIR/state/live.meta" <<EOF
worktree=$TREEHOUSE/pool-live/live-slot/repository
project=unrelated
kind=ship
EOF

run_audit() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TREEHOUSE_ROOT="$TREEHOUSE" \
    FM_HYGIENE_NOW_EPOCH="$NOW" "$ROOT/bin/fm-fleet-hygiene-audit.sh" "$@"
}

out=$(run_audit)
assert_contains "$out" '| [x] | pool-a | age-small |' 'Age accepts a small slot at exactly seven days'
assert_contains "$out" '| [x] | pool-a | age-large |' 'Age accepts a large old slot without quota'
assert_contains "$out" '| [x] | pool-a | size-oldest |' 'Size selects the oldest young large slot within quota'
assert_not_contains "$out" '| [x] | pool-a | size-middle |' 'Size keep-two retains a newer slot'
assert_not_contains "$out" '| [x] | pool-a | size-newest |' 'Size keep-two retains the newest slot'
assert_contains "$out" '| pool-a | size-middle |' 'retained Size slot remains in appendix'
assert_contains "$out" 'retained by Size keep-2' 'appendix names the Size quota'
assert_contains "$out" '| pool-live | live-slot |' 'live slot remains visible in appendix'
assert_contains "$out" '| live | live meta worktree |' 'live metadata is a hard exclusion'
assert_contains "$out" '| [x] | pool-live | live-size-old |' 'live slot counts toward two remaining slots'
assert_not_contains "$out" '| [x] | pool-live | live-size-new |' 'newer Size slot is retained beside live slot'
assert_not_contains "$out" '| [x] | pool-single | single-size |' 'single young large slot is retained'
pass 'Layer A applies Age/Size OR, Size keep-two, and live metadata exclusion'

new_project() {
  local name=$1 days=$2 repo remote branch commit_epoch
  repo="$HOME_DIR/projects/$name"
  remote="$TMP_ROOT/remotes/$name.git"
  commit_epoch=$((NOW - days * 86400))
  mkdir -p "$repo" "$TMP_ROOT/remotes"
  git -C "$repo" init -q
  printf '# %s\n' "$name" > "$repo/README.md"
  git -C "$repo" add README.md
  GIT_AUTHOR_DATE="@$commit_epoch" GIT_COMMITTER_DATE="@$commit_epoch" \
    git -C "$repo" commit -qm initial
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  git clone --quiet --bare "$repo" "$remote"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin "$branch"
  git -C "$repo" remote set-url origin "https://github.com/example/$name.git"
}

for spec in \
  'recent 29' \
  'thirty 30' \
  'fortyfive 45' \
  'openpr 60' \
  'prfail 60' \
  'inflight 60' \
  'queued 60' \
  'decision 60' \
  'adcue 90'; do
  # shellcheck disable=SC2086
  new_project $spec
done
printf 'uncommitted\n' > "$HOME_DIR/projects/inflight/local.txt"
rm "$HOME_DIR/projects/inflight/local.txt"

cat > "$HOME_DIR/data/projects.md" <<'EOF'
- recent [no-mistakes] - recent fixture
- thirty [no-mistakes] - threshold fixture
- fortyfive [no-mistakes] - threshold fixture
- openpr [no-mistakes] - open PR fixture
- prfail [no-mistakes] - PR failure fixture
- inflight [no-mistakes] - active fixture
- queued [no-mistakes] - queued fixture
- decision [no-mistakes] - decision fixture
- adcue [no-mistakes] - whitelist fixture
EOF
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] active-work - Active work (repo: inflight, kind: ship)

## Queued
- [ ] queued-work - Queued docs (repo: queued, kind: docs)
- [ ] decision-work - Awaiting captain (repo: decision, kind: captain)

## Done
EOF
cat > "$HOME_DIR/state/active.meta" <<EOF
worktree=$TMP_ROOT/active-worktree
project=inflight
kind=ship
EOF

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
repo=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -R|--repo) repo=$2; shift ;;
  esac
  shift
done
case "$repo" in
  example/openpr) printf 'count: 1\nprs[1]{number}:\n  12\n' ;;
  example/prfail) exit 1 ;;
  *) printf 'count: 0\nprs[0]:\n' ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

out=$(run_audit --check-prs)
assert_contains "$out" '| [ ] | thirty | 30 days | observe | stale 30-44 days |' '30-day project enters observation list'
assert_contains "$out" '| [x] | fortyfive | 45 days | 2 |' '45-day clear project is prechecked for tier 2'
assert_not_contains "$out" '| [x] | recent |' '29-day project is below threshold'
assert_contains "$out" '| recent | 29 days | below stale threshold |' 'recent project remains in appendix'
assert_contains "$out" '| openpr | 60 days | hard excluded | open PR - merge or close first |' 'open PR hard-excludes stale project'
assert_contains "$out" '| [ ] | prfail | 60 days | 2 |' 'failed PR check prevents tier 2 precheck'
assert_contains "$out" 'unknown (PR check failed)' 'failed PR check is reported as unknown'
assert_contains "$out" '| inflight | 60 days | hard excluded |' 'in-flight project is hard excluded'
assert_contains "$out" '| queued | 60 days | hard excluded | queued ship/docs work |' 'queued project is hard excluded'
assert_contains "$out" '| decision | 60 days | hard excluded | open captain decision |' 'open decision is hard excluded'
assert_contains "$out" '| adcue | 90 days | hard excluded | static or configured whitelist |' 'static whitelist is hard excluded'
pass 'Layer B applies 30/45 thresholds and hard exclusions'

out=$(run_audit)
assert_contains "$out" '| [ ] | fortyfive | 45 days | 2 |' 'local-only default does not precheck stale tier 2'
assert_contains "$out" 'unknown (not checked)' 'local-only default reports PR evidence as unknown'
report="$HOME_DIR/data/hygiene/custom.md"
run_audit --output "$report" >/dev/null
[ -f "$report" ] || fail '--output did not write the requested report'
assert_grep '# Fleet hygiene audit -' "$report" 'written report is missing its title'
pass 'audit is local-only by default and writes only an explicitly requested report'

set +e
out=$(run_audit --output "$HOME_DIR/data/projects.md/report.md" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail 'output directory creation failure returned success'
assert_contains "$out" 'could not create output directory' 'directory creation failure is not reported'
assert_not_contains "$out" 'fm-fleet-hygiene-audit: wrote' 'directory creation failure reported a successful write'

cat > "$FAKEBIN/cp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/cp"
set +e
out=$(run_audit --output "$HOME_DIR/data/hygiene/copy-failure.md" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail 'report copy failure returned success'
assert_contains "$out" 'could not write' 'report copy failure is not reported'
assert_not_contains "$out" 'fm-fleet-hygiene-audit: wrote' 'report copy failure reported a successful write'
pass 'write failures return nonzero without reporting success'
