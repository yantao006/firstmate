#!/usr/bin/env bash
# fm-fleet-hygiene-audit.sh - read-only Fleet hygiene P0 audit.
#
# This command implements the mechanics for the policy owned by
# docs/fleet-hygiene.md. It scans treehouse slots and registered/local projects,
# writes no fleet state unless --write is requested, and never destroys, prunes,
# archives, closes, or removes anything.
#
# Inputs:
#   FM_HOME                         firstmate operational home (default: repo root)
#   FM_TREEHOUSE_ROOT               treehouse root (default: $HOME/.treehouse)
#   FM_HYGIENE_NOW_EPOCH            fixed clock for deterministic tests
#   FM_HYGIENE_WHITELIST            comma-separated extra Layer B project names
#   $FM_HOME/state/*.meta           live worktree and project exclusions
#   $FM_HOME/data/projects.md       project registry
#   $FM_HOME/data/backlog.md        in-flight, queued, and captain-decision hints
#   $FM_HOME/projects/*             project clones and local activity
#
# Optional local tools improve classification: git inspects repository safety,
# and bd checks open decisions when a clone has a .beads database. PR checks are
# networked and therefore opt-in with --check-prs; they use gh-axi, never plain gh.
# A missing or failed PR check is unknown and prevents a Layer B tier 2 precheck.
#
# Usage:
#   bin/fm-fleet-hygiene-audit.sh [--write] [--output PATH] [--check-prs]
#   bin/fm-fleet-hygiene-audit.sh --help
#
# Output is Markdown on stdout. --write also saves it to
# $FM_HOME/data/hygiene/report-YYYY-MM-DD.md. --output PATH implies --write and
# selects another Markdown file directly inside that report directory. The
# command is always dry-run only.
set -u

usage() {
  cat <<'EOF'
Usage: fm-fleet-hygiene-audit.sh [options]

Generate the read-only Layer A treehouse and Layer B project hygiene checklist.
The policy contract is docs/fleet-hygiene.md. This command never deletes,
prunes, archives, closes, or removes anything.

Options:
  --write          Also write $FM_HOME/data/hygiene/report-YYYY-MM-DD.md
  --output PATH    Write another .md file directly in $FM_HOME/data/hygiene
  --check-prs      Query open PRs with gh-axi for GitHub-backed project clones
  -h, --help       Show this help

Defaults:
  FM_HOME defaults to the repository containing this script.
  FM_TREEHOUSE_ROOT defaults to $HOME/.treehouse.
  Network access is disabled unless --check-prs is supplied.
  Markdown is always printed to stdout.

Optional environment:
  FM_HYGIENE_WHITELIST is a comma-separated Layer B whitelist extension.
  FM_HYGIENE_NOW_EPOCH fixes the audit clock for deterministic fixtures.
EOF
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FM_HOME=${FM_HOME:-$ROOT}
TREEHOUSE_ROOT=${FM_TREEHOUSE_ROOT:-${HOME:?HOME is required}/.treehouse}
NOW=${FM_HYGIENE_NOW_EPOCH:-$(date +%s)}
WRITE=0
OUTPUT=
CHECK_PRS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --write) WRITE=1 ;;
    --output)
      [ "$#" -ge 2 ] || { printf 'fm-fleet-hygiene-audit: --output requires a path\n' >&2; exit 2; }
      OUTPUT=$2
      WRITE=1
      shift
      ;;
    --check-prs) CHECK_PRS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-fleet-hygiene-audit: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-hygiene.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
A_ALL="$TMP/a-all.tsv"
A_CANDIDATES="$TMP/a-candidates.tsv"
A_APPENDIX="$TMP/a-appendix.tsv"
PROJECTS="$TMP/projects.txt"
B_MAIN="$TMP/b-main.tsv"
B_APPENDIX="$TMP/b-appendix.tsv"
REPORT="$TMP/report.md"
: > "$A_ALL"
: > "$A_CANDIDATES"
: > "$A_APPENDIX"
: > "$PROJECTS"
: > "$B_MAIN"
: > "$B_APPENDIX"

