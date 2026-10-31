#!/bin/bash
# ios-workers.sh
# Make this Mac a Cursor "My Machines" worker for every iOS repo found under $HOME
# (or under $SEARCH_ROOT).
#
# Project home and docs: see README.md. License: MIT.
#
# Usage:
#   ios-workers.sh scan     Dry run. Lists iOS repos that would get a worker. Changes nothing.
#   ios-workers.sh start    Starts one background worker per iOS repo (default mode).
#   ios-workers.sh stop     Stops only the workers this script started.
#   ios-workers.sh status   Lists the workers this script started and whether they are running.
#   ios-workers.sh install  Adds a LaunchAgent so "start" runs each time you log in.
#   ios-workers.sh uninstall Removes that LaunchAgent. Running workers keep running until "stop".
#   ios-workers.sh help     Shows this help.
#
# Written for macOS default tools: /bin/bash 3.2, BSD find, ps, git from Xcode or the
# Command Line Tools. No sudo. It writes only to:
#   ~/.config/ios-workers/        (exclude list you create, pid files)
#   ~/Library/Logs/ios-workers/   (one log per worker, plus launchd.log)
#   ~/Library/LaunchAgents/<label>.plist   (only with "install"; removed by "uninstall")
#
# Settings (environment variables, all optional):
#   IOS_WORKERS_NAME          Machine name the workers register as.
#                             Default: short hostname, lowercase, letters/digits/hyphens,
#                             followed by "-ios". Example: "my-macbook-pro-ios".
#   IOS_WORKERS_MAX_DEPTH     How deep to search $HOME for git repos. Default 6.
#   IOS_WORKERS_DETECT_DEPTH  How deep to look inside a repo for iOS files. Default 8.
#   IOS_WORKERS_MODE          "per-repo" (default): one worker process per repo.
#                             "single": one worker process with every repo as a --worker-dir.
#   SEARCH_ROOT               Folder to search for repos. Default $HOME.
#                             (IOS_WORKERS_ROOT is still accepted as an older alias.)
#   IOS_WORKERS_CLI           Full path to the Cursor CLI. Default: the first of "agent" or
#                             "cursor-agent" found on PATH, in ~/.local/bin, /opt/homebrew/bin
#                             or /usr/local/bin.
#   IOS_WORKERS_IDLE_TIMEOUT  Passed as --idle-release-timeout. Default 3600 seconds. After
#                             this long idle, the worker exits cleanly and the restart loop
#                             starts a fresh one.
#   IOS_WORKERS_LOOP          "1" (default) runs each worker inside a restart loop.
#                             "0" runs the worker once, with no restart.
#   IOS_WORKERS_LABEL         LaunchAgent label for install and uninstall.
#   IOS_WORKERS_RESTART_DELAY Seconds to wait before a normal restart. Default 5.
#
# Cursor documentation this relies on (checked October 2026):
#   https://cursor.com/docs/cloud-agent/self-hosted/my-machines
#   https://cursor.com/docs/cli/reference/parameters
#   https://cursor.com/docs/cli/reference/authentication
#   - "agent worker start" starts a My Machines worker. Worker options go before "start",
#     for example: agent worker --computer-use --name "my-mac" start
#   - "--worker-dir <path>" is repeatable. The first value is the assignment identity.
#     The docs say: pass --worker-dir once per checkout, OR start a worker in each
#     repo's checkout. Both are documented.
#   - "--name <name>" is a custom display name. The default is the machine hostname.
#   - A worker=NAME or machine=NAME request runs on a machine only if the machine belongs
#     to the requesting user, its --name matches, and its registered repo matches the
#     request's repo. Registered repos come from the git remotes of the worker directories.
#   - "agent status" (alias "agent whoami") shows whether you are signed in.
#   - Install: curl https://cursor.com/install -fsS | bash   Sign in: agent login
#   - Limit: 200 connected workers per user.
#   - "--idle-release-timeout <seconds>": seconds the worker may stay connected after it
#     becomes idle. The docs say the default is 0 (no idle release). The real CLI help
#     (version 2026.10.22) says the default is 3600 and that the worker exits with code 0
#     so a supervisor can restart it. This script always passes the value explicitly.
#
# NOT CONFIRMED by the docs (design choices, test them):
#   - Whether several worker processes may share the same --name. The docs neither allow
#     nor forbid it. Per-repo mode does this (same name, different repo per process).
#     If routing misbehaves, use IOS_WORKERS_MODE=single, which is clearly documented.
#   - The exact text and exit code of "agent status" when signed out. This script treats
#     a non-zero exit code, or output saying "not authenticated" or "not logged in",
#     as signed out. Its output is never printed or saved.
#   - Whether stopping the worker with SIGTERM is the intended way to stop it. The docs
#     only say to keep the process running, or stop it. This script sends SIGTERM to the
#     worker's process group, and SIGKILL only if it is still running after 15 seconds.
#   - Whether a worker serves a repo whose .git is a file (worktree or submodule).
#     Those are skipped.
#   - The "cursor-agent" command name (installed by Homebrew) is not in Cursor's docs.
#     It was seen on a real Mac and behaves like "agent".
#   - The restart loop and the LaunchAgent are this project's own setup, not Cursor
#     guidance. The docs only show launchd as an option for pool workers.

