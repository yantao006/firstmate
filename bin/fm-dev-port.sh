#!/usr/bin/env bash
# fm-dev-port.sh - stop / start / restart a local dev server by TCP listen port.
#
# Owner of the operational sequence in data/runbooks/local-dev-server-port-lifecycle.md:
# find LISTEN PID by port, kill that process (not a broad pkill), optionally start
# again from a given app directory.
#
# Usage:
#   fm-dev-port.sh status  <port>
#   fm-dev-port.sh stop    <port>
#   fm-dev-port.sh start   <port> --dir <app-root> [options]
#   fm-dev-port.sh restart <port> --dir <app-root> [options]
#
# Start/restart options:
#   --dir <path>         Application root (required for start/restart; must contain package.json)
#   --host <host>        Bind host passed to next (default: 127.0.0.1)
#   --cmd <command>      Full start command; default:
#                          npm run dev -- -p <port> -H <host>
#   --proxy              Export HTTP(S)_PROXY / ALL_PROXY / NODE_USE_ENV_PROXY for this process tree
#   --proxy-port <n>     Local proxy port (default: 7890); only used with --proxy
#   --log <path>         Log file for background start (default: /tmp/fm-dev-port-<port>.log)
#   --foreground         Run start in the foreground (default: background via nohup)
#   --db-push            Run `npx prisma db push` in --dir before start (needs DATABASE_URL in env/.env*)
#   --wait-seconds <n>   Health-check wait after background start (default: 30)
#   --health-path <path> Path for readiness curl (default: /)
#
# Examples:
#   bin/fm-dev-port.sh status 3456
#   bin/fm-dev-port.sh stop 3456
#   bin/fm-dev-port.sh restart 3456 --dir projects/AdWhiz-clone --proxy --health-path /login
#
# Does not read or print secrets. Does not pkill by name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

log() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; }

require_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || { err "port must be a number (got: ${port:-empty})"; usage 2; }
  ((port >= 1 && port <= 65535)) || { err "port out of range: $port"; exit 2; }
}

listen_pids() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true
}

cmd_status() {
  local port="$1"
  require_port "$port"
  local pids
  pids="$(listen_pids "$port")"
  if [[ -z "$pids" ]]; then
    log "port $port: free (no LISTEN)"
    return 0
  fi
  log "port $port: LISTEN"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -v smbfs || true
}

cmd_stop() {
  local port="$1"
  require_port "$port"
  local pids pids2
  pids="$(listen_pids "$port")"
  if [[ -z "$pids" ]]; then
    log "port $port: already free"
    return 0
  fi
  log "port $port: killing PID(s): $(echo "$pids" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 1
  pids2="$(listen_pids "$port")"
  if [[ -n "$pids2" ]]; then
    log "port $port: still listening, kill -9 PID(s): $(echo "$pids2" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill -9 $pids2 2>/dev/null || true
    sleep 0.5
  fi
  if [[ -n "$(listen_pids "$port")" ]]; then
    err "port $port still in use after kill"
    cmd_status "$port"
    exit 1
  fi
  log "port $port: free"
}