stat_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

format_day() {
  date -r "$1" +%F 2>/dev/null || date -d "@$1" +%F 2>/dev/null || date +%F
}

format_size() {
  awk -v kib="$1" 'BEGIN {
    if (kib >= 1048576) printf "%.1f GiB", kib / 1048576;
    else if (kib >= 1024) printf "%.0f MiB", kib / 1024;
    else printf "%d KiB", kib;
  }'
}

physical_path() {
  if [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "${1%/}"
  else
    printf '%s\n' "${1%/}"
  fi
}

latest_mtime() {
  local root=$1 latest current entry entries="$TMP/latest-mtime"
  latest=$(stat_mtime "$root") || return 1
  find "$root" -mindepth 1 -maxdepth 3 -print > "$entries" 2>/dev/null || return 1
  while IFS= read -r entry; do
    current=$(stat_mtime "$entry") || return 1
    [ "$current" -le "$latest" ] || latest=$current
  done < "$entries"
  printf '%s\n' "$latest"
}

live_worktree() {
  local target meta value resolved
  target=$(physical_path "$1")
  for meta in "$FM_HOME"/state/*.meta; do
    [ -f "$meta" ] || continue
    value=$(awk -F= '$1=="worktree" {sub(/^[^=]*=/, ""); print; exit}' "$meta")
    [ -n "$value" ] || continue
    resolved=$(physical_path "$value")
    case "$resolved" in
      "$target"|"$target"/*) return 0 ;;
    esac
  done
  return 1
}

slot_git_root() {
  local slot=$1 candidate root found=
  command -v git >/dev/null 2>&1 || return 1
  for candidate in "$slot" "$slot"/*; do
    [ -d "$candidate" ] || continue
    root=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || continue
    root=$(physical_path "$root")
    if [ -n "$found" ] && [ "$root" != "$found" ]; then
      return 1
    fi
    found=$root
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

slot_class() {
  local slot=$1 repo upstream branch unmerged status
  if live_worktree "$slot"; then
    printf 'live\n'
    return
  fi
  repo=$(slot_git_root "$slot") || { printf 'orphan\n'; return; }
  unmerged=$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null) \
    || { printf 'orphan\n'; return; }
  if [ -n "$unmerged" ]; then
    printf 'unmerged\n'
    return
  fi
  status=$(git -C "$repo" status --porcelain --untracked-files=normal 2>/dev/null) \
    || { printf 'orphan\n'; return; }
  if [ -n "$status" ]; then
    printf 'dirty\n'
    return
  fi
  upstream=$(git -C "$repo" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
  if [ -n "$upstream" ]; then
    if git -C "$repo" merge-base --is-ancestor HEAD "$upstream" >/dev/null 2>&1; then
      printf 'disposable\n'
    else
      printf 'unmerged\n'
    fi
    return
  fi
  branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if git -C "$repo" branch -r --contains HEAD 2>/dev/null | grep -q .; then
    printf 'disposable\n'
  elif [ -z "$branch" ]; then
    printf 'orphan\n'
  else
    printf 'unmerged\n'
  fi
}

markdown_escape() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/|/\\|/g'
}

append_text() {
  if [ -n "$1" ]; then
    printf '%s；%s' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

slot_class_label() {
  case "$1" in
    live) printf '使用中' ;;
    dirty) printf '有未提交更改' ;;
    unmerged) printf '有未合并提交' ;;
    orphan) printf '孤立或无法读取' ;;
    disposable) printf '可安全处置' ;;
    *) printf '未知' ;;
  esac
}

candidate_route_label() {
  case "$1" in
    Age) printf '按时间' ;;
    Size) printf '按大小' ;;
    *) printf '未知' ;;
  esac
}

# Layer A records: pool, slot, path, class, age_seconds, age_days, size_kib.
if [ -d "$TREEHOUSE_ROOT" ]; then
  for pool_dir in "$TREEHOUSE_ROOT"/*; do
    [ -d "$pool_dir" ] || continue
    for slot_dir in "$pool_dir"/*; do
      [ -d "$slot_dir" ] || continue
      pool=$(basename "$pool_dir")
      slot=$(basename "$slot_dir")
      mtime_known=1
      mtime=$(latest_mtime "$slot_dir") || { mtime=$NOW; mtime_known=0; }
      case "$mtime" in ''|*[!0-9]*) mtime=$NOW; mtime_known=0 ;; esac
      age_seconds=$((NOW - mtime))
      [ "$age_seconds" -ge 0 ] || age_seconds=0
      age_days=$((age_seconds / 86400))
      size_kib=$(du -sk "$slot_dir" 2>/dev/null | awk 'NR==1 {print $1}')
      case "$size_kib" in ''|*[!0-9]*) size_kib=0 ;; esac
      class=$(slot_class "$slot_dir")
      [ "$mtime_known" -eq 1 ] || class=orphan
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pool" "$slot" "$(physical_path "$slot_dir")" "$class" \
        "$age_seconds" "$age_days" "$size_kib" >> "$A_ALL"
    done
  done
fi

# Age candidates are unconditional after the safety class. Size candidates are
# ranked per pool and admitted only while at least two total slots remain after
# all Age candidates and admitted Size candidates are hypothetically removed.
while IFS=$'\t' read -r pool slot path class age_seconds age_days size_kib; do
  [ -n "$pool" ] || continue
  if [ "$class" = disposable ] && [ "$age_seconds" -ge 604800 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tAge\n' \
      "$pool" "$slot" "$path" "$class" "$age_seconds" "$age_days" "$size_kib" >> "$A_CANDIDATES"
  fi
done < "$A_ALL"

cut -f1 "$A_ALL" | LC_ALL=C sort -u | while IFS= read -r pool; do
  [ -n "$pool" ] || continue
  total=$(awk -F '\t' -v p="$pool" '$1==p {n++} END {print n+0}' "$A_ALL")
  age_n=$(awk -F '\t' -v p="$pool" '$1==p && $8=="Age" {n++} END {print n+0}' "$A_CANDIDATES")
  limit=$((total - age_n - 2))
  [ "$limit" -ge 0 ] || limit=0
  selected=0
  awk -F '\t' -v p="$pool" '$1==p && $4=="disposable" && $5<604800 && $7>=1048576' "$A_ALL" \
    | LC_ALL=C sort -t $'\t' -k5,5nr -k7,7n -k3,3 \
    | while IFS=$'\t' read -r p s path class age_seconds age_days size_kib; do
        if [ "$selected" -lt "$limit" ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tSize\n' \
            "$p" "$s" "$path" "$class" "$age_seconds" "$age_days" "$size_kib" >> "$A_CANDIDATES"
          selected=$((selected + 1))
        else
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t因大小路径每池保留 2 个槽位\n' \
            "$p" "$s" "$path" "$class" "$age_seconds" "$age_days" "$size_kib" >> "$A_APPENDIX"
        fi
      done
done

while IFS=$'\t' read -r pool slot path class age_seconds age_days size_kib; do
  [ -n "$pool" ] || continue
  case "$class" in
    live) reason='被运行中任务引用' ;;
    dirty) reason='工作副本有未提交更改' ;;
    unmerged) reason='存在未合并提交' ;;
    orphan) reason='孤立槽位或无法读取 Git 元数据' ;;
    disposable)
      if [ "$age_seconds" -lt 604800 ] && [ "$size_kib" -lt 1048576 ]; then
        reason='未达到时间或大小阈值'
      else
        continue
      fi
      ;;
    *) reason='安全分类未知' ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pool" "$slot" "$path" "$class" "$age_seconds" "$age_days" "$size_kib" "$reason" >> "$A_APPENDIX"
done < "$A_ALL"

# Layer B project identity comes from the registry and local clone directories.
if [ -f "$FM_HOME/data/projects.md" ]; then
  awk '$1=="-" && $2!="" {print $2}' "$FM_HOME/data/projects.md" >> "$PROJECTS"
fi
if [ -d "$FM_HOME/projects" ]; then
  for project_dir in "$FM_HOME"/projects/*; do
    [ -d "$project_dir" ] || continue
    basename "$project_dir" >> "$PROJECTS"
  done
fi
LC_ALL=C sort -u "$PROJECTS" -o "$PROJECTS"

is_whitelisted() {
  local project=$1 item old_ifs
  case "$project" in adcue|firstmate|google-ads-tools) return 0 ;; esac
  old_ifs=$IFS
  IFS=,
  for item in ${FM_HYGIENE_WHITELIST:-}; do
    [ "$item" != "$project" ] || { IFS=$old_ifs; return 0; }
  done
  IFS=$old_ifs
  return 1
}

meta_project_active() {
  local project=$1 meta value kind projects item old_ifs
  for meta in "$FM_HOME"/state/*.meta; do
    [ -f "$meta" ] || continue
    value=$(awk -F= '$1=="project" {sub(/^[^=]*=/, ""); print; exit}' "$meta")
    if [ "$value" = "$project" ] || [ "$(basename "$value" 2>/dev/null)" = "$project" ]; then
      return 0
    fi
    kind=$(awk -F= '$1=="kind" {print $2; exit}' "$meta")
    [ "$kind" = secondmate ] || continue
    projects=$(awk -F= '$1=="projects" {sub(/^[^=]*=/, ""); print; exit}' "$meta")
    old_ifs=$IFS
    IFS=', '
    for item in $projects; do
      if [ "$item" = "$project" ]; then
        IFS=$old_ifs
        return 0
      fi
    done
    IFS=$old_ifs
  done
  return 1
}

backlog_flags() {
  local project=$1 file="$FM_HOME/data/backlog.md"
  [ -f "$file" ] || { printf 'none\n'; return; }
  awk -v project="$project" '
    /^##[[:space:]]+In flight/ {section="in_flight"; next}
    /^##[[:space:]]+Queued/ {section="queued"; next}
    /^##[[:space:]]+/ {section=""; next}
    {
      line=$0
      if (!match(line, /repo:[[:space:]]*[^,)]*/)) next
      repo=substr(line, RSTART, RLENGTH)
      sub(/^repo:[[:space:]]*/, "", repo)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", repo)
      if (repo != project) next
      if (section == "in_flight") inflight=1
      if (section == "queued" && line ~ /kind:[[:space:]]*(ship|docs)([,)]|$)/) queued=1
      if (line ~ /(kind|hold-kind):[[:space:]]*(captain|decision)([,)]|$)/) decision=1
    }
    END {
      sep=""
      if (inflight) {printf "in_flight"; sep=","}
      if (queued) {printf "%squeued", sep; sep=","}
      if (decision) {printf "%sdecision", sep; sep=","}
      if (sep == "") printf "none"
      printf "\n"
    }
  ' "$file"
}

