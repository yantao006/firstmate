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
  local pool=$1 slot=$2 age_seconds=$3 path remote branch
  path="$TREEHOUSE/$pool/$slot"
  remote="$TMP_ROOT/slot-remotes/$pool-$slot.git"
  fm_git_init_commit "$path"
  mkdir -p "$TMP_ROOT/slot-remotes"
  git clone --quiet --bare "$path" "$remote"
  git -C "$path" remote add origin "$remote"
  branch=$(git -C "$path" symbolic-ref --short HEAD)
  git -C "$path" push -q -u origin "$branch"
  set_tree_age "$path" "$age_seconds"
}

cat > "$FAKEBIN/du" <<'SH'
#!/usr/bin/env bash
path=${!#}
case "$(basename "$path")" in
  age-small) kib=51200 ;;
  age-large) kib=2097152 ;;
  size-oldest|size-middle|size-newest|live-size-old|live-size-new|single-size|tie-middle) kib=1572864 ;;
  tie-small) kib=1048576 ;;
  tie-large) kib=2097152 ;;
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
new_slot pool-tie tie-small 86400
new_slot pool-tie tie-middle 86400
new_slot pool-tie tie-large 86400
new_slot pool-remote remote-contained 604800
git -C "$TREEHOUSE/pool-remote/remote-contained" branch --unset-upstream
mkdir -p "$TREEHOUSE/pool-protected/no-upstream"
fm_git_init_commit "$TREEHOUSE/pool-protected/no-upstream"
set_tree_age "$TREEHOUSE/pool-protected/no-upstream" 604800

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
assert_contains "$out" '| 可安全处置 | 按时间 |' 'candidate class and route labels are Chinese'
assert_contains "$out" '| [x] | pool-a | age-large |' 'Age accepts a large old slot without quota'
assert_contains "$out" '| [x] | pool-a | size-oldest |' 'Size selects the oldest young large slot within quota'
assert_not_contains "$out" '| [x] | pool-a | size-middle |' 'Size keep-two retains a newer slot'
assert_not_contains "$out" '| [x] | pool-a | size-newest |' 'Size keep-two retains the newest slot'
assert_contains "$out" '| pool-a | size-middle |' 'retained Size slot remains in appendix'
assert_contains "$out" '因大小路径每池保留 2 个槽位' 'appendix names the Size quota in Chinese'
assert_contains "$out" '| pool-live | live-slot |' 'live slot remains visible in appendix'
assert_contains "$out" '| 使用中 | 被运行中任务引用 |' 'live metadata is a hard exclusion with Chinese presentation'
assert_contains "$out" '| [x] | pool-live | live-size-old |' 'live slot counts toward two remaining slots'
assert_not_contains "$out" '| [x] | pool-live | live-size-new |' 'newer Size slot is retained beside live slot'
assert_not_contains "$out" '| [x] | pool-single | single-size |' 'single young large slot is retained'
assert_contains "$out" '| [x] | pool-tie | tie-small |' 'Size selects the smaller slot when candidate ages tie'
assert_not_contains "$out" '| [x] | pool-tie | tie-large |' 'Size retains the larger slot when candidate ages tie'
assert_contains "$out" '| [x] | pool-remote | remote-contained |' 'remote containment proves a no-upstream slot is disposable'
assert_not_contains "$out" '| [x] | pool-protected | no-upstream |' 'a default branch without upstream or remote containment is protected'
assert_contains "$out" '| 有未合并提交 | 存在未合并提交 |' 'uncertain no-upstream work remains visible in the Chinese appendix'
pass 'Layer A applies Age/Size OR, Size keep-two, and live metadata exclusion'

REAL_GIT=$(command -v git)
FAIL_GIT="$TMP_ROOT/fail-git"
mkdir -p "$FAIL_GIT"
cat > "$FAIL_GIT/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" diff --name-only --diff-filter=U "*|*" status --porcelain --untracked-files=normal "*) exit 1 ;;
esac
exec "$REAL_GIT" "$@"
SH
chmod +x "$FAIL_GIT/git"
out=$(REAL_GIT="$REAL_GIT" PATH="$FAIL_GIT:$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
  FM_TREEHOUSE_ROOT="$TREEHOUSE" FM_HYGIENE_NOW_EPOCH="$NOW" \
  "$ROOT/bin/fm-fleet-hygiene-audit.sh")
assert_not_contains "$out" '| [x] | pool-a | age-small |' 'failed Git evidence preselected a Layer A slot'
assert_contains "$out" '| pool-a | age-small |' 'slot with failed Git evidence is missing from the appendix'
assert_contains "$out" '| 孤立或无法读取 |' 'failed Git evidence is not classified as unreadable'