resolve_dir() {
  local dir="$1"
  if [[ -z "$dir" ]]; then
    err "--dir is required for start/restart"
    exit 2
  fi
  if [[ "$dir" != /* ]]; then
    # Prefer FM_HOME/projects when relative path does not exist from cwd
    if [[ -d "$dir" ]]; then
      dir="$(cd "$dir" && pwd)"
    elif [[ -d "${FM_HOME:-$FM_ROOT}/projects/$dir" ]]; then
      dir="$(cd "${FM_HOME:-$FM_ROOT}/projects/$dir" && pwd)"
    elif [[ -d "$FM_ROOT/$dir" ]]; then
      dir="$(cd "$FM_ROOT/$dir" && pwd)"
    else
      err "directory not found: $dir"
      exit 2
    fi
  fi
  [[ -d "$dir" ]] || { err "not a directory: $dir"; exit 2; }
  [[ -f "$dir/package.json" ]] || { err "no package.json in $dir"; exit 2; }
  printf '%s\n' "$dir"
}

apply_proxy() {
  local proxy_port="$1"
  export HTTP_PROXY="http://127.0.0.1:${proxy_port}"
  export HTTPS_PROXY="http://127.0.0.1:${proxy_port}"
  export ALL_PROXY="socks5://127.0.0.1:${proxy_port}"
  export NODE_USE_ENV_PROXY=1
  if [[ -z "${NODE_OPTIONS:-}" ]]; then
    export NODE_OPTIONS='--dns-result-order=ipv4first'
  elif [[ "$NODE_OPTIONS" != *dns-result-order* ]]; then
    export NODE_OPTIONS="${NODE_OPTIONS} --dns-result-order=ipv4first"
  fi
  log "proxy: HTTP(S)_PROXY=127.0.0.1:${proxy_port} NODE_USE_ENV_PROXY=1"
}

health_wait() {
  local port="$1" path="$2" seconds="$3"
  local i code
  path="/${path#/}"
  for ((i = 1; i <= seconds; i++)); do
    code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:${port}${path}" 2>/dev/null || echo 000)"
    if [[ "$code" != "000" && -n "$code" ]]; then
      log "ready: http://127.0.0.1:${port}${path} -> HTTP ${code} (${i}s)"
      return 0
    fi
    sleep 1
  done
  err "not ready after ${seconds}s: http://127.0.0.1:${port}${path}"
  return 1
}

cmd_start() {
  local port="$1"
  shift
  require_port "$port"

  local dir="" host="127.0.0.1" cmd="" use_proxy=0 proxy_port=7890
  local log_path="/tmp/fm-dev-port-${port}.log" foreground=0 db_push=0
  local wait_seconds=30 health_path="/"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) dir="${2:-}"; shift 2 ;;
      --host) host="${2:-}"; shift 2 ;;
      --cmd) cmd="${2:-}"; shift 2 ;;
      --proxy) use_proxy=1; shift ;;
      --proxy-port) proxy_port="${2:-}"; shift 2 ;;
      --log) log_path="${2:-}"; shift 2 ;;
      --foreground) foreground=1; shift ;;
      --db-push) db_push=1; shift ;;
      --wait-seconds) wait_seconds="${2:-}"; shift 2 ;;
      --health-path) health_path="${2:-}"; shift 2 ;;
      -h|--help) usage 0 ;;
      *) err "unknown option: $1"; usage 2 ;;
    esac
  done

  dir="$(resolve_dir "$dir")"
  [[ "$proxy_port" =~ ^[0-9]+$ ]] || { err "invalid --proxy-port"; exit 2; }
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || { err "invalid --wait-seconds"; exit 2; }

  if [[ -n "$(listen_pids "$port")" ]]; then
    err "port $port already in use; run: $0 stop $port"
    cmd_status "$port"
    exit 1
  fi

  if ((use_proxy)); then
    apply_proxy "$proxy_port"
  fi

  if [[ -z "$cmd" ]]; then
    cmd="npm run dev -- -p ${port} -H ${host}"
  fi

  log "dir: $dir"
  log "cmd: $cmd"

  cd "$dir"

  if ((db_push)); then
    log "running: npx prisma db push"
    npx prisma db push
  fi

  if ((foreground)); then
    log "starting in foreground on port $port"
    # shellcheck disable=SC2086
    exec bash -lc "$cmd"
  fi

  log "starting in background; log: $log_path"
  nohup bash -lc "$cmd" >"$log_path" 2>&1 &
  local pid=$!
  log "started pid=$pid"

  if ! health_wait "$port" "$health_path" "$wait_seconds"; then
    log "--- last 40 log lines ---"
    tail -40 "$log_path" 2>/dev/null || true
    exit 1
  fi

  cmd_status "$port"
  log "open: http://127.0.0.1:${port}${health_path%/}"
  log "tip: OAuth apps often need http://localhost:${port}/... (see data/runbooks/google-oauth-web-client-local.md)"
}

cmd_restart() {
  local port="$1"
  shift
  require_port "$port"
  cmd_stop "$port"
  cmd_start "$port" "$@"
}

main() {
  local action="${1:-}"
  shift || true
  case "$action" in
    status) [[ $# -ge 1 ]] || usage 2; cmd_status "$1" ;;
    stop) [[ $# -ge 1 ]] || usage 2; cmd_stop "$1" ;;
    start) [[ $# -ge 1 ]] || usage 2; cmd_start "$@" ;;
    restart) [[ $# -ge 1 ]] || usage 2; cmd_restart "$@" ;;
    -h|--help|help|"") usage 0 ;;
    *) err "unknown action: $action"; usage 2 ;;
  esac
}

main "$@"