set -u

PROG="$(basename "$0")"
SELF="$(cd "$(dirname "$0")" && pwd)/$PROG"
ROOT="${SEARCH_ROOT:-${IOS_WORKERS_ROOT:-$HOME}}"
MAX_DEPTH="${IOS_WORKERS_MAX_DEPTH:-6}"
DETECT_DEPTH="${IOS_WORKERS_DETECT_DEPTH:-8}"
MODE="${IOS_WORKERS_MODE:-per-repo}"
CONFIG_DIR="$HOME/.config/ios-workers"
PID_DIR="$CONFIG_DIR/pids"
EXCLUDE_FILE="$CONFIG_DIR/exclude"
LOG_DIR="$HOME/Library/Logs/ios-workers"
IDLE_TIMEOUT="${IOS_WORKERS_IDLE_TIMEOUT:-3600}"
USE_LOOP="${IOS_WORKERS_LOOP:-1}"
RESTART_DELAY="${IOS_WORKERS_RESTART_DELAY:-5}"
FAST_FAIL_SECONDS=60      # A run shorter than this counts as a fast failure.
MAX_BACKOFF_SECONDS=300   # Longest wait between restarts.
MAX_FAST_FAILURES=20      # Give up after this many fast failures in a row.
DEFAULT_LABEL="io.github.cursor-ios-workers"
LABEL="${IOS_WORKERS_LABEL:-$DEFAULT_LABEL}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LAUNCHCTL="${IOS_WORKERS_LAUNCHCTL:-launchctl}"   # Test hook only.
MAX_WORKERS=200
STOP_WAIT_SECONDS=15

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

usage() {
  say "Usage: $PROG scan | start | stop | status | install | uninstall | help"
  say ""
  say "scan    List the iOS repos that would get a worker. Changes nothing."
  say "start   Start a Cursor My Machines worker for each iOS repo, in the background."
  say "stop    Stop only the workers this script started."
  say "status  List the workers this script started."
  say "install    Add a LaunchAgent that runs start each time you log in."
  say "uninstall  Remove that LaunchAgent. Workers keep running until you run stop."
}

is_number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