FAIL_MTIME="$TMP_ROOT/fail-mtime"
mkdir -p "$FAIL_MTIME"
cat > "$FAIL_MTIME/stat" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAIL_MTIME/stat"
out=$(PATH="$FAIL_MTIME:$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_TREEHOUSE_ROOT="$TREEHOUSE" \
  FM_HYGIENE_NOW_EPOCH="$NOW" "$ROOT/bin/fm-fleet-hygiene-audit.sh")
assert_not_contains "$out" '| [x] | pool-a | age-small |' 'failed mtime evidence preselected a Layer A slot'
assert_contains "$out" '| pool-a | age-small |' 'slot with failed mtime evidence is missing from the appendix'
assert_contains "$out" '| 孤立或无法读取 |' 'failed mtime evidence is not classified as unreadable'

cat > "$FAIL_MTIME/stat" <<SH
#!/usr/bin/env bash
exec "$(command -v stat)" "\$@"
SH
cat > "$FAIL_MTIME/find" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -mindepth 1 -maxdepth 3 -print "*) exit 1 ;;
esac
exec "$REAL_FIND" "$@"
SH
chmod +x "$FAIL_MTIME/find"
REAL_FIND=$(command -v find)
out=$(REAL_FIND="$REAL_FIND" PATH="$FAIL_MTIME:$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
  FM_TREEHOUSE_ROOT="$TREEHOUSE" FM_HYGIENE_NOW_EPOCH="$NOW" \
  "$ROOT/bin/fm-fleet-hygiene-audit.sh")
assert_not_contains "$out" '| [x] | pool-a | age-small |' 'failed mtime traversal preselected a Layer A slot'
assert_contains "$out" '| 孤立或无法读取 |' 'failed mtime traversal is not classified as unreadable'
pass 'Layer A fails closed when Git or mtime evidence cannot be read'

EMPTY_HOME="$TMP_ROOT/empty-home"
EMPTY_TREEHOUSE="$TMP_ROOT/empty-treehouse"
mkdir -p "$EMPTY_HOME/state" "$EMPTY_HOME/data" "$EMPTY_HOME/projects" "$EMPTY_TREEHOUSE"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$EMPTY_HOME" FM_TREEHOUSE_ROOT="$EMPTY_TREEHOUSE" \
  FM_HYGIENE_NOW_EPOCH="$NOW" "$ROOT/bin/fm-fleet-hygiene-audit.sh")
assert_contains "$out" '没有可安全处置的候选项' 'Layer A candidate empty state is Chinese'
assert_contains "$out" '没有通过强制排除检查的闲置项目' 'Layer B candidate empty state is Chinese'
assert_contains "$out" '没有已排除或因配额保留的槽位' 'Layer A appendix empty state is Chinese'
assert_contains "$out" '没有已排除或未达到阈值的项目' 'Layer B appendix empty state is Chinese'
pass 'empty report rows are captain-facing Chinese'

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
  'decisionunknown 60' \
  'activity 60' \
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
- decisionunknown [no-mistakes] - unknown decision fixture
- activity [no-mistakes] - recent docs fixture
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
mkdir -p "$HOME_DIR/projects/decisionunknown/.beads" "$HOME_DIR/data/docs"
printf '.beads/\n' >> "$HOME_DIR/projects/decisionunknown/.git/info/exclude"
printf 'recent project activity\n' > "$HOME_DIR/data/docs/activity-note.md"
set_tree_age "$HOME_DIR/data/docs/activity-note.md" 432000
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

cat > "$FAKEBIN/bd" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/bd"

out=$(run_audit --check-prs)
assert_contains "$out" '| [ ] | thirty | 30 天 | 观察 | 已闲置 30 至 44 天 |' '30-day project enters observation list'
assert_contains "$out" '| [x] | fortyfive | 45 天 | 2 |' '45-day clear project is prechecked for tier 2'
assert_not_contains "$out" '| [x] | recent |' '29-day project is below threshold'
assert_contains "$out" '| recent | 29 天 | 未达到闲置阈值 |' 'recent project remains in appendix'
assert_contains "$out" '| openpr | 60 天 | 强制排除 | 存在开放的 PR，请先合并或关闭 |' 'open PR hard-excludes stale project'
assert_contains "$out" '| [ ] | prfail | 60 天 | 2 |' 'failed PR check prevents tier 2 precheck'
assert_contains "$out" 'PR 检查失败，状态未知' 'failed PR check is reported as unknown in Chinese'
assert_contains "$out" '| inflight | 60 天 | 强制排除 |' 'in-flight project is hard excluded'
assert_contains "$out" '| queued | 60 天 | 强制排除 | 任务清单中有排队的交付或文档工作 |' 'queued project is hard excluded'
assert_contains "$out" '| decision | 60 天 | 强制排除 | 存在待船长决定的事项 |' 'open decision is hard excluded'
assert_contains "$out" '| [ ] | decisionunknown | 60 天 | 2 |' 'unknown Beads decision status prevents a tier 2 precheck'
assert_contains "$out" 'Beads 决策状态未知' 'failed decision evidence is reported as unknown in Chinese'
assert_not_contains "$out" '| [x] | activity |' 'recent documentation activity prevents a stale precheck'
assert_contains "$out" '| activity | 5 天 | 未达到闲置阈值 |' 'stale clock uses the youngest available activity age'
assert_contains "$out" '| adcue | 90 天 | 强制排除 | 静态或配置白名单 |' 'static whitelist is hard excluded'
pass 'Layer B applies 30/45 thresholds and hard exclusions'

out=$(REAL_GIT="$REAL_GIT" PATH="$FAIL_GIT:$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
  FM_TREEHOUSE_ROOT="$TREEHOUSE" FM_HYGIENE_NOW_EPOCH="$NOW" \
  "$ROOT/bin/fm-fleet-hygiene-audit.sh" --check-prs)
assert_contains "$out" '| [ ] | fortyfive | 45 天 | 2 |' 'failed Git status preselected a Layer B project'
assert_contains "$out" 'Git 状态检查失败，本地副本安全状态未知' 'failed Git status is not reported as unknown'
pass 'Layer B fails closed when Git status cannot be read'

out=$(run_audit)
assert_contains "$out" '| [ ] | fortyfive | 45 天 | 2 |' 'local-only default does not precheck stale tier 2'
assert_contains "$out" '未检查 PR 状态' 'local-only default reports PR evidence as unknown in Chinese'
report="$HOME_DIR/data/hygiene/custom.md"
run_audit --output "$report" >/dev/null
[ -f "$report" ] || fail '--output did not write the requested report'
assert_grep '# 舰队卫生审计 -' "$report" 'written report is missing its Chinese title'
assert_grep '| 选择 | 池 | 槽位 | 路径 | 空闲时间 | 大小 | 分类 | 候选规则 |' "$report" 'written report is missing Chinese Layer A headers'
assert_grep '## 如何回复' "$report" 'written report is missing Chinese reply instructions'
pass 'audit is local-only by default and writes only an explicitly requested report'

set +e
printf 'registry sentinel\n' > "$HOME_DIR/data/projects.md"
out=$(run_audit --output "$HOME_DIR/data/projects.md" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail 'registry output path returned success'
assert_contains "$out" 'output must be a .md file directly inside' 'registry output path is not rejected'
[ "$(cat "$HOME_DIR/data/projects.md")" = 'registry sentinel' ] || fail 'registry output path modified the registry'

printf 'registry target sentinel\n' > "$HOME_DIR/data/registry-target.md"
ln -s "$HOME_DIR/data/registry-target.md" "$HOME_DIR/data/hygiene/report-link.md"
out=$(run_audit --output "$HOME_DIR/data/hygiene/report-link.md" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail 'symbolic-link output path returned success'
assert_contains "$out" 'refusing symbolic-link output path' 'symbolic-link output path is not rejected'
[ "$(cat "$HOME_DIR/data/registry-target.md")" = 'registry target sentinel' ] \
  || fail 'symbolic-link output modified its target'

out=$(run_audit --output "$HOME_DIR/data/hygiene/report.txt" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail 'non-Markdown output path returned success'
assert_contains "$out" 'output must be a .md file directly inside' 'non-Markdown output path is not rejected'
pass 'output is confined to nonsymlink Markdown reports'

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

skill="$ROOT/.agents/skills/fleet-hygiene/SKILL.md"
assert_grep "Add \`--check-prs\` only when the captain explicitly requests PR checks." "$skill" 'skill does not keep PR checks opt-in'
assert_grep 'lavish-axi playbook input' "$skill" 'skill does not require current Lavish input guidance'
assert_grep 'lavish-axi playbook table' "$skill" 'skill does not require current Lavish table guidance'
assert_grep '.lavish/fleet-hygiene-YYYY-MM-DD.html' "$skill" 'skill does not define the dated Lavish artifact path'
assert_grep 'native multi-select checkboxes' "$skill" 'skill does not require native multi-select controls'
assert_grep 'window.lavish.queuePrompt()' "$skill" 'skill does not queue one concrete checklist prompt'
assert_grep '船长，舰队卫生检查清单已在 Lavish 中打开' "$skill" 'skill chat summary is not explicitly Chinese'
assert_not_contains "$(cat "$skill")" '## Safety boundary' 'skill restates policy outside the tracked docs owner'
pass 'skill keeps policy ownership in docs and requires Chinese Lavish presentation'
