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

ORIGINAL_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG=$(python3 - "$CONFIG" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]))
PY
)
STATE=$(python3 - "$STATE" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]))
PY
)
REGISTRY="$CONFIG/knowledge-sources.json"
INDEX_LOCATOR="$STATE/knowledge-indexes"
if [ "${FM_KNOWLEDGE_INDEX_SUPERVISED:-}" = 1 ]; then
  INDEX_DIR=.
else
  INDEX_DIR=$INDEX_LOCATOR
fi
REGISTRY_SCHEMA="firstmate.knowledge-sources.v1"
JSON=0
TEMP_FILES=()
TEMP_DIRS=()

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
  for tool in jq sqlite3 find sort git python3 sed; do
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
  local root=$1 allows_json=$2 denies_json=$3 snapshot_dir=$4 file_list=$5 identity_file=$6 commit_file=$7
  python3 - "$root" "$allows_json" "$denies_json" "$snapshot_dir" "$file_list" "$identity_file" "$commit_file" <<'PY'
import fnmatch
import json
import os
import stat
import subprocess
import sys
import time

try:
    root, allows_json, denies_json, snapshot_dir, file_list, identity_file, commit_file = sys.argv[1:]
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
        saved_cwd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fchdir(directory_fd)
            git_environment = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("GIT_")
            }
            inside = subprocess.run(
                ["git", "rev-parse", "--is-inside-work-tree"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                text=True,
                env=git_environment,
            )
            commit = ""
            if inside.returncode == 0 and inside.stdout.strip() == "true":
                resolved = subprocess.run(
                    ["git", "rev-parse", "--verify", "HEAD^{commit}"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    text=True,
                    env=git_environment,
                )
                candidate = resolved.stdout.strip()
                if resolved.returncode == 0 and candidate and all(
                    character in "0123456789abcdefABCDEF" for character in candidate
                ):
                    commit = candidate
        finally:
            os.fchdir(saved_cwd)
            os.close(saved_cwd)

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
            json.dump(
                {"device": root_stat.st_dev, "inode": root_stat.st_ino},
                identity,
                sort_keys=True,
                separators=(",", ":"),
            )
            identity.write("\n")
            identity.flush()
            os.fsync(identity.fileno())
        with open(commit_file, "w", encoding="ascii") as output:
            output.write(commit + "\n")
            output.flush()
            os.fsync(output.fileno())
    finally:
        os.close(directory_fd)
except OSError:
    sys.exit(1)
PY
}

snapshot_registry() {
  local snapshot=$1 identity=$2
  python3 - "$REGISTRY" "$snapshot" "$identity" <<'PY'
import hashlib
import json
import os
import stat
import sys
import time

path, snapshot, identity = sys.argv[1:]
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise OSError("registry is not a regular file")
    digest = hashlib.sha256()
    with open(snapshot, "wb") as output:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            output.write(chunk)
    with open(identity, "w", encoding="utf-8") as output:
        json.dump(
            {"device": info.st_dev, "inode": info.st_ino, "sha256": digest.hexdigest()},
            output,
            sort_keys=True,
            separators=(",", ":"),
        )
        output.write("\n")
finally:
    os.close(fd)
PY
}

verify_registry_identity() {
  local registry=$1 identity=$2
  python3 - "$registry" "$identity" <<'PY'
import hashlib
import json
import os
import stat
import sys

path, identity_path = sys.argv[1:]
with open(identity_path, encoding="utf-8") as source:
    expected = json.load(source)
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise OSError("registry is not a regular file")
    digest = hashlib.sha256()
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    if (
        info.st_dev != expected["device"]
        or info.st_ino != expected["inode"]
        or digest.hexdigest() != expected["sha256"]
    ):
        raise OSError("registry identity changed")
finally:
    os.close(fd)
PY
}

publish_database() {
  local root=$1 identity_file=$2 registry=$3 registry_identity=$4 tmp_db=$5 db=$6
  python3 - "$root" "$identity_file" "$registry" "$registry_identity" "$tmp_db" "$db" <<'PY'
import hashlib
import json
import os
import stat
import sys
import time

try:
    root, identity_file, registry, registry_identity, temporary, destination = sys.argv[1:]
    with open(identity_file, "r", encoding="ascii") as identity:
        payload = json.load(identity)
    expected = (int(payload["device"]), int(payload["inode"]))
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
    except Exception:
        os.close(directory_fd)
        raise
    gate = os.environ.get("FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_IDENTITY_VERIFY")
    if gate:
        open(gate + ".ready", "w", encoding="utf-8").close()
        while not os.path.exists(gate + ".release"):
            time.sleep(0.01)
    with open(registry_identity, encoding="utf-8") as source:
        expected_registry = json.load(source)
    registry_fd = os.open(registry, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        registry_stat = os.fstat(registry_fd)
        if not stat.S_ISREG(registry_stat.st_mode):
            raise OSError("registry is not a regular file")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(registry_fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        if (
            registry_stat.st_dev != expected_registry["device"]
            or registry_stat.st_ino != expected_registry["inode"]
            or digest.hexdigest() != expected_registry["sha256"]
        ):
            raise OSError("registry identity changed")
    except Exception:
        os.close(registry_fd)
        os.close(directory_fd)
        raise
    gate = os.environ.get("FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_PUBLICATION_VERIFY")
    if gate:
        open(gate + ".ready", "w", encoding="utf-8").close()
        while not os.path.exists(gate + ".release"):
            time.sleep(0.01)
    index_fd = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        temporary_name = os.path.basename(temporary)
        destination_name = ".prepared-" + os.path.basename(destination)
        temporary_fd = os.open(
            temporary_name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=index_fd
        )
        try:
            if not stat.S_ISREG(os.fstat(temporary_fd).st_mode):
                raise OSError("temporary database is not regular")
            os.fchmod(temporary_fd, 0o600)
        finally:
            os.close(temporary_fd)
        os.replace(
            temporary_name,
            destination_name,
            src_dir_fd=index_fd,
            dst_dir_fd=index_fd,
        )
    finally:
        os.close(index_fd)
    os.close(registry_fd)
    os.close(directory_fd)
except (KeyError, OSError, TypeError, ValueError):
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
  if [ "${FM_KNOWLEDGE_INDEX_SUPERVISED:-}" = 1 ]; then
    python3 - <<'PY' \
      || die "cannot access stable index directory: $INDEX_DIR"
import os
import stat

fd = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
provided = os.fstat(fd)
if not stat.S_ISDIR(provided.st_mode):
    raise OSError("index descriptor is not a directory")
os.fchmod(fd, 0o700)
os.close(fd)
PY
    return
  fi
  mkdir -p -- "$INDEX_DIR"
  [ -d "$INDEX_DIR" ] || die "cannot create index directory: $INDEX_DIR"
  [ ! -L "$INDEX_DIR" ] || die "index directory must not be a symlink: $INDEX_DIR"
  chmod 700 "$INDEX_DIR"
}

database_path() {
  printf '%s/%s.sqlite3\n' "$INDEX_LOCATOR" "$1"
}

coordinate_index_operation() {
  local mode=$1
  if [ "${FM_KNOWLEDGE_INDEX_SUPERVISED:-}" = 1 ]; then
    if [ "$PPID" -ne "$FM_KNOWLEDGE_INDEX_SUPERVISOR_PID" ]; then
      printf 'fm-knowledge-index: cannot verify index operation supervisor\n' >&2
      exit 1
    fi
    if [ -z "${FM_KNOWLEDGE_INDEX_OUTPUT_FD:-}" ]; then
      printf 'fm-knowledge-index: cannot verify index operation supervisor\n' >&2
      exit 1
    fi
    python3 - "$FM_KNOWLEDGE_INDEX_OUTPUT_FD" <<'PY' \
      || { printf 'fm-knowledge-index: cannot verify index operation output\n' >&2; exit 1; }
import os
import stat
import sys

output = os.fstat(int(sys.argv[1]))
stdout = os.fstat(1)
if not stat.S_ISREG(output.st_mode):
    raise OSError("worker output is not regular")
if (output.st_dev, output.st_ino) != (stdout.st_dev, stdout.st_ino):
    raise OSError("worker stdout is not supervisor output")
PY
    return
  fi
  if [ -n "${FM_KNOWLEDGE_INDEX_DIR_FD:-}${FM_KNOWLEDGE_INDEX_SUPERVISOR_PID:-}${FM_KNOWLEDGE_INDEX_CONTROL_FD:-}${FM_KNOWLEDGE_INDEX_OUTPUT_FD:-}${FM_KNOWLEDGE_INDEX_SUPERVISED:-}" ]; then
    die "refusing unverified index supervisor environment"
  fi
  env -u INDEX_LOCATOR \
    -u FM_KNOWLEDGE_INDEX_DIR_FD \
    -u FM_KNOWLEDGE_INDEX_SUPERVISED \
    -u FM_KNOWLEDGE_INDEX_SUPERVISOR_PID \
    -u FM_KNOWLEDGE_INDEX_CONTROL_FD \
    -u FM_KNOWLEDGE_INDEX_OUTPUT_FD \
    python3 - "$STATE" "$CONFIG" "$mode" "$SCRIPT_DIR/$(basename "$0")" "${ORIGINAL_ARGS[@]}" <<'PY'
import fcntl
import os
import secrets
import shutil
import sqlite3
import stat
import subprocess
import sys

state_dir, config_dir, mode, script, *arguments = sys.argv[1:]
source_pattern = __import__("re").compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
command = arguments[0] if arguments else ""
sources = [arguments[index + 1] for index, value in enumerate(arguments[:-1]) if value == "--source"]
if command in ("sync", "search", "status", "remove"):
    if not sources or any(source == "all" or not source_pattern.fullmatch(source) for source in sources):
        sys.stderr.write("fm-knowledge-index: invalid source id\n")
        sys.exit(1)
if command in ("sync", "status", "remove") and len(sources) != 1:
    sys.stderr.write("fm-knowledge-index: exactly one source is required\n")
    sys.exit(1)

parent_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
try:
    state_parts = state_dir.split("/")[1:]
    ancestor_fds = [os.dup(parent_fd)]
    ancestor_identities = [os.fstat(ancestor_fds[0])]
    for part in state_parts[:-1]:
        try:
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd,
            )
        except FileNotFoundError:
            os.mkdir(part, 0o700, dir_fd=parent_fd)
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd,
            )
        os.close(parent_fd)
        parent_fd = next_fd
        ancestor_fds.append(os.dup(parent_fd))
        ancestor_identities.append(os.fstat(ancestor_fds[-1]))
    state_name = state_parts[-1]
    try:
        fd = os.open(
            state_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
    except FileNotFoundError:
        os.mkdir(state_name, 0o700, dir_fd=parent_fd)
        fd = os.open(
            state_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
    if not stat.S_ISDIR(os.fstat(fd).st_mode):
        raise OSError("state path is not a directory")
    state_identity = os.fstat(fd)

    def ancestors_match():
        current_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            current = os.fstat(current_fd)
            expected = ancestor_identities[0]
            if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
                return False
            for index, part in enumerate(state_parts[:-1], 1):
                next_fd = os.open(
                    part,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=current_fd,
                )
                os.close(current_fd)
                current_fd = next_fd
                current = os.fstat(current_fd)
                expected = ancestor_identities[index]
                if (current.st_dev, current.st_ino) != (
                    expected.st_dev,
                    expected.st_ino,
                ):
                    return False
            return True
        finally:
            os.close(current_fd)

    def state_matches():
        if not ancestors_match():
            return False
        current_fd = os.open(
            state_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        try:
            current = os.fstat(current_fd)
            return (current.st_dev, current.st_ino) == (
                state_identity.st_dev,
                state_identity.st_ino,
            )
        finally:
            os.close(current_fd)

    def require_locators():
        if not state_matches():
            raise OSError("selected state locator changed")
        current_index_fd = os.open(
            "knowledge-indexes",
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=fd,
        )
        try:
            current = os.fstat(current_index_fd)
            if (current.st_dev, current.st_ino) != (
                index_identity.st_dev,
                index_identity.st_ino,
            ):
                raise OSError("index locator changed")
        finally:
            os.close(current_index_fd)

    os.fchmod(fd, 0o700)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        os.mkdir("knowledge-indexes", 0o700, dir_fd=fd)
    except FileExistsError:
        pass
    index_fd = os.open(
        "knowledge-indexes",
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=fd,
    )
    index_identity = os.fstat(index_fd)
    work_name = ".knowledge-operation-" + secrets.token_hex(12)
    os.mkdir(work_name, 0o700, dir_fd=fd)
    work_fd = os.open(
        work_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
    )
    if command in ("search", "status"):
        require_locators()
        for source in sources:
            source_fd = os.open(
                source + ".sqlite3", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=index_fd
            )
            try:
                info = os.fstat(source_fd)
                if not stat.S_ISREG(info.st_mode):
                    raise OSError("database is not regular")
                destination_fd = os.open(
                    source + ".sqlite3",
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=work_fd,
                )
                try:
                    while True:
                        chunk = os.read(source_fd, 1024 * 1024)
                        if not chunk:
                            break
                        view = memoryview(chunk)
                        while view:
                            view = view[os.write(destination_fd, view):]
                    os.fsync(destination_fd)
                finally:
                    os.close(destination_fd)
            finally:
                os.close(source_fd)
    control_read, control_write = os.pipe()
    output_name = ".knowledge-worker-output"
    output_fd = os.open(
        output_name,
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=work_fd,
    )
    os.set_inheritable(work_fd, True)
    os.set_inheritable(control_read, True)
    os.set_inheritable(output_fd, True)
    environment = os.environ.copy()
    environment["FM_KNOWLEDGE_INDEX_DIR_FD"] = str(work_fd)
    environment["FM_KNOWLEDGE_INDEX_SUPERVISED"] = "1"
    environment["FM_KNOWLEDGE_INDEX_SUPERVISOR_PID"] = str(os.getpid())
    environment["FM_KNOWLEDGE_INDEX_CONTROL_FD"] = str(control_read)
    environment["FM_KNOWLEDGE_INDEX_OUTPUT_FD"] = str(output_fd)
    environment["FM_STATE_OVERRIDE"] = state_dir
    environment["FM_CONFIG_OVERRIDE"] = config_dir
    environment["INDEX_LOCATOR"] = os.path.join(state_dir, "knowledge-indexes")
    environment["INDEX_DIR"] = "."
    completed = subprocess.run(
        [script] + arguments,
        env=environment,
        pass_fds=(work_fd, control_read, output_fd),
        preexec_fn=lambda: os.fchdir(work_fd),
        stdout=output_fd,
        stderr=subprocess.PIPE,
        check=False,
    )
    os.lseek(output_fd, 0, os.SEEK_SET)
    output_chunks = []
    while True:
        chunk = os.read(output_fd, 1024 * 1024)
        if not chunk:
            break
        output_chunks.append(chunk)
    completed.stdout = b"".join(output_chunks)
    os.close(output_fd)
    os.close(control_read)
    os.close(control_write)
    try:
        require_locators()
    except OSError:
        if completed.returncode != 0 and completed.stdout:
            sys.stdout.buffer.write(completed.stdout)
        if completed.stderr:
            sys.stderr.buffer.write(completed.stderr)
        sys.exit(completed.returncode or 1)
    if completed.returncode == 0 and command == "sync":
        source = sources[0]
        prepared = ".prepared-" + source + ".sqlite3"
        original_cwd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fchdir(work_fd)
            connection = sqlite3.connect("file:" + prepared + "?mode=ro", uri=True)
            metadata = dict(connection.execute("SELECT key, value FROM metadata"))
            connection.close()
        finally:
            os.fchdir(original_cwd)
            os.close(original_cwd)
        gate = os.environ.get("FM_KNOWLEDGE_INDEX_TEST_PAUSE_BEFORE_SUPERVISOR_COMMIT")
        if gate:
            open(gate + ".ready", "w", encoding="utf-8").close()
            while not os.path.exists(gate + ".release"):
                import time
                time.sleep(0.01)
        root = metadata["source_root"]
        def revalidate_provenance():
            root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
            try:
                for part in root.split("/")[1:]:
                    next_fd = os.open(
                        part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=root_fd,
                    )
                    os.close(root_fd)
                    root_fd = next_fd
                root_info = os.fstat(root_fd)
                if (str(root_info.st_dev), str(root_info.st_ino)) != (
                    metadata["source_root_device"], metadata["source_root_inode"]
                ):
                    raise OSError("source root changed during supervisor commit")
            finally:
                os.close(root_fd)
            registry_fd = os.open(
                metadata["registry_locator"], os.O_RDONLY | os.O_NOFOLLOW
            )
            try:
                registry_info = os.fstat(registry_fd)
                digest = __import__("hashlib").sha256()
                while True:
                    chunk = os.read(registry_fd, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                if (
                    str(registry_info.st_dev),
                    str(registry_info.st_ino),
                    digest.hexdigest(),
                ) != (
                    metadata["registry_device"],
                    metadata["registry_inode"],
                    metadata["registry_sha256"],
                ):
                    raise OSError("registry changed during supervisor commit")
            finally:
                os.close(registry_fd)

        revalidate_provenance()
        require_locators()
        gate = os.environ.get("FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_SUPERVISOR_VERIFY")
        if gate:
            open(gate + ".ready", "w", encoding="utf-8").close()
            while not os.path.exists(gate + ".release"):
                import time
                time.sleep(0.01)
        revalidate_provenance()
        require_locators()
        previous = ".previous-" + secrets.token_hex(12) + ".sqlite3"
        had_previous = True
        published = False
        try:
            try:
                os.link(
                    "knowledge-indexes/" + source + ".sqlite3", previous,
                    src_dir_fd=fd, dst_dir_fd=fd,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                had_previous = False
            gate = os.environ.get("FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_BACKUP_LINK")
            if gate:
                open(gate + ".ready", "w", encoding="utf-8").close()
                while not os.path.exists(gate + ".release"):
                    import time
                    time.sleep(0.01)
            os.replace(
                work_name + "/" + prepared,
                "knowledge-indexes/" + source + ".sqlite3",
                src_dir_fd=fd,
                dst_dir_fd=fd,
            )
            published = True
            revalidate_provenance()
            require_locators()
        except Exception:
            if published:
                if had_previous:
                    os.replace(
                        previous,
                        "knowledge-indexes/" + source + ".sqlite3",
                        src_dir_fd=fd,
                        dst_dir_fd=fd,
                    )
                else:
                    try:
                        os.unlink("knowledge-indexes/" + source + ".sqlite3", dir_fd=fd)
                    except FileNotFoundError:
                        pass
            elif had_previous:
                os.unlink(previous, dir_fd=fd)
            raise
        if had_previous:
            os.unlink(previous, dir_fd=fd)
    elif completed.returncode == 0 and command == "remove":
        source = sources[0]
        require_locators()
        removal_staged = False
        quarantine = ".knowledge-remove-" + secrets.token_hex(12) + ".sqlite3"
        try:
            target_fd = os.open(
                source + ".sqlite3",
                os.O_RDONLY | os.O_NOFOLLOW,
                dir_fd=index_fd,
            )
            try:
                expected_target = os.fstat(target_fd)
                if not stat.S_ISREG(expected_target.st_mode):
                    raise OSError("database is not regular")
            finally:
                os.close(target_fd)
            gate = os.environ.get("FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_REMOVE_VERIFY")
            if gate:
                open(gate + ".ready", "w", encoding="utf-8").close()
                while not os.path.exists(gate + ".release"):
                    import time
                    time.sleep(0.01)
            os.rename(
                "knowledge-indexes/" + source + ".sqlite3",
                quarantine,
                src_dir_fd=fd,
                dst_dir_fd=fd,
            )
        except FileNotFoundError:
            removed = False
        else:
            try:
                actual = os.stat(quarantine, dir_fd=fd, follow_symlinks=False)
                if (actual.st_dev, actual.st_ino) != (
                    expected_target.st_dev,
                    expected_target.st_ino,
                ):
                    raise OSError("database changed during exact removal")
                validation_name = ".remove-validation.sqlite3"
                source_fd = os.open(quarantine, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
                destination_fd = os.open(
                    validation_name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=work_fd,
                )
                try:
                    while True:
                        chunk = os.read(source_fd, 1024 * 1024)
                        if not chunk:
                            break
                        view = memoryview(chunk)
                        while view:
                            view = view[os.write(destination_fd, view):]
                finally:
                    os.close(source_fd)
                    os.close(destination_fd)
                original_cwd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
                os.fchdir(work_fd)
                connection = sqlite3.connect(
                    "file:" + validation_name + "?mode=ro", uri=True
                )
                stored = connection.execute(
                    "SELECT value FROM metadata WHERE key = 'source_id'"
                ).fetchone()
                connection.close()
                os.fchdir(original_cwd)
                os.close(original_cwd)
                if stored != (source,):
                    raise OSError("database metadata mismatch")
                require_locators()
                os.rename(
                    quarantine,
                    work_name + "/" + quarantine,
                    src_dir_fd=fd,
                    dst_dir_fd=fd,
                )
                removal_staged = True
                require_locators()
                removed = True
            except Exception:
                try:
                    os.stat(
                        "knowledge-indexes/" + source + ".sqlite3",
                        dir_fd=fd,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    staged_name = (
                        work_name + "/" + quarantine
                        if removal_staged else quarantine
                    )
                    os.rename(
                        staged_name,
                        "knowledge-indexes/" + source + ".sqlite3",
                        src_dir_fd=fd,
                        dst_dir_fd=fd,
                    )
                raise
        if "--json" in arguments:
            completed.stdout = (
                '{"schema":"fm-knowledge-index.remove.v1","source":"%s",'
                '"database":"%s/knowledge-indexes/%s.sqlite3","removed":%s}\n'
                % (source, state_dir, source, str(removed).lower())
            ).encode()
        else:
            completed.stdout = (
                "removed=%s source=%s index=%s/knowledge-indexes/%s.sqlite3\n"
                % (str(removed).lower(), source, state_dir, source)
            ).encode()
    try:
        require_locators()
    except Exception:
        if command == "remove" and locals().get("removal_staged"):
            try:
                os.rename(
                    work_name + "/" + quarantine,
                    "knowledge-indexes/" + source + ".sqlite3",
                    src_dir_fd=fd,
                    dst_dir_fd=fd,
                )
                removal_staged = False
            except OSError:
                pass
        raise
    if completed.returncode == 0:
        sys.stdout.buffer.write(completed.stdout)
        sys.stdout.buffer.flush()
    else:
        if completed.stdout:
            sys.stdout.buffer.write(completed.stdout)
            sys.stdout.buffer.flush()
        if completed.stderr:
            sys.stderr.buffer.write(completed.stderr)
            sys.stderr.buffer.flush()
    sys.exit(completed.returncode)
finally:
    try:
        os.fchdir(fd)
        shutil.rmtree(work_name)
    except (NameError, OSError):
        pass
    for descriptor in (locals().get("work_fd"), locals().get("index_fd")):
        if descriptor is not None:
            os.close(descriptor)
    for descriptor in locals().get("ancestor_fds", []):
        os.close(descriptor)
    os.close(fd)
    os.close(parent_fd)
PY
  exit $?
}

validate_database() {
  local id=$1 db=$2 stable_db stored integrity
  stable_db=$(mktemp "$INDEX_DIR/.knowledge-database-snapshot.XXXXXX")
  TEMP_FILES+=("$stable_db")
  python3 - "$FM_KNOWLEDGE_INDEX_DIR_FD" "$id.sqlite3" "$(basename "$stable_db")" <<'PY' \
    || die "index not found or unsafe for $id; run sync --source $id"
import os
import stat
import sys
import time

directory_fd = os.dup(int(sys.argv[1]))
name, snapshot = sys.argv[2:]
try:
    source_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    try:
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            raise OSError("database is not regular")
        gate = os.environ.get("FM_KNOWLEDGE_INDEX_TEST_PAUSE_AFTER_DATABASE_OPEN")
        if gate:
            open(gate + ".ready", "w", encoding="utf-8").close()
            while not os.path.exists(gate + ".release"):
                time.sleep(0.01)
        destination_fd = os.open(
            snapshot,
            os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
        try:
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                view = memoryview(chunk)
                while view:
                    view = view[os.write(destination_fd, view):]
            os.fsync(destination_fd)
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)
finally:
    os.close(directory_fd)
PY
  VALIDATED_DATABASE=$stable_db
  stored=$(sqlite3 -readonly "$stable_db" \
    "SELECT value FROM metadata WHERE key = 'source_id';" 2>/dev/null) \
    || die "cannot read index metadata for $id"
  [ "$stored" = "$id" ] || die "index metadata does not match selected source $id"
  integrity=$(sqlite3 -readonly "$stable_db" "PRAGMA quick_check;" 2>/dev/null) \
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
  local snapshot_dir snapshot root_identity commit_file root_device root_inode
  local original_registry registry_snapshot registry_identity
  local registry_device registry_inode registry_sha256
  local -a allows=() denies=()
  original_registry=$REGISTRY
  ensure_index_dir
  registry_snapshot=$(mktemp "$INDEX_DIR/.knowledge-registry.XXXXXX")
  registry_identity=$(mktemp "$INDEX_DIR/.knowledge-registry-identity.XXXXXX")
  TEMP_FILES+=("$registry_snapshot" "$registry_identity")
  snapshot_registry "$registry_snapshot" "$registry_identity" \
    || die "cannot safely snapshot registry; previous index preserved"
  registry_device=$(jq -er '.device' "$registry_identity") \
    || die "cannot read registry identity; previous index preserved"
  registry_inode=$(jq -er '.inode' "$registry_identity") \
    || die "cannot read registry identity; previous index preserved"
  registry_sha256=$(jq -er '.sha256' "$registry_identity") \
    || die "cannot read registry identity; previous index preserved"
  REGISTRY=$registry_snapshot
  validate_registry_structure
  validate_source_id "$id"
  validate_all_roots
  root=$(source_field "$id" root)
  owner=$(source_field "$id" owner)
  privacy=$(source_field "$id" privacy)
  repo=$(source_repo "$id")
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
  commit_file=$(mktemp "$INDEX_DIR/.knowledge-commit.XXXXXX")
  tmp_db=$(mktemp "$INDEX_DIR/.$id.sqlite3.tmp.XXXXXX")
  snapshot_dir=$(mktemp -d "$INDEX_DIR/.knowledge-snapshot.XXXXXX")
  TEMP_FILES+=("$lines" "$manifest" "$file_list" "$root_identity" "$commit_file" "$tmp_db")
  TEMP_DIRS+=("$snapshot_dir")

  snapshot_source_tree "$root" "$allows_json" "$denies_json" "$snapshot_dir" "$file_list" "$root_identity" "$commit_file" \
    || die "cannot safely snapshot source tree for $id; previous index preserved"
  commit=$(tr -d '\n' < "$commit_file")
  root_device=$(jq -er '.device' "$root_identity") \
    || die "cannot read source root identity for $id; previous index preserved"
  root_inode=$(jq -er '.inode' "$root_identity") \
    || die "cannot read source root identity for $id; previous index preserved"

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
    --argjson root_device "$root_device" \
    --argjson root_inode "$root_inode" \
    --arg registry_locator "$original_registry" \
    --argjson registry_device "$registry_device" \
    --argjson registry_inode "$registry_inode" \
    --arg registry_sha256 "$registry_sha256" \
    --arg indexed_at "$indexed_at" \
    --slurpfile documents "$lines" \
    '{
      source_id:$source_id,
      owner:$owner,
      privacy:$privacy,
      source_root:$source_root,
      repo:$repo,
      commit:$commit,
      root_device:$root_device,
      root_inode:$root_inode,
      registry_locator:$registry_locator,
      registry_device:$registry_device,
      registry_inode:$registry_inode,
      registry_sha256:$registry_sha256,
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
  source_root_device INTEGER NOT NULL,
  source_root_inode INTEGER NOT NULL,
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
UNION ALL SELECT 'source_root_device', json_extract(payload, '$.root_device') FROM manifest_input
UNION ALL SELECT 'source_root_inode', json_extract(payload, '$.root_inode') FROM manifest_input
UNION ALL SELECT 'registry_locator', json_extract(payload, '$.registry_locator') FROM manifest_input
UNION ALL SELECT 'registry_device', json_extract(payload, '$.registry_device') FROM manifest_input
UNION ALL SELECT 'registry_inode', json_extract(payload, '$.registry_inode') FROM manifest_input
UNION ALL SELECT 'registry_sha256', json_extract(payload, '$.registry_sha256') FROM manifest_input
UNION ALL SELECT 'indexed_at', json_extract(payload, '$.indexed_at') FROM manifest_input;
INSERT INTO documents(
  relative_path, absolute_path, source_id, owner, privacy_class,
  source_root, repo_identity, commit_sha, source_root_device, source_root_inode,
  content_sha256, indexed_at, content
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
  json_extract(manifest.payload, '$.root_device'),
  json_extract(manifest.payload, '$.root_inode'),
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
  db="$id.sqlite3"
  verify_registry_identity "$original_registry" "$registry_identity" \
    || die "registry changed before publishing $id; previous index preserved"
  publish_database "$root" "$root_identity" "$original_registry" "$registry_identity" "$tmp_db" "$db" \
    || die "source root changed before publishing $id; previous index preserved"
  if [ "$JSON" -eq 1 ]; then
    jq -cn \
      --arg source "$id" --arg database "$(database_path "$id")" --arg indexed_at "$indexed_at" \
      --argjson documents "$count" \
      '{schema:"fm-knowledge-index.sync.v1",source:$source,database:$database,documents:$documents,indexed_at:$indexed_at}'
  else
    printf 'synced %s: %s documents -> %s\n' "$id" "$count" "$(database_path "$id")"
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
    escaped=$(printf '%s' "$token" | sed 's/"/""/g')
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
    db="$id.sqlite3"
    validate_database "$id" "$db"
    db=$VALIDATED_DATABASE
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
         d.source_root_device,
         d.source_root_inode,
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
      "  root=\(.source_root) identity=\(.source_root_device):\(.source_root_inode) repo=\(.repo_identity // "-") commit=\(.commit_sha // "-") sha256=\(.content_sha256) indexed=\(.indexed_at)",
      "  \(.snippet | gsub("[\\r\\n]+"; " "))"'
  fi
}

command_status() {
  local id=$1 db database_locator metadata bytes documents payload
  validate_registry_structure
  validate_source_id "$id"
  db="$id.sqlite3"
  database_locator=$(database_path "$id")
  validate_database "$id" "$db"
  db=$VALIDATED_DATABASE
  metadata=$(sqlite3 -readonly -json "$db" \
    "SELECT key, value FROM metadata ORDER BY key;" 2>/dev/null) \
    || die "cannot read index status for $id"
  [ -n "$metadata" ] || metadata='[]'
  bytes=$(wc -c < "$db" | tr -d '[:space:]')
  documents=$(sqlite3 -readonly "$db" "SELECT count(*) FROM documents;" 2>/dev/null) \
    || die "cannot count index documents for $id"
  payload=$(jq -cn \
    --arg source "$id" --arg database "$database_locator" \
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
      "$database_locator" \
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
  removed=false
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
    coordinate_index_operation write
    command_sync "${SOURCES[0]}"
    ;;
  search)
    [ "${#SOURCES[@]}" -gt 0 ] && [ -n "$QUERY" ] && [ -z "$CONFIRM" ] \
      || die "search requires explicit --source and --query"
    coordinate_index_operation read
    command_search "$QUERY" "$LIMIT" "${SOURCES[@]}"
    ;;
  status)
    [ "${#SOURCES[@]}" -eq 1 ] && [ -z "$QUERY$CONFIRM" ] && [ "$LIMIT" -eq 20 ] \
      || die "status requires exactly one --source and accepts only --json otherwise"
    coordinate_index_operation read
    command_status "${SOURCES[0]}"
    ;;
  remove)
    [ "${#SOURCES[@]}" -eq 1 ] && [ -n "$CONFIRM" ] && [ -z "$QUERY" ] && [ "$LIMIT" -eq 20 ] \
      || die "remove requires exactly one --source and --confirm"
    validate_registry_structure
    validate_source_id "${SOURCES[0]}"
    coordinate_index_operation write
    command_remove "${SOURCES[0]}" "$CONFIRM"
    ;;
  *) usage >&2; exit 2 ;;
esac