check_settings() {
  if ! is_number "$MAX_DEPTH" || ! is_number "$DETECT_DEPTH"; then
    warn "Error: IOS_WORKERS_MAX_DEPTH and IOS_WORKERS_DETECT_DEPTH must be whole numbers."
    exit 2
  fi
  if ! is_number "$IDLE_TIMEOUT" || ! is_number "$RESTART_DELAY"; then
    warn "Error: IOS_WORKERS_IDLE_TIMEOUT and IOS_WORKERS_RESTART_DELAY must be whole numbers."
    exit 2
  fi
  case "$USE_LOOP" in
    0|1) ;;
    *) warn "Error: IOS_WORKERS_LOOP must be 0 or 1. It is set to: $USE_LOOP"; exit 2 ;;
  esac
  case "$MODE" in
    per-repo|single) ;;
    *) warn "Error: IOS_WORKERS_MODE must be per-repo or single. It is set to: $MODE"; exit 2 ;;
  esac
  if [ ! -d "$ROOT" ]; then
    warn "Error: search folder does not exist: $ROOT"
    exit 2
  fi
  # Drop trailing slashes so path checks match find output.
  while [ "${#ROOT}" -gt 1 ] && [ "${ROOT%/}" != "$ROOT" ]; do ROOT="${ROOT%/}"; done
}

# Machine name: lowercase, letters, digits and hyphens only.
sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' \
    | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

machine_name() {
  if [ -n "${IOS_WORKERS_NAME:-}" ]; then
    sanitize_name "$IOS_WORKERS_NAME"
    return
  fi
  local host=""
  if command -v scutil >/dev/null 2>&1; then
    host="$(scutil --get LocalHostName 2>/dev/null || true)"
  fi
  [ -z "$host" ] && host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo mac)"
  host="$(sanitize_name "$host")"
  [ -z "$host" ] && host="mac"
  printf '%s-ios' "$host"
}

# git on macOS is a shim that opens an installer dialog if no developer tools exist.
check_git() {
  if [ "$(uname -s)" = "Darwin" ] && ! xcode-select -p >/dev/null 2>&1; then
    warn "Error: no Xcode or Command Line Tools found, so git cannot run."
    warn "Install Xcode, or run: xcode-select --install"
    exit 3
  fi
  if ! command -v git >/dev/null 2>&1; then
    warn "Error: git was not found."
    exit 3
  fi
}

# Strip trailing slashes and expand a leading ~.
normalize_path() {
  local p="$1"
  # A literal "~/" prefix from the exclude file is expanded by hand here.
  # shellcheck disable=SC2088
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

# Returns 0 if the repo path is listed in the exclude file, or is inside a listed folder.
is_excluded() {
  local repo="$1" line entry
  [ -f "$EXCLUDE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    # Trim spaces; skip blank lines and comments.
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in ''|'#'*) continue ;; esac
    entry="$(normalize_path "$line")"
    if [ "$repo" = "$entry" ]; then return 0; fi
    case "$repo" in "$entry"/*) return 0 ;; esac
  done < "$EXCLUDE_FILE"
  return 1
}

# Prints owner/repo for a GitHub remote, or nothing. Never prints the raw URL,
# because remote URLs can contain embedded credentials.
github_slug() {
  local repo="$1" url="" remote rest
  url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  if [ -z "$url" ]; then
    remote="$(git -C "$repo" remote 2>/dev/null | head -n 1)"
    [ -n "$remote" ] && url="$(git -C "$repo" remote get-url "$remote" 2>/dev/null || true)"
  fi
  [ -z "$url" ] && return 0
  case "$url" in
    git@github.com:*)                rest="${url#git@github.com:}" ;;
    ssh://git@github.com/*)          rest="${url#ssh://git@github.com/}" ;;
    ssh://git@github.com:*/*)        rest="${url#ssh://git@github.com:}"; rest="${rest#*/}" ;;
    https://github.com/*)            rest="${url#https://github.com/}" ;;
    http://github.com/*)             rest="${url#http://github.com/}" ;;
    https://*@github.com/*)          rest="${url#https://*@github.com/}" ;;
    *) printf 'NOT_GITHUB'; return 0 ;;
  esac
  rest="${rest%/}"; rest="${rest%.git}"
  printf '%s' "$rest"
}

has_remote() {
  [ -n "$(git -C "$1" remote 2>/dev/null | head -n 1)" ]
}

