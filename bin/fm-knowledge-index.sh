#!/usr/bin/env bash
# Build and query the physically source-isolated keyword knowledge projection.
# docs/knowledge-index.md is the single owner of the registry, storage, safety,
# provenance, sync, query, and removal contracts implemented here.
#
# Usage:
#   fm-knowledge-index.sh validate [--json]
#   fm-knowledge-index.sh sync --source <id> [--json]
#   fm-knowledge-index.sh search --source <id> [--source <id> ...] --query <text> [--limit <n>] [--json]
#   fm-knowledge-index.sh status --source <id> [--json]
#   fm-knowledge-index.sh remove --source <id> --confirm <id> [--json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$CONFIG/knowledge-sources.json"
INDEX_DIR="$STATE/knowledge-indexes"
REGISTRY_SCHEMA="firstmate.knowledge-sources.v1"
JSON=0
TEMP_FILES=()
TEMP_DIRS=()
SOURCE_OPERATION_LOCK_FD=

cleanup() {
  local file directory
  for file in "${TEMP_FILES[@]:-}"; do
    [ -n "$file" ] && rm -f -- "$file"
  done
  for directory in "${TEMP_DIRS[@]:-}"; do
    [ -n "$directory" ] && rm -rf -- "$directory"
  done
  return 0
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
usage:
  fm-knowledge-index.sh validate [--json]
  fm-knowledge-index.sh sync --source <id> [--json]
  fm-knowledge-index.sh search --source <id> [--source <id> ...] --query <text> [--limit <n>] [--json]
  fm-knowledge-index.sh status --source <id> [--json]
  fm-knowledge-index.sh remove --source <id> --confirm <id> [--json]

The registry is config/knowledge-sources.json in the selected FM_HOME.
Search has no default, wildcard, all-sources, or implicit federation mode.
See docs/knowledge-index.md for the versioned registry and index contracts.
EOF
}

die() {
  local message=$1
  if [ "$JSON" -eq 1 ] && command -v jq >/dev/null 2>&1; then
    jq -cn --arg error "$message" \
      '{schema:"fm-knowledge-index.error.v1",error:$error}'
  else
    printf 'fm-knowledge-index: %s\n' "$message" >&2
  fi
  exit 1
}

require_tools() {
  local tool
  for tool in jq sqlite3 find sort git python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
  done
  if command -v shasum >/dev/null 2>&1; then
    HASH_TOOL=shasum
  elif command -v sha256sum >/dev/null 2>&1; then
    HASH_TOOL=sha256sum
  else
    die "shasum or sha256sum not found"
  fi
  if ! sqlite3 ':memory:' \
    "CREATE VIRTUAL TABLE fts_probe USING fts5(body); DROP TABLE fts_probe;" \
    >/dev/null 2>&1; then
    die "SQLite FTS5 is unavailable; install a sqlite3 build with ENABLE_FTS5"
  fi
  if ! sqlite3 ':memory:' "SELECT json_valid('{}');" >/dev/null 2>&1; then
    die "SQLite JSON functions are unavailable; install a current sqlite3 build"
  fi
}