open_beads_decision() {
  local repo=$1 out
  [ -d "$repo/.beads" ] || return 1
  command -v bd >/dev/null 2>&1 || return 2
  out=$(bd --readonly -C "$repo" list --status open,in_progress,blocked,deferred --type decision --json --limit 1 2>/dev/null) || return 2
  if printf '%s' "$out" | grep -q '"id"'; then
    return 0
  fi
  return 1
}

iso_epoch() {
  local value clean
  value=$1
  clean=$(printf '%s' "$value" | sed -E 's/\.[0-9]+Z$/Z/')
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$clean" +%s 2>/dev/null \
    || date -u -d "$clean" +%s 2>/dev/null
}

beads_activity_epoch() {
  local repo=$1 out updated
  [ -d "$repo/.beads" ] || return 1
  command -v bd >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  out=$(bd --readonly -C "$repo" list --all --json --limit 0 2>/dev/null) || return 1
  updated=$(printf '%s' "$out" | jq -r '[.. | objects | .updated_at? // empty] | max // empty' 2>/dev/null) || return 1
  [ -n "$updated" ] || return 1
  iso_epoch "$updated"
}

github_slug() {
  local repo=$1 remote slug
  command -v git >/dev/null 2>&1 || return 1
  remote=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
  case "$remote" in
    git@github.com:*) slug=${remote#git@github.com:} ;;
    https://github.com/*) slug=${remote#https://github.com/} ;;
    http://github.com/*) slug=${remote#http://github.com/} ;;
    *) return 1 ;;
  esac
  slug=${slug%.git}
  case "$slug" in */*) printf '%s\n' "$slug" ;; *) return 1 ;; esac
}

pr_status() {
  local repo=$1 slug out
  [ "$CHECK_PRS" -eq 1 ] || { printf 'unknown (not checked)\n'; return; }
  command -v gh-axi >/dev/null 2>&1 || { printf 'unknown (gh-axi unavailable)\n'; return; }
  slug=$(github_slug "$repo") || { printf 'unknown (no GitHub origin)\n'; return; }
  out=$(gh-axi pr list -R "$slug" --state open --limit 1 --fields number 2>/dev/null) \
    || { printf 'unknown (PR check failed)\n'; return; }
  if printf '%s\n' "$out" | grep -Eq '^count:[[:space:]]*0([[:space:]]|$)'; then
    printf 'none\n'
  elif printf '%s\n' "$out" | grep -Eq '^count:[[:space:]]*[1-9][0-9]*([[:space:]]|$)|number'; then
    printf 'open\n'
  else
    printf 'unknown (unrecognized PR result)\n'
  fi
}

clone_safety() {
  local repo=$1 upstream ahead branch status
  [ -d "$repo" ] || { printf 'unknown (no local clone)\n'; return; }
  command -v git >/dev/null 2>&1 || { printf 'unknown (git unavailable)\n'; return; }
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { printf 'unknown (not a git clone)\n'; return; }
  status=$(git -C "$repo" status --porcelain --untracked-files=normal 2>/dev/null) \
    || { printf 'unknown (git status failed)\n'; return; }
  if [ -n "$status" ]; then
    printf 'dirty\n'
    return
  fi
  upstream=$(git -C "$repo" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
  if [ -n "$upstream" ]; then
    ahead=$(git -C "$repo" rev-list --count "$upstream"..HEAD 2>/dev/null || printf 'unknown')
    case "$ahead" in
      0) printf 'clean\n' ;;
      ''|*[!0-9]*) printf 'unknown (branch comparison failed)\n' ;;
      *) printf 'unpushed commits\n' ;;
    esac
    return
  fi
  branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$branch" ] && git -C "$repo" branch -r --contains HEAD 2>/dev/null | grep -q .; then
    printf 'clean\n'
  else
    printf 'unknown (no tracked branch)\n'
  fi
}

project_age() {
  local project=$1 repo="$FM_HOME/projects/$1" newest age min_age=0 found=0 item mtime commit beads_epoch
  if [ -d "$repo" ]; then
    if command -v git >/dev/null 2>&1 && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      commit=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || true)
      case "$commit" in
        ''|*[!0-9]*) ;;
        *) age=$((NOW - commit)); [ "$age" -ge 0 ] || age=0; min_age=$age; found=1 ;;
      esac
    fi
    beads_epoch=$(beads_activity_epoch "$repo" || true)
    case "$beads_epoch" in
      ''|*[!0-9]*) ;;
      *)
        age=$((NOW - beads_epoch))
        [ "$age" -ge 0 ] || age=0
        if [ "$found" -eq 0 ] || [ "$age" -lt "$min_age" ]; then
          min_age=$age
        fi
        found=1
        ;;
    esac
    if [ "$found" -eq 0 ]; then
      mtime=$(stat_mtime "$repo" || printf '%s' "$NOW")
      age=$((NOW - mtime)); [ "$age" -ge 0 ] || age=0; min_age=$age; found=1
    fi
  fi
  newest=0
  if [ -d "$FM_HOME/data/docs" ]; then
    for item in "$FM_HOME"/data/docs/"$project"*; do
      [ -e "$item" ] || continue
      mtime=$(stat_mtime "$item" || printf '%s' "$NOW")
      [ "$mtime" -le "$newest" ] || newest=$mtime
    done
  fi
  if [ "$newest" -gt 0 ]; then
    age=$((NOW - newest)); [ "$age" -ge 0 ] || age=0
    if [ "$found" -eq 0 ] || [ "$age" -lt "$min_age" ]; then
      min_age=$age
    fi
    found=1
  fi
  if [ "$found" -eq 0 ] && [ -f "$FM_HOME/data/projects.md" ]; then
    mtime=$(stat_mtime "$FM_HOME/data/projects.md" || printf '%s' "$NOW")
    min_age=$((NOW - mtime)); [ "$min_age" -ge 0 ] || min_age=0
  fi
  printf '%s\n' "$((min_age / 86400))"
}

while IFS= read -r project; do
  [ -n "$project" ] || continue
  repo="$FM_HOME/projects/$project"
  age_days=$(project_age "$project")
  reasons=
  warnings=
  if is_whitelisted "$project"; then
    reasons='静态或配置白名单'
  fi
  if meta_project_active "$project"; then
    reasons=$(append_text "$reasons" '存在进行中的任务或活跃的二副')
  fi
  flags=$(backlog_flags "$project")
  case ",$flags," in *,in_flight,*) reasons=$(append_text "$reasons" '任务清单中有进行中的工作') ;; esac
  case ",$flags," in *,queued,*) reasons=$(append_text "$reasons" '任务清单中有排队的交付或文档工作') ;; esac
  case ",$flags," in *,decision,*) reasons=$(append_text "$reasons" '存在待船长决定的事项') ;; esac
  beads_result=none
  if open_beads_decision "$repo"; then
    beads_result=open
    reasons=$(append_text "$reasons" '存在未解决的 Beads 决策')
  else
    beads_code=$?
    [ "$beads_code" -ne 2 ] || warnings=$(append_text "$warnings" 'Beads 决策状态未知')
  fi
  safety=$(clone_safety "$repo")
  case "$safety" in
    dirty) reasons=$(append_text "$reasons" '本地副本有未提交更改') ;;
    unpushed\ commits) reasons=$(append_text "$reasons" '本地副本有未推送提交') ;;
    'unknown (no local clone)') warnings=$(append_text "$warnings" '本地副本不存在，安全状态未知') ;;
    'unknown (git unavailable)') warnings=$(append_text "$warnings" 'Git 不可用，本地副本安全状态未知') ;;
    'unknown (not a git clone)') warnings=$(append_text "$warnings" '本地目录不是 Git 副本，安全状态未知') ;;
    'unknown (git status failed)') warnings=$(append_text "$warnings" 'Git 状态检查失败，本地副本安全状态未知') ;;
    'unknown (branch comparison failed)') warnings=$(append_text "$warnings" '分支比较失败，本地副本安全状态未知') ;;
    'unknown (no tracked branch)') warnings=$(append_text "$warnings" '没有跟踪分支，本地副本安全状态未知') ;;
    unknown*) warnings=$(append_text "$warnings" '本地副本安全状态未知') ;;
  esac
  prs=$(pr_status "$repo")
  case "$prs" in
    open) reasons=$(append_text "$reasons" '存在开放的 PR，请先合并或关闭') ;;
    'unknown (not checked)') warnings=$(append_text "$warnings" '未检查 PR 状态') ;;
    'unknown (gh-axi unavailable)') warnings=$(append_text "$warnings" 'gh-axi 不可用，PR 状态未知') ;;
    'unknown (no GitHub origin)') warnings=$(append_text "$warnings" '没有 GitHub 来源，PR 状态未知') ;;
    'unknown (PR check failed)') warnings=$(append_text "$warnings" 'PR 检查失败，状态未知') ;;
    'unknown (unrecognized PR result)') warnings=$(append_text "$warnings" '无法识别 PR 检查结果，状态未知') ;;
    unknown*) warnings=$(append_text "$warnings" 'PR 状态未知') ;;
  esac

  if [ -n "$reasons" ]; then
    printf '%s\t%s\t%s\t%s\n' "$project" "$age_days" '强制排除' "$reasons${warnings:+；$warnings}" >> "$B_APPENDIX"
  elif [ "$age_days" -lt 30 ]; then
    printf '%s\t%s\t%s\t%s\n' "$project" "$age_days" '未达到闲置阈值' "${warnings:-近期有活动}" >> "$B_APPENDIX"
  elif [ "$age_days" -ge 45 ] && [ -z "$warnings" ] && [ "$prs" = none ]; then
    printf '%s\t%s\t[x]\t2\t已闲置至少 45 天；已预选本地放弃\n' "$project" "$age_days" >> "$B_MAIN"
  elif [ "$age_days" -ge 45 ]; then
    printf '%s\t%s\t[ ]\t2\t已闲置至少 45 天；未预选：%s\n' "$project" "$age_days" "${warnings:-PR 状态未知}" >> "$B_MAIN"
  else
    printf '%s\t%s\t[ ]\t观察\t已闲置 30 至 44 天\n' "$project" "$age_days" >> "$B_MAIN"
  fi
  : "$beads_result"
done < "$PROJECTS"

TODAY=$(format_day "$NOW")
{
  printf '# 舰队卫生审计 - %s\n\n' "$TODAY"
  printf "这是依据 \`docs/fleet-hygiene.md\` 生成的只读检查清单。\n"
  printf '本次审计未更改任何 treehouse 槽位、项目、任务、决策、数据文件、本地副本或 GitHub 仓库。\n\n'
  printf '## A 层 - 可安全处置的 treehouse 候选项\n\n'
  printf '| 选择 | 池 | 槽位 | 路径 | 空闲时间 | 大小 | 分类 | 候选规则 |\n'
  printf '|---|---|---|---|---:|---:|---|---|\n'
  if [ -s "$A_CANDIDATES" ]; then
    LC_ALL=C sort -t $'\t' -k8,8 -k5,5nr -k7,7nr -k3,3 "$A_CANDIDATES" \
      | while IFS=$'\t' read -r pool slot path class age_seconds age_days size_kib route; do
          : "$age_seconds"
          printf "| [x] | %s | %s | \`%s\` | %s 天 | %s | %s | %s |\n" \
            "$(markdown_escape "$pool")" "$(markdown_escape "$slot")" "$(markdown_escape "$path")" \
            "$age_days" "$(format_size "$size_kib")" "$(slot_class_label "$class")" "$(candidate_route_label "$route")"
        done
  else
    printf '|  |  |  | 没有可安全处置的候选项 |  |  |  |  |\n'
  fi
  printf '\n## B 层 - 闲置项目候选项\n\n'
  printf '| 选择 | 项目 | 闲置时间 | 建议级别 | 原因 |\n'
  printf '|---|---|---:|---:|---|\n'
  if [ -s "$B_MAIN" ]; then
    LC_ALL=C sort -t $'\t' -k2,2nr -k1,1 "$B_MAIN" \
      | while IFS=$'\t' read -r project age_days select tier reason; do
          printf '| %s | %s | %s 天 | %s | %s |\n' \
            "$select" "$(markdown_escape "$project")" "$age_days" "$tier" "$(markdown_escape "$reason")"
        done
  else
    printf '|  | 没有通过强制排除检查的闲置项目 |  |  |  |\n'
  fi
  printf '\n级别 2 表示在保留本地副本和 GitHub 远端仓库的前提下，在本地放弃该项目。\n'
  printf '本次审计不会执行级别 1、2 或 3 的任何操作。\n\n'
  printf '## 附录 - 已排除、已保留和未达到阈值的项目\n\n'
  printf '### A 层\n\n'
  printf '| 池 | 槽位 | 路径 | 空闲时间 | 大小 | 分类 | 原因 |\n'
  printf '|---|---|---|---:|---:|---|---|\n'
  if [ -s "$A_APPENDIX" ]; then
    LC_ALL=C sort -t $'\t' -k1,1 -k5,5nr -k3,3 "$A_APPENDIX" \
      | while IFS=$'\t' read -r pool slot path class age_seconds age_days size_kib reason; do
          : "$age_seconds"
          printf "| %s | %s | \`%s\` | %s 天 | %s | %s | %s |\n" \
            "$(markdown_escape "$pool")" "$(markdown_escape "$slot")" "$(markdown_escape "$path")" \
            "$age_days" "$(format_size "$size_kib")" "$(slot_class_label "$class")" "$(markdown_escape "$reason")"
        done
  else
    printf '|  |  | 没有已排除或因配额保留的槽位 |  |  |  |  |\n'
  fi
  printf '\n### B 层\n\n'
  printf '| 项目 | 闲置时间 | 处理结论 | 原因 |\n'
  printf '|---|---:|---|---|\n'
  if [ -s "$B_APPENDIX" ]; then
    LC_ALL=C sort -t $'\t' -k2,2nr -k1,1 "$B_APPENDIX" \
      | while IFS=$'\t' read -r project age_days disposition reason; do
          printf '| %s | %s 天 | %s | %s |\n' \
            "$(markdown_escape "$project")" "$age_days" "$(markdown_escape "$disposition")" "$(markdown_escape "$reason")"
        done
  else
    printf '|  |  | 没有已排除或未达到阈值的项目 |  |\n'
  fi
  printf '\n## 如何回复\n\n'
  printf '请选择希望后续处理的 A 层池/槽位行和 B 层项目/级别行。\n'
  printf '清理属于后续独立指令；进行任何更改前都必须重新执行安全检查。\n'
} > "$REPORT"

cat "$REPORT"
if [ "$WRITE" -eq 1 ]; then
  REPORT_DIR="$FM_HOME/data/hygiene"
  if [ -z "$OUTPUT" ]; then
    OUTPUT="$REPORT_DIR/report-$TODAY.md"
  fi
  if [ "$(dirname "$OUTPUT")" != "$REPORT_DIR" ] || [ "${OUTPUT##*.}" != md ]; then
    printf 'fm-fleet-hygiene-audit: output must be a .md file directly inside %s\n' "$REPORT_DIR" >&2
    exit 1
  fi
  if [ -L "$FM_HOME/data" ] || [ -L "$REPORT_DIR" ] || [ -L "$OUTPUT" ]; then
    printf 'fm-fleet-hygiene-audit: refusing symbolic-link output path: %s\n' "$OUTPUT" >&2
    exit 1
  fi
  if ! mkdir -p "$REPORT_DIR"; then
    printf 'fm-fleet-hygiene-audit: could not create output directory for %s\n' "$OUTPUT" >&2
    exit 1
  fi
  if ! cp "$REPORT" "$OUTPUT"; then
    printf 'fm-fleet-hygiene-audit: could not write %s\n' "$OUTPUT" >&2
    exit 1
  fi
  printf 'fm-fleet-hygiene-audit: wrote %s\n' "$OUTPUT" >&2
fi