# Returns 0 if the repo has Xcode projects, workspaces, Package.swift, or Swift files.
is_ios_repo() {
  local repo="$1" hit
  hit="$(find "$repo" -maxdepth "$DETECT_DEPTH" \
      \( -type d \( -name node_modules -o -name DerivedData -o -name Pods -o -name .build \
                   -o -name Carthage -o -name '.*' \) ! -path "$repo" -prune \) \
      -o \( -name '*.xcodeproj' -o -name '*.xcworkspace' -o -name Package.swift -o -name '*.swift' \) \
      -print 2>/dev/null | head -n 1)"
  [ -n "$hit" ]
}

# Finds candidate git repos. Output: NUL-separated repo paths.
find_git_dirs() {
  find "$ROOT" -maxdepth "$MAX_DEPTH" \
    \( -path "$HOME/Library" -o -path "$HOME/.Trash" \) -prune \
    -o \( -type d \( -name node_modules -o -name DerivedData -o -name Pods -o -name .build \
                    -o -name Carthage \) -prune \) \
    -o \( -name .git \( -type d -o -type f \) -print0 -prune \) \
    -o \( -type d -name '.*' ! -name .git ! -path "$ROOT" -prune \) \
    2>/dev/null
}

# Fills the global arrays REPOS (paths) and SLUGS (owner/repo), and prints a report.
REPOS=()
SLUGS=()
collect_repos() {
  local quiet="${1:-}" gitpath repo slug found=0 skipped=0
  REPOS=(); SLUGS=()
  [ -z "$quiet" ] && say "Searching $ROOT for git repos, up to $MAX_DEPTH folders deep."
  while IFS= read -r -d '' gitpath; do
    repo="$(dirname "$gitpath")"
    if [ -f "$gitpath" ]; then
      [ -z "$quiet" ] && say "Skipped: $repo. Reason: it is a git worktree or submodule."
      skipped=$((skipped + 1)); continue
    fi
    if is_excluded "$repo"; then
      [ -z "$quiet" ] && say "Skipped: $repo. Reason: listed in $EXCLUDE_FILE."
      skipped=$((skipped + 1)); continue
    fi
    if ! is_ios_repo "$repo"; then
      continue   # Not iOS. Not reported, to keep the output short.
    fi
    if ! has_remote "$repo"; then
      [ -z "$quiet" ] && say "Skipped: $repo. Reason: no git remote."
      skipped=$((skipped + 1)); continue
    fi
    slug="$(github_slug "$repo")"
    if [ "$slug" = "NOT_GITHUB" ] || [ -z "$slug" ]; then
      [ -z "$quiet" ] && say "Skipped: $repo. Reason: its remote is not on GitHub."
      skipped=$((skipped + 1)); continue
    fi
    REPOS+=("$repo"); SLUGS+=("$slug")
    found=$((found + 1))
  done < <(find_git_dirs | LC_ALL=C sort -z)
  if [ -z "$quiet" ]; then
    say "Found $found iOS repo(s) with a GitHub remote. Skipped $skipped."
  fi
}

# Key used for pid and log file names: a readable slug plus a short hash of the path.
repo_key() {
  local path="$1" base hash
  base="$(printf '%s' "${path##*/}" | tr -c 'A-Za-z0-9._-' '_')"
  if command -v md5 >/dev/null 2>&1; then
    hash="$(printf '%s' "$path" | md5 -q | cut -c1-8)"
  else
    hash="$(printf '%s' "$path" | md5sum | cut -c1-8)"
  fi
  printf '%s-%s' "$base" "$hash"
}

# Pid file format: line 1 is the PID, line 2 is the repo path (or "all repos").
read_pidfile() {
  PF_PID="$(sed -n 1p "$1" 2>/dev/null)"
  PF_REPO="$(sed -n 2p "$1" 2>/dev/null)"
}

# True only if PID is alive and is an "agent worker" process, to avoid PID reuse mistakes.
is_our_worker() {
  local pid="$1" cmd
  is_number "$pid" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
  # Either the restart loop (this script with _run-loop) or a worker started directly.
  case "$cmd" in *_run-loop*|*agent*worker*) return 0 ;; *) return 1 ;; esac
}