has_control() {
  LC_ALL=C printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

validate_pattern() {
  local pattern=$1 kind=$2 lower segment
  local -a segments=()
  [ -n "$pattern" ] || die "$kind pattern must not be empty"
  has_control "$pattern" && die "$kind pattern contains a control character"
  case "$pattern" in
    /*|./*|*//*|*\\*|*'['*|*']'*) die "unsafe $kind pattern: $pattern" ;;
  esac
  IFS='/' read -r -a segments <<< "$pattern"
  for segment in "${segments[@]}"; do
    case "$segment" in
      ''|.|..) die "unsafe $kind pattern segment in: $pattern" ;;
    esac
  done
  if [ "$kind" = allow ]; then
    lower=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      *.md|*.markdown) ;;
      *) die "allow pattern is not Markdown: $pattern" ;;
    esac
  fi
}

validate_registry_structure() {
  local pattern index other_index root other_root
  local -a roots=()
  [ -f "$REGISTRY" ] || die "registry not found: $REGISTRY"
  [ ! -L "$REGISTRY" ] || die "registry must not be a symlink: $REGISTRY"
  if ! jq -e --arg schema "$REGISTRY_SCHEMA" '
    type == "object" and
    (keys | sort) == ["schema", "sources"] and
    .schema == $schema and
    (.sources | type == "array") and
    (all(.sources[];
      type == "object" and
      ((keys | sort) == ["deny", "id", "markdown_allow", "owner", "privacy", "root"] or
       (keys | sort) == ["deny", "id", "markdown_allow", "owner", "privacy", "repo", "root"]) and
      (.id | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$") and . != "all") and
      (.root | type == "string" and startswith("/") and length > 1 and
        (test("[[:cntrl:]]") | not)) and
      (.owner | type == "string" and test("[^[:space:]]") and
        (test("[[:cntrl:]]") | not)) and
      (.privacy == "public" or .privacy == "repo-private" or
       .privacy == "fleet-private" or .privacy == "captain-private") and
      (.markdown_allow | type == "array" and length > 0 and
        all(.[]; type == "string" and (test("[[:cntrl:]]") | not))) and
      (.deny | type == "array" and
        all(.[]; type == "string" and (test("[[:cntrl:]]") | not))) and
      ((has("repo") | not) or
        (.repo | type == "string" and test("[^[:space:]]") and
          (test("[[:cntrl:]]") | not)))
    )) and
    ([.sources[].id] | length == (unique | length)) and
    ([.sources[].root] | length == (unique | length))
  ' "$REGISTRY" >/dev/null 2>&1; then
    die "registry does not satisfy $REGISTRY_SCHEMA"
  fi
  while IFS= read -r pattern; do
    validate_pattern "$pattern" allow
  done < <(jq -r '.sources[].markdown_allow[]' "$REGISTRY")
  while IFS= read -r pattern; do
    validate_pattern "$pattern" deny
  done < <(jq -r '.sources[].deny[]' "$REGISTRY")
  while IFS= read -r root; do
    roots+=("$root")
  done < <(jq -r '.sources[].root' "$REGISTRY")
  for ((index=0; index<${#roots[@]}; index++)); do
    root=${roots[$index]}
    for ((other_index=index + 1; other_index<${#roots[@]}; other_index++)); do
      other_root=${roots[$other_index]}
      case "$root/" in
        "$other_root/"*) die "source roots must not overlap: $root and $other_root" ;;
      esac
      case "$other_root/" in
        "$root/"*) die "source roots must not overlap: $root and $other_root" ;;
      esac
    done
  done
}

source_exists() {
  [ "$(jq -r --arg id "$1" '[.sources[] | select(.id == $id)] | length' "$REGISTRY")" -eq 1 ]
}

validate_source_id() {
  case "$1" in
    ''|all|*[!a-z0-9-]*|-*|*-) die "invalid source id: $1" ;;
  esac
  [ "${#1}" -le 63 ] || die "invalid source id: $1"
  source_exists "$1" || die "unknown source: $1"
}

source_field() {
  jq -er --arg id "$1" --arg field "$2" \
    '.sources[] | select(.id == $id) | .[$field] // empty' "$REGISTRY"
}

source_repo() {
  jq -r --arg id "$1" '.sources[] | select(.id == $id) | .repo // ""' "$REGISTRY"
}

validate_source_root() {
  local id=$1 root physical
  root=$(source_field "$id" root)
  [ -d "$root" ] || die "source root is not an existing directory for $id: $root"
  [ ! -L "$root" ] || die "source root must not be a symlink for $id: $root"
  physical=$(cd "$root" 2>/dev/null && pwd -P) \
    || die "cannot resolve source root for $id: $root"
  [ "$physical" = "$root" ] \
    || die "source root is not its canonical physical path for $id: $root"
}

validate_all_roots() {
  local id physical index other_index root other_root
  local -a roots=()
  while IFS= read -r id; do
    validate_source_root "$id"
    root=$(source_field "$id" root)
    physical=$(cd "$root" 2>/dev/null && pwd -P) \
      || die "cannot resolve source root for $id: $root"
    roots+=("$physical")
  done < <(jq -r '.sources[].id' "$REGISTRY")
  for ((index=0; index<${#roots[@]}; index++)); do
    root=${roots[$index]}
    for ((other_index=index + 1; other_index<${#roots[@]}; other_index++)); do
      other_root=${roots[$other_index]}
      case "$root/" in
        "$other_root/"*) die "source roots must not overlap: $root and $other_root" ;;
      esac
      case "$other_root/" in
        "$root/"*) die "source roots must not overlap: $root and $other_root" ;;
      esac
    done
  done
}

snapshot_source_tree() {
  local root=$1 allows_json=$2 denies_json=$3 snapshot_dir=$4 file_list=$5 identity_file=$6
  python3 - "$root" "$allows_json" "$denies_json" "$snapshot_dir" "$file_list" "$identity_file" <<'PY'
import fnmatch
import json
import os
import stat
import sys
import time

try:
    root, allows_json, denies_json, snapshot_dir, file_list, identity_file = sys.argv[1:]
    allows = json.loads(allows_json)
    denies = json.loads(denies_json)
    directory_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in root.split("/")[1:]:
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
            os.close(directory_fd)
            directory_fd = next_fd

        root_stat = os.fstat(directory_fd)

        candidates = []

        def denied(path):
            wrapped = "/" + path + "/"
            basename = path.rsplit("/", 1)[-1]
            if basename == ".env" or basename.startswith(".env."):
                return True
            if basename in {
                "backlog.md", "secret.md", "secrets.md", "credential.md",
                "credentials.md", "feedback.md",
            } or "generated-feedback" in basename:
                return True
            if path == "data/captain.md" or fnmatch.fnmatchcase(path, "*/data/captain.md"):
                return True
            if fnmatch.fnmatchcase(path, "data/*/brief.md") or fnmatch.fnmatchcase(path, "*/data/*/brief.md"):
                return True
            for segment in {
                "secret", "secrets", "credential", "credentials", "backlogs",
                ".lavish", "generated", "feedback", "node_modules", "vendor",
                "build", "dist", "out", "target", "coverage", ".next",
            }:
                if f"/{segment}/" in wrapped:
                    return True
            return any(fnmatch.fnmatchcase(path, pattern) for pattern in denies)

        def enumerate_directory(parent_fd, prefix=""):
            with os.scandir(parent_fd) as entries:
                ordered = sorted(entries, key=lambda entry: os.fsencode(entry.name))
            for entry in ordered:
                path = entry.name if not prefix else prefix + "/" + entry.name
                try:
                    if entry.is_symlink():
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        child_fd = os.open(
                            entry.name,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=parent_fd,
                        )
                        try:
                            enumerate_directory(child_fd, path)
                        finally:
                            os.close(child_fd)
                    elif entry.is_file(follow_symlinks=False):
                        lower = entry.name.lower()
                        if not (lower.endswith(".md") or lower.endswith(".markdown")):
                            continue
                        if not any(fnmatch.fnmatchcase(path, pattern) for pattern in allows):
                            continue
                        if not denied(path):
                            candidates.append(path)
                except FileNotFoundError:
                    raise OSError("source changed during enumeration")

        enumerate_directory(directory_fd)
        gate = os.environ.get("FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_SNAPSHOT")
        if gate:
            open(gate + ".ready", "w", encoding="utf-8").close()
            while not os.path.exists(gate + ".release"):
                time.sleep(0.01)

        with open(file_list, "wb") as output:
            for ordinal, relative_path in enumerate(candidates, 1):
                current_fd = os.dup(directory_fd)
                parts = relative_path.split("/")
                try:
                    for part in parts[:-1]:
                        next_fd = os.open(
                            part,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=current_fd,
                        )
                        os.close(current_fd)
                        current_fd = next_fd
                    source_fd = os.open(
                        parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=current_fd
                    )
                    try:
                        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
                            raise OSError("source is not a regular file")
                        snapshot = os.path.join(snapshot_dir, f"{ordinal}.md")
                        destination_fd = os.open(
                            snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
                        )
                        try:
                            while True:
                                chunk = os.read(source_fd, 1024 * 1024)
                                if not chunk:
                                    break
                                view = memoryview(chunk)
                                while view:
                                    written = os.write(destination_fd, view)
                                    view = view[written:]
                            os.fsync(destination_fd)
                        finally:
                            os.close(destination_fd)
                    finally:
                        os.close(source_fd)
                finally:
                    os.close(current_fd)
                output.write(os.fsencode(relative_path) + b"\0")
                output.write(os.fsencode(snapshot) + b"\0")

        verification_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in root.split("/")[1:]:
                next_fd = os.open(
                    part,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=verification_fd,
                )
                os.close(verification_fd)
                verification_fd = next_fd
            verification_stat = os.fstat(verification_fd)
            if (verification_stat.st_dev, verification_stat.st_ino) != (
                root_stat.st_dev,
                root_stat.st_ino,
            ):
                raise OSError("registered source root changed during snapshot")
        finally:
            os.close(verification_fd)

        with open(identity_file, "w", encoding="ascii") as identity:
            identity.write(f"{root_stat.st_dev} {root_stat.st_ino}\n")
            identity.flush()
            os.fsync(identity.fileno())
    finally:
        os.close(directory_fd)
except OSError:
    sys.exit(1)
PY
}

verify_source_root_identity() {
  local root=$1 identity_file=$2
  python3 - "$root" "$identity_file" <<'PY'
import os
import sys

try:
    root, identity_file = sys.argv[1:]
    with open(identity_file, "r", encoding="ascii") as identity:
        expected = tuple(int(value) for value in identity.read().split())
    if len(expected) != 2:
        raise OSError("invalid source root identity")
    directory_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in root.split("/")[1:]:
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
            os.close(directory_fd)
            directory_fd = next_fd
        current = os.fstat(directory_fd)
        if (current.st_dev, current.st_ino) != expected:
            raise OSError("registered source root no longer matches snapshot")
    finally:
        os.close(directory_fd)
except (OSError, ValueError):
    sys.exit(1)
PY
}

hash_file() {
  if [ "$HASH_TOOL" = shasum ]; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    sha256sum -- "$1" | awk '{print $1}'
  fi
}

glob_matches() {
  local path=$1 pattern=$2
  # shellcheck disable=SC2053
  [[ "$path" == $pattern ]]
}

built_in_denied() {
  local path=$1 wrapped="/$1/"
  case "$path" in
    .env|.env.*|*/.env|*/.env.*) return 0 ;;
    backlog.md|*/backlog.md|secret.md|*/secret.md|secrets.md|*/secrets.md|credential.md|*/credential.md|credentials.md|*/credentials.md) return 0 ;;
    data/captain.md|*/data/captain.md|data/*/brief.md|*/data/*/brief.md) return 0 ;;
    feedback.md|*/feedback.md|*generated-feedback*.md) return 0 ;;
  esac
  case "$wrapped" in
    */secret/*|*/secrets/*|*/credential/*|*/credentials/*|*/backlogs/*|*/.lavish/*|*/generated/*|*/feedback/*|*/node_modules/*|*/vendor/*|*/build/*|*/dist/*|*/out/*|*/target/*|*/coverage/*|*/.next/*) return 0 ;;
  esac
  return 1
}

safe_relative_path() {
  local path=$1 segment
  local -a segments=()
  [ -n "$path" ] || return 1
  case "$path" in /*|*//*) return 1 ;; esac
  has_control "$path" && return 1
  IFS='/' read -r -a segments <<< "$path"
  for segment in "${segments[@]}"; do
    case "$segment" in ''|.|..) return 1 ;; esac
  done
  return 0
}

ensure_index_dir() {
  mkdir -p -- "$INDEX_DIR"
  [ -d "$INDEX_DIR" ] || die "cannot create index directory: $INDEX_DIR"
  [ ! -L "$INDEX_DIR" ] || die "index directory must not be a symlink: $INDEX_DIR"
  chmod 700 "$INDEX_DIR"
}

database_path() {
  printf '%s/%s.sqlite3\n' "$INDEX_DIR" "$1"
}

coordinate_source_operation() {
  local id=$1 lock_file
  ensure_index_dir
  lock_file="$INDEX_DIR/.$id.operation.lock"
  [ ! -L "$lock_file" ] \
    || die "source operation lock is not a regular file for $id"
  if [ -e "$lock_file" ]; then
    [ -f "$lock_file" ] \
      || die "source operation lock is not a regular file for $id"
  else
    (umask 077; : > "$lock_file") \
      || die "cannot create source operation lock for $id"
  fi
  chmod 600 "$lock_file"
  exec {SOURCE_OPERATION_LOCK_FD}> "$lock_file" \
    || die "cannot open source operation lock for $id"
  if command -v flock >/dev/null 2>&1; then
    flock -x "$SOURCE_OPERATION_LOCK_FD" \
      || die "cannot acquire source operation lock for $id"
  elif command -v lockf >/dev/null 2>&1; then
    lockf "$SOURCE_OPERATION_LOCK_FD" \
      || die "cannot acquire source operation lock for $id"
  else
    die "flock or lockf not found; cannot coordinate source operation for $id"
  fi
}

validate_database() {
  local id=$1 db=$2 stored integrity
  [ -f "$db" ] || die "index not found for $id; run sync --source $id"
  [ ! -L "$db" ] || die "index database must not be a symlink for $id"
  stored=$(sqlite3 -readonly "$db" \
    "SELECT value FROM metadata WHERE key = 'source_id';" 2>/dev/null) \
    || die "cannot read index metadata for $id"
  [ "$stored" = "$id" ] || die "index metadata does not match selected source $id"
  integrity=$(sqlite3 -readonly "$db" "PRAGMA quick_check;" 2>/dev/null) \
    || die "cannot check index integrity for $id"
  [ "$integrity" = ok ] || die "index integrity check failed for $id"
}

command_validate() {
  local payload
  validate_registry_structure
  validate_all_roots
  payload=$(jq -c --arg registry "$REGISTRY" '
    {
      schema: "fm-knowledge-index.registry-validation.v1",
      registry: $registry,
      valid: true,
      sources: [.sources[] | {
        id, root, owner, privacy,
        markdown_allow, deny,
        repo: (.repo // null)
      }] | sort_by(.id)
    }
  ' "$REGISTRY")
  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$payload"
  else
    printf 'valid %s (%s sources)\n' "$REGISTRY" \
      "$(printf '%s' "$payload" | jq -r '.sources | length')"
  fi
}

command_sync() {
  local id=$1 root owner privacy repo commit indexed_at db tmp_db lines manifest file_list
  local rel physical sha count manifest_sql integrity allows_json denies_json
  local snapshot_dir snapshot root_identity
  local -a allows=() denies=()
  validate_registry_structure
  validate_source_id "$id"
  validate_all_roots
  ensure_index_dir
  root=$(source_field "$id" root)
  owner=$(source_field "$id" owner)
  privacy=$(source_field "$id" privacy)
  repo=$(source_repo "$id")
  commit=""
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    commit=$(git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
    case "$commit" in ''|*[!0-9a-fA-F]*) commit="" ;; esac
  fi
  indexed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  while IFS= read -r pattern; do allows+=("$pattern"); done \
    < <(jq -r --arg id "$id" '.sources[] | select(.id == $id) | .markdown_allow[]' "$REGISTRY")
  while IFS= read -r pattern; do denies+=("$pattern"); done \
    < <(jq -r --arg id "$id" '.sources[] | select(.id == $id) | .deny[]' "$REGISTRY")
  allows_json=$(jq -c --arg id "$id" '.sources[] | select(.id == $id) | .markdown_allow' "$REGISTRY")
  denies_json=$(jq -c --arg id "$id" '.sources[] | select(.id == $id) | .deny' "$REGISTRY")

  lines=$(mktemp "$INDEX_DIR/.knowledge-manifest-lines.XXXXXX")
  manifest=$(mktemp "$INDEX_DIR/.knowledge-manifest.XXXXXX")
  file_list=$(mktemp "$INDEX_DIR/.knowledge-files.XXXXXX")
  root_identity=$(mktemp "$INDEX_DIR/.knowledge-root-identity.XXXXXX")
  tmp_db=$(mktemp "$INDEX_DIR/.$id.sqlite3.tmp.XXXXXX")
  snapshot_dir=$(mktemp -d "$INDEX_DIR/.knowledge-snapshot.XXXXXX")
  TEMP_FILES+=("$lines" "$manifest" "$file_list" "$root_identity" "$tmp_db")
  TEMP_DIRS+=("$snapshot_dir")

  snapshot_source_tree "$root" "$allows_json" "$denies_json" "$snapshot_dir" "$file_list" "$root_identity" \
    || die "cannot safely snapshot source tree for $id; previous index preserved"

  while IFS= read -r -d '' rel && IFS= read -r -d '' snapshot; do
    safe_relative_path "$rel" || die "unsafe relative path under $id"
    physical="$root/$rel"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] \
      || die "source file changed into a symlink while syncing: $rel"
    sha=$(hash_file "$snapshot") || die "cannot hash source file: $rel"
    jq -cn \
      --arg relative_path "$rel" \
      --arg absolute_path "$physical" \
      --arg content_path "$snapshot" \
      --arg content_sha256 "$sha" \
      '{relative_path:$relative_path,absolute_path:$absolute_path,content_path:$content_path,content_sha256:$content_sha256}' \
      >> "$lines"
  done < "$file_list"

  jq -n \
    --arg source_id "$id" \
    --arg owner "$owner" \
    --arg privacy "$privacy" \
    --arg source_root "$root" \
    --arg repo "$repo" \
    --arg commit "$commit" \
    --arg indexed_at "$indexed_at" \
    --slurpfile documents "$lines" \
    '{
      source_id:$source_id,
      owner:$owner,
      privacy:$privacy,
      source_root:$source_root,
      repo:$repo,
      commit:$commit,
      indexed_at:$indexed_at,
      documents:($documents | sort_by(.relative_path))
    }' > "$manifest"
  [ -s "$manifest" ] || die "cannot create sync manifest for $id; previous index preserved"

  manifest_sql=${manifest//\'/\'\'}
  if ! sqlite3 \
    -cmd '.parameter init' \
    -cmd ".parameter set :manifest_path \"'$manifest_sql'\"" \
    -cmd '.parameter set :manifest "CAST(readfile(:manifest_path) AS TEXT)"' \
    "$tmp_db" <<'SQL'
.bail on
PRAGMA synchronous = FULL;
BEGIN IMMEDIATE;
CREATE TEMP TABLE manifest_input (
  payload TEXT NOT NULL CHECK(json_valid(payload))
);
INSERT INTO manifest_input(payload)
VALUES(:manifest);
CREATE TABLE metadata (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE documents (
  rowid INTEGER PRIMARY KEY,
  relative_path TEXT NOT NULL UNIQUE,
  absolute_path TEXT NOT NULL UNIQUE,
  source_id TEXT NOT NULL,
  owner TEXT NOT NULL,
  privacy_class TEXT NOT NULL,
  source_root TEXT NOT NULL,
  repo_identity TEXT,
  commit_sha TEXT,
  content_sha256 TEXT NOT NULL,
  indexed_at TEXT NOT NULL,
  content TEXT NOT NULL
);
CREATE VIRTUAL TABLE documents_fts USING fts5(
  relative_path,
  content,
  content = 'documents',
  content_rowid = 'rowid',
  tokenize = 'unicode61 remove_diacritics 2'
);
INSERT INTO metadata(key, value)
SELECT 'schema', 'fm-knowledge-index.sqlite.v1'
UNION ALL SELECT 'source_id', json_extract(payload, '$.source_id') FROM manifest_input
UNION ALL SELECT 'owner', json_extract(payload, '$.owner') FROM manifest_input
UNION ALL SELECT 'privacy_class', json_extract(payload, '$.privacy') FROM manifest_input
UNION ALL SELECT 'source_root', json_extract(payload, '$.source_root') FROM manifest_input
UNION ALL SELECT 'repo_identity', COALESCE(json_extract(payload, '$.repo'), '') FROM manifest_input
UNION ALL SELECT 'commit_sha', COALESCE(json_extract(payload, '$.commit'), '') FROM manifest_input
UNION ALL SELECT 'indexed_at', json_extract(payload, '$.indexed_at') FROM manifest_input;
INSERT INTO documents(
  relative_path, absolute_path, source_id, owner, privacy_class,
  source_root, repo_identity, commit_sha, content_sha256, indexed_at, content
)
SELECT
  json_extract(document.value, '$.relative_path'),
  json_extract(document.value, '$.absolute_path'),
  json_extract(manifest.payload, '$.source_id'),
  json_extract(manifest.payload, '$.owner'),
  json_extract(manifest.payload, '$.privacy'),
  json_extract(manifest.payload, '$.source_root'),
  NULLIF(json_extract(manifest.payload, '$.repo'), ''),
  NULLIF(json_extract(manifest.payload, '$.commit'), ''),
  json_extract(document.value, '$.content_sha256'),
  json_extract(manifest.payload, '$.indexed_at'),
  CAST(readfile(json_extract(document.value, '$.content_path')) AS TEXT)
FROM manifest_input AS manifest,
  json_each(json_extract(manifest.payload, '$.documents')) AS document;
INSERT INTO documents_fts(documents_fts) VALUES('rebuild');
COMMIT;
SQL
  then
    die "sync failed while building source $id; previous index preserved"
  fi
  integrity=$(sqlite3 -readonly "$tmp_db" "PRAGMA integrity_check;" 2>/dev/null) \
    || die "sync integrity check failed for $id; previous index preserved"
  [ "$integrity" = ok ] \
    || die "sync integrity check failed for $id; previous index preserved"
  if ! count=$(sqlite3 -readonly "$tmp_db" "SELECT count(*) FROM documents;" 2>&1); then
    die "cannot count rebuilt index for $id; previous index preserved: $count"
  fi
  if [ "${FM_KNOWLEDGE_INDEX_TEST_FAIL_BEFORE_PUBLISH:-0}" = 1 ]; then
    die "injected pre-publish sync failure for $id; previous index preserved"
  fi
  if [ -n "${FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_PUBLISH:-}" ]; then
    : > "$FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_PUBLISH.ready"
    while [ ! -e "$FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_PUBLISH.release" ]; do
      sleep 0.01
    done
  fi
  verify_source_root_identity "$root" "$root_identity" \
    || die "source root changed before publishing $id; previous index preserved"
  chmod 600 "$tmp_db"
  db=$(database_path "$id")
  mv -f -- "$tmp_db" "$db"
  chmod 600 "$db"
  if [ "$JSON" -eq 1 ]; then
    jq -cn \
      --arg source "$id" --arg database "$db" --arg indexed_at "$indexed_at" \
      --argjson documents "$count" \
      '{schema:"fm-knowledge-index.sync.v1",source:$source,database:$database,documents:$documents,indexed_at:$indexed_at}'
  else
    printf 'synced %s: %s documents -> %s\n' "$id" "$count" "$db"
  fi
}

compile_fts_query() {
  local input=$1 cleaned token escaped compiled=""
  local -a tokens=()
  [ -n "$input" ] || die "search query must not be empty"
  [ "${#input}" -le 4096 ] || die "search query exceeds 4096 characters"
  cleaned=$(printf '%s' "$input" | tr '\r\n\t' '   ')
  read -r -a tokens <<< "$cleaned"
  [ "${#tokens[@]}" -gt 0 ] || die "search query has no tokens"
  for token in "${tokens[@]}"; do
    escaped=${token//\"/\"\"}
    compiled="${compiled}${compiled:+ AND }\"${escaped}\"*"
  done
  printf '%s' "$compiled"
}

command_search() {
  local query=$1 limit=$2 result_file query_file compiled id db rows error_file
  local sources_json results_json query_sql seen_id
  shift 2
  local -a sources=("$@") seen=()
  validate_registry_structure
  [ "${#sources[@]}" -gt 0 ] || die "search requires at least one explicit --source"
  case "$limit" in ''|*[!0-9]*) die "limit must be an integer from 1 to 100" ;; esac
  [ "$limit" -ge 1 ] && [ "$limit" -le 100 ] \
    || die "limit must be an integer from 1 to 100"
  compiled=$(compile_fts_query "$query")
  ensure_index_dir
  result_file=$(mktemp "$INDEX_DIR/.knowledge-search-results.XXXXXX")
  query_file=$(mktemp "$INDEX_DIR/.knowledge-search-query.XXXXXX")
  error_file=$(mktemp "$INDEX_DIR/.knowledge-search-error.XXXXXX")
  TEMP_FILES+=("$result_file" "$query_file" "$error_file")
  printf '%s' "$compiled" > "$query_file"
  for id in "${sources[@]}"; do
    validate_source_id "$id"
    for seen_id in "${seen[@]:-}"; do
      [ -n "$seen_id" ] || continue
      [ "$seen_id" != "$id" ] || die "duplicate selected source: $id"
    done
    seen+=("$id")
    db=$(database_path "$id")
    validate_database "$id" "$db"
    query_sql=${query_file//\'/\'\'}
    if ! rows=$(sqlite3 -readonly -json \
      -cmd '.parameter init' \
      -cmd ".parameter set :query_path \"'$query_sql'\"" \
      -cmd '.parameter set :query "CAST(readfile(:query_path) AS TEXT)"' \
      -cmd ".parameter set :limit $limit" \
      "$db" \
      "SELECT
         d.source_id,
         d.owner,
         d.privacy_class,
         d.relative_path,
         d.absolute_path,
         d.repo_identity,
         d.commit_sha,
         d.content_sha256,
         d.indexed_at,
         d.source_root,
         bm25(documents_fts) AS rank,
         snippet(documents_fts, 1, '', '', ' ... ', 24) AS snippet
       FROM documents_fts
       JOIN documents AS d ON d.rowid = documents_fts.rowid
       WHERE documents_fts MATCH :query
       ORDER BY rank, d.relative_path
       LIMIT :limit;" 2>"$error_file"); then
      die "safe FTS query failed for source $id"
    fi
    [ -n "$rows" ] || rows='[]'
    printf '%s\n' "$rows" >> "$result_file"
  done
  sources_json=$(printf '%s\n' "${sources[@]}" | jq -R . | jq -sc .)
  results_json=$(jq -sc 'add // []' "$result_file")
  if [ "$JSON" -eq 1 ]; then
    jq -cn \
      --arg query "$query" --argjson limit "$limit" \
      --argjson sources "$sources_json" --argjson results "$results_json" \
      '{schema:"fm-knowledge-index.search.v1",query:$query,sources:$sources,limit_per_source:$limit,results:$results}'
  elif [ "$(printf '%s' "$results_json" | jq 'length')" -eq 0 ]; then
    printf 'no results for explicitly selected source(s): %s\n' "$(IFS=,; printf '%s' "${sources[*]}")"
  else
    printf '%s' "$results_json" | jq -r '.[] |
      "[\(.source_id)] \(.relative_path) | owner=\(.owner) privacy=\(.privacy_class)",
      "  root=\(.source_root) repo=\(.repo_identity // "-") commit=\(.commit_sha // "-") sha256=\(.content_sha256) indexed=\(.indexed_at)",
      "  \(.snippet | gsub("[\\r\\n]+"; " "))"'
  fi
}

command_status() {
  local id=$1 db metadata bytes documents payload
  validate_registry_structure
  validate_source_id "$id"
  db=$(database_path "$id")
  validate_database "$id" "$db"
  metadata=$(sqlite3 -readonly -json "$db" \
    "SELECT key, value FROM metadata ORDER BY key;" 2>/dev/null) \
    || die "cannot read index status for $id"
  [ -n "$metadata" ] || metadata='[]'
  bytes=$(wc -c < "$db" | tr -d '[:space:]')
  documents=$(sqlite3 -readonly "$db" "SELECT count(*) FROM documents;" 2>/dev/null) \
    || die "cannot count index documents for $id"
  payload=$(jq -cn \
    --arg source "$id" --arg database "$db" \
    --argjson bytes "$bytes" --argjson documents "$documents" \
    --argjson metadata "$metadata" \
    '{
      schema:"fm-knowledge-index.status.v1",
      source:$source,
      database:$database,
      bytes:$bytes,
      documents:$documents,
      metadata:($metadata | map({key:.key,value:.value}) | from_entries)
    }')
  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$payload"
  else
    printf '%s: %s documents, %s bytes, indexed %s\n' \
      "$id" "$documents" "$bytes" "$(printf '%s' "$payload" | jq -r '.metadata.indexed_at')"
    printf '  database=%s privacy=%s owner=%s root=%s\n' \
      "$db" \
      "$(printf '%s' "$payload" | jq -r '.metadata.privacy_class')" \
      "$(printf '%s' "$payload" | jq -r '.metadata.owner')" \
      "$(printf '%s' "$payload" | jq -r '.metadata.source_root')"
  fi
}

command_remove() {
  local id=$1 confirm=$2 db removed=false
  validate_registry_structure
  validate_source_id "$id"
  [ "$confirm" = "$id" ] \
    || die "removal requires --confirm $id"
  db=$(database_path "$id")
  if [ -L "$db" ]; then
    die "refusing to remove symlinked index for $id"
  fi
  if [ -e "$db" ]; then
    [ -f "$db" ] || die "refusing to remove non-file index path for $id"
    rm -f -- "$db"
    removed=true
  fi
  if [ "$JSON" -eq 1 ]; then
    jq -cn --arg source "$id" --arg database "$db" --argjson removed "$removed" \
      '{schema:"fm-knowledge-index.remove.v1",source:$source,database:$database,removed:$removed}'
  else
    printf 'removed=%s source=%s index=%s\n' "$removed" "$id" "$db"
  fi
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
COMMAND=$1
shift
SOURCES=()
QUERY=""
LIMIT=20
CONFIRM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SOURCES+=("$2")
      shift 2
      ;;
    --query)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      QUERY=$2
      shift 2
      ;;
    --limit)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      LIMIT=$2
      shift 2
      ;;
    --confirm)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CONFIRM=$2
      shift 2
      ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

require_tools
case "$COMMAND" in
  validate)
    [ "${#SOURCES[@]}" -eq 0 ] && [ -z "$QUERY$CONFIRM" ] && [ "$LIMIT" -eq 20 ] \
      || die "validate accepts only --json"
    command_validate
    ;;
  sync)
    [ "${#SOURCES[@]}" -eq 1 ] && [ -z "$QUERY$CONFIRM" ] && [ "$LIMIT" -eq 20 ] \
      || die "sync requires exactly one --source and accepts only --json otherwise"
    validate_registry_structure
    validate_source_id "${SOURCES[0]}"
    coordinate_source_operation "${SOURCES[0]}"
    command_sync "${SOURCES[0]}"
    ;;
  search)
    [ "${#SOURCES[@]}" -gt 0 ] && [ -n "$QUERY" ] && [ -z "$CONFIRM" ] \
      || die "search requires explicit --source and --query"
    command_search "$QUERY" "$LIMIT" "${SOURCES[@]}"
    ;;
  status)
    [ "${#SOURCES[@]}" -eq 1 ] && [ -z "$QUERY$CONFIRM" ] && [ "$LIMIT" -eq 20 ] \
      || die "status requires exactly one --source and accepts only --json otherwise"
    command_status "${SOURCES[0]}"
    ;;
  remove)
    [ "${#SOURCES[@]}" -eq 1 ] && [ -n "$CONFIRM" ] && [ -z "$QUERY" ] && [ "$LIMIT" -eq 20 ] \
      || die "remove requires exactly one --source and --confirm"
    validate_registry_structure
    validate_source_id "${SOURCES[0]}"
    coordinate_source_operation "${SOURCES[0]}"
    command_remove "${SOURCES[0]}" "$CONFIRM"
    ;;
  *) usage >&2; exit 2 ;;
esac