# Finds the Cursor CLI. Looks for "agent" first, then "cursor-agent".
find_agent() {
  local name dir
  if [ -n "${IOS_WORKERS_CLI:-}" ]; then
    [ -x "$IOS_WORKERS_CLI" ] && printf '%s' "$IOS_WORKERS_CLI"
    return 0
  fi
  for name in agent cursor-agent; do
    if command -v "$name" >/dev/null 2>&1; then
      command -v "$name"; return 0
    fi
    for dir in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
      if [ -x "$dir/$name" ]; then printf '%s' "$dir/$name"; return 0; fi
    done
  done
  return 0
}

check_agent_ready() {
  AGENT="$(find_agent)"
  if [ -z "$AGENT" ]; then
    if [ -n "${IOS_WORKERS_CLI:-}" ]; then
      say "IOS_WORKERS_CLI is set, but that file does not exist or is not executable:"
      say "  $IOS_WORKERS_CLI"
      say "Nothing was started or changed."
      exit 4
    fi
    say "The Cursor CLI was not found. It is called agent or cursor-agent."
    say "Looked on your PATH and in ~/.local/bin, /opt/homebrew/bin and /usr/local/bin."
    say "Nothing was started or changed. To install it, run this yourself, then sign in:"
    say "  curl https://cursor.com/install -fsS | bash"
    say "  agent login"
    say "If your copy is called cursor-agent, sign in with: cursor-agent login"
    say "If it is somewhere else, set IOS_WORKERS_CLI to its full path."
    exit 4
  fi
  local out rc cli_name
  cli_name="${AGENT##*/}"
  out="$("$AGENT" status 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qiE 'not (authenticated|logged in|signed in)|logged out'; then
    say "The Cursor CLI is installed at $AGENT but you are not signed in."
    say "Nothing was started or changed. Sign in by running:"
    say "  $cli_name login"
    exit 4
  fi
  unset out
  say "Cursor CLI found at $AGENT and signed in."
}

ensure_dirs() {
  mkdir -p "$PID_DIR" "$LOG_DIR" || { warn "Error: could not create $PID_DIR or $LOG_DIR."; exit 5; }
  chmod 700 "$CONFIG_DIR" "$PID_DIR" 2>/dev/null
  chmod 700 "$LOG_DIR" 2>/dev/null
}

# Launch one worker in its own process group. Arguments: key, label, then --worker-dir args.
launch_worker() {
  local key="$1" label="$2" name="$3"; shift 3
  local pidfile="$PID_DIR/$key.pid" log="$LOG_DIR/$key.log" pid
  if [ -f "$pidfile" ]; then
    read_pidfile "$pidfile"
    if is_our_worker "$PF_PID"; then
      say "Already running: $label (process $PF_PID). Not starting a duplicate."
      return 0
    fi
    rm -f "$pidfile"
  fi
  {
    printf '\n----- Started %s for %s -----\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$label"
  } >> "$log"
  # set -m gives the background job its own process group, so stop can end
  # the worker and any child processes it starts, and nothing else.
  set -m
  if [ "$USE_LOOP" = "1" ]; then
    nohup /bin/bash "$SELF" _run-loop "$AGENT" --name "$name" \
      --idle-release-timeout "$IDLE_TIMEOUT" "$@" >> "$log" 2>&1 < /dev/null &
  else
    nohup "$AGENT" worker --name "$name" --idle-release-timeout "$IDLE_TIMEOUT" "$@" start \
      >> "$log" 2>&1 < /dev/null &
  fi
  pid=$!
  set +m
  printf '%s\n%s\n' "$pid" "$label" > "$pidfile"
  chmod 600 "$pidfile" "$log" 2>/dev/null
  sleep 2
  if is_our_worker "$pid"; then
    say "Started: $label (process $pid). Log: $log"
  else
    say "Failed to start or exited right away: $label. Read the log: $log"
    rm -f "$pidfile"
    return 1
  fi
}

# Internal. Runs one worker again and again until stopped.
# Arguments: CLI path, then the worker options. Output goes to the worker's log.
run_loop() {
  local cli="$1"; shift
  local child="" stopping=0 fast=0 rc started ran delay i
  trap 'stopping=1; [ -n "$child" ] && kill -TERM "$child" 2>/dev/null' TERM INT HUP
  while [ "$stopping" -eq 0 ]; do
    started="$(date +%s)"
    say "$(date '+%Y-%m-%d %H:%M:%S %Z') Starting worker."
    "$cli" worker "$@" start &
    child=$!
    wait "$child"; rc=$?
    # A signal interrupts wait. Wait again until the worker has really exited.
    while kill -0 "$child" 2>/dev/null; do wait "$child"; rc=$?; done
    child=""
    [ "$stopping" -eq 1 ] && break
    ran=$(( $(date +%s) - started ))
    if [ "$ran" -lt "$FAST_FAIL_SECONDS" ]; then
      fast=$((fast + 1))
      if [ "$fast" -ge "$MAX_FAST_FAILURES" ]; then
        say "$(date '+%Y-%m-%d %H:%M:%S %Z') Worker failed $fast times in a row. Giving up. Run start again after fixing the problem."
        exit 1
      fi
      delay="$RESTART_DELAY"; i=1
      while [ "$i" -lt "$fast" ] && [ "$delay" -lt "$MAX_BACKOFF_SECONDS" ]; do
        delay=$((delay * 2)); i=$((i + 1))
      done
      [ "$delay" -gt "$MAX_BACKOFF_SECONDS" ] && delay="$MAX_BACKOFF_SECONDS"
    else
      fast=0
      delay="$RESTART_DELAY"
    fi
    say "$(date '+%Y-%m-%d %H:%M:%S %Z') Worker exited with code $rc after $ran seconds. Restarting in $delay seconds."
    sleep "$delay" &
    wait $! 2>/dev/null
  done
  say "$(date '+%Y-%m-%d %H:%M:%S %Z') Restart loop stopped."
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

plist_path() { printf '%s/%s.plist' "$LAUNCH_AGENTS_DIR" "$LABEL"; }

check_label() {
  case "$LABEL" in
    ''|*[!A-Za-z0-9._-]*) warn "Error: IOS_WORKERS_LABEL may use only letters, digits, dots, hyphens and underscores."; exit 2 ;;
  esac
}

check_launchctl() {
  if ! command -v "$LAUNCHCTL" >/dev/null 2>&1; then
    warn "Error: launchctl was not found. install and uninstall work only on macOS."
    exit 8
  fi
}

# Writes the LaunchAgent. It runs "start" once at login. The workers then run on their
# own, in their own process groups, so AbandonProcessGroup keeps launchd from ending them
# when "start" finishes. Current settings are saved into the plist.
write_plist() {
  local file="$1" var val
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">' '<dict>'
    printf '  <key>Label</key>\n  <string>%s</string>\n' "$(xml_escape "$LABEL")"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    printf '    <string>/bin/bash</string>\n    <string>%s</string>\n    <string>start</string>\n' "$(xml_escape "$SELF")"
    printf '  </array>\n'
    printf '  <key>RunAtLoad</key>\n  <true/>\n'
    printf '  <key>KeepAlive</key>\n  <false/>\n'
    printf '  <key>AbandonProcessGroup</key>\n  <true/>\n'
    printf '  <key>ProcessType</key>\n  <string>Background</string>\n'
    printf '  <key>StandardOutPath</key>\n  <string>%s</string>\n' "$(xml_escape "$LOG_DIR/launchd.log")"
    printf '  <key>StandardErrorPath</key>\n  <string>%s</string>\n' "$(xml_escape "$LOG_DIR/launchd.log")"
    printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>PATH</key>\n    <string>%s</string>\n' \
      "$(xml_escape "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")"
    printf '    <key>IOS_WORKERS_CLI</key>\n    <string>%s</string>\n' "$(xml_escape "$AGENT")"
    for var in IOS_WORKERS_NAME IOS_WORKERS_MODE IOS_WORKERS_MAX_DEPTH IOS_WORKERS_DETECT_DEPTH \
               SEARCH_ROOT IOS_WORKERS_ROOT IOS_WORKERS_IDLE_TIMEOUT IOS_WORKERS_LOOP \
               IOS_WORKERS_RESTART_DELAY IOS_WORKERS_LABEL; do
      val="${!var:-}"
      [ -n "$val" ] && printf '    <key>%s</key>\n    <string>%s</string>\n' "$var" "$(xml_escape "$val")"
    done
    printf '  </dict>\n'
    printf '%s\n' '</dict>' '</plist>'
  } > "$file"
}

cmd_install() {
  check_settings; check_label; check_launchctl
  check_agent_ready
  local plist uid tmp
  plist="$(plist_path)"; uid="$(id -u)"
  mkdir -p "$LAUNCH_AGENTS_DIR" || { warn "Error: could not create $LAUNCH_AGENTS_DIR."; exit 5; }
  ensure_dirs
  tmp="$plist.tmp.$$"
  write_plist "$tmp"
  if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; warn "Error: the LaunchAgent file did not pass plutil -lint. Nothing was installed."; exit 9
  fi
  chmod 644 "$tmp"
  if [ -f "$plist" ]; then
    say "Replacing the existing LaunchAgent $LABEL."
    "$LAUNCHCTL" bootout "gui/$uid/$LABEL" >/dev/null 2>&1
  fi
  mv -f "$tmp" "$plist"
  if "$LAUNCHCTL" bootstrap "gui/$uid" "$plist"; then
    say "Installed the LaunchAgent: $plist"
    say "It runs \"$PROG start\" now and each time you log in. Its log is $LOG_DIR/launchd.log"
    say "It points at this script: $SELF. If you move the script, run install again."
  else
    warn "Error: launchctl bootstrap failed. The file is at $plist. Run uninstall to remove it."
    exit 9
  fi
}

cmd_uninstall() {
  check_label; check_launchctl
  local plist uid
  plist="$(plist_path)"; uid="$(id -u)"
  "$LAUNCHCTL" bootout "gui/$uid/$LABEL" >/dev/null 2>&1
  if [ -f "$plist" ]; then
    rm -f "$plist"
    say "Removed the LaunchAgent: $plist"
  else
    say "No LaunchAgent file found at $plist. Nothing to remove."
  fi
  say "Workers that are already running keep running. Run \"$PROG stop\" to stop them."
}

cmd_scan() {
  check_settings; check_git
  collect_repos
  local i
  if [ "${#REPOS[@]}" -gt 0 ]; then
    say ""
    say "These repos would get a worker named $(machine_name):"
    for i in "${!REPOS[@]}"; do
      say "  ${SLUGS[$i]} at ${REPOS[$i]}"
    done
  fi
  say ""
  say "This was a dry run. Nothing was started or changed."
}

cmd_start() {
  check_settings; check_git
  check_agent_ready
  collect_repos
  local name i failed=0 args
  name="$(machine_name)"
  if [ "${#REPOS[@]}" -eq 0 ]; then
    say "No iOS repos to serve. Nothing was started."
    return 0
  fi
  if [ "${#REPOS[@]}" -gt "$MAX_WORKERS" ]; then
    warn "Error: ${#REPOS[@]} repos found, but Cursor allows $MAX_WORKERS workers per user."
    warn "Add some to $EXCLUDE_FILE, or use IOS_WORKERS_MODE=single."
    exit 6
  fi
  ensure_dirs
  # Do not mix modes: a single worker and per-repo workers for the same repos.
  local f other=0
  for f in "$PID_DIR"/*.pid; do
    [ -f "$f" ] || continue
    read_pidfile "$f"
    is_our_worker "$PF_PID" || continue
    if [ "$MODE" = "single" ] && [ "$(basename "$f")" != "all-repos.pid" ]; then other=1; fi
    if [ "$MODE" = "per-repo" ] && [ "$(basename "$f")" = "all-repos.pid" ]; then other=1; fi
  done
  if [ "$other" -eq 1 ]; then
    warn "Error: workers from the other mode are running. Run \"$PROG stop\" first, then start again."
    exit 7
  fi
  say "Machine name: $name"
  if [ "$MODE" = "single" ]; then
    args=()
    for i in "${!REPOS[@]}"; do args+=(--worker-dir "${REPOS[$i]}"); done
    launch_worker "all-repos" "all repos" "$name" "${args[@]}" || failed=1
  else
    for i in "${!REPOS[@]}"; do
      launch_worker "$(repo_key "${REPOS[$i]}")" "${REPOS[$i]}" "$name" \
        --worker-dir "${REPOS[$i]}" || failed=$((failed + 1))
    done
  fi
  say ""
  say "To run a cloud agent here, target machine=$name for one of the repos above."
  [ "$failed" -eq 0 ]
}

cmd_stop() {
  local f count=0 pgid waited
  if [ ! -d "$PID_DIR" ] || [ -z "$(ls -A "$PID_DIR" 2>/dev/null)" ]; then
    say "No workers started by this script were found. Nothing to stop."
    return 0
  fi
  for f in "$PID_DIR"/*.pid; do
    [ -f "$f" ] || continue
    read_pidfile "$f"
    if ! is_our_worker "$PF_PID"; then
      say "Not running: $PF_REPO. Removing its old pid file."
      rm -f "$f"; continue
    fi
    pgid="$(ps -p "$PF_PID" -o pgid= 2>/dev/null | tr -d ' ')"
    if [ "$pgid" = "$PF_PID" ]; then
      kill -TERM -- "-$PF_PID" 2>/dev/null
    else
      kill -TERM "$PF_PID" 2>/dev/null
    fi
    waited=0
    while is_our_worker "$PF_PID" && [ "$waited" -lt "$STOP_WAIT_SECONDS" ]; do
      sleep 1; waited=$((waited + 1))
    done
    if is_our_worker "$PF_PID"; then
      say "Still running after $STOP_WAIT_SECONDS seconds, forcing stop: $PF_REPO"
      if [ "$pgid" = "$PF_PID" ]; then kill -KILL -- "-$PF_PID" 2>/dev/null; else kill -KILL "$PF_PID" 2>/dev/null; fi
    fi
    say "Stopped: $PF_REPO (process $PF_PID)."
    rm -f "$f"; count=$((count + 1))
  done
  say "Stopped $count worker(s)."
}

cmd_status() {
  local f running=0 stale=0
  say "Machine name: $(machine_name)"
  if [ ! -d "$PID_DIR" ] || [ -z "$(ls -A "$PID_DIR" 2>/dev/null)" ]; then
    say "No workers started by this script."
    return 0
  fi
  for f in "$PID_DIR"/*.pid; do
    [ -f "$f" ] || continue
    read_pidfile "$f"
    if is_our_worker "$PF_PID"; then
      say "Running: $PF_REPO (process $PF_PID). Log: $LOG_DIR/$(basename "$f" .pid).log"
      running=$((running + 1))
    else
      say "Not running: $PF_REPO. Run start to restart it, or stop to clear it."
      stale=$((stale + 1))
    fi
  done
  say "$running running, $stale not running."
}

main() {
  case "${1:-help}" in
    scan)   cmd_scan ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    _run-loop) shift; run_loop "$@" ;;
    help|-h|--help) usage ;;
    *) warn "Unknown command: $1"; usage; exit 2 ;;
  esac
}

main "$@"
