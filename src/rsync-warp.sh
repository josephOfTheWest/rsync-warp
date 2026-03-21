#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage:
  $0 <remote-host> <remote-is> <working-dir> <ssh-port> <dry-run> <verbose> <label> <source-path> <target-path> [<label> <source-path> <target-path> ...]

  remote-host:  SSH host for the remote endpoint. Pass "" for local-to-local transfers.
  remote-is:    "source" if the remote host provides files; "target" if it receives them.
                Ignored when remote-host is "".
  working-dir:  Local directory for logs and run-control files. Default: current directory.
  ssh-port:     SSH port number. Default: 22.
  dry-run:      true to simulate the transfer without writing files. Default: false.
  verbose:      true enables pre-flight SSH/path checks and increased rsync log detail. Default: false.
  label:        Unique name for this transfer set. Used for log and control file names.
  source-path:  Path to read from. Absolute if starting with /; otherwise relative to working-dir.
  target-path:  Path to write to. Absolute if starting with /; otherwise relative to working-dir.

  Multiple label/source-path/target-path groups may be appended. All sets run in parallel.

Examples:
  Pull from remote source to local target:
    $0 remote.example.com source /var/backups "" "" "" mydata /remote/data /local/data

  Push from local source to remote target:
    $0 remote.example.com target /var/backups "" "" "" mydata /data /remote/data

  Local to local:
    $0 "" "" /var/backups "" "" "" mydata /data /local/backup

  Non-standard SSH port with dry run:
    $0 remote.example.com target /var/backups 2222 true false mydata /data /remote/data

  Verbose diagnostics:
    $0 remote.example.com target /var/backups "" "" true mydata /data /remote/data

  Multiple sets in parallel:
    $0 remote.example.com target /var/backups "" "" false \\
      photos    /mnt/data/photos    /backup/photos \\
      documents /mnt/data/documents /backup/documents \\
      videos    /mnt/data/videos    /backup/videos
EOF
}

if [ "$#" -eq 1 ] && [ "$1" = "--status" ]; then
  pid=$(pgrep -f "[r]sync-warp.sh" | head -n 1) || true
  if [ -z "$pid" ]; then
    echo "rsync-warp is not running"
    exit 1
  fi
  echo "rsync-warp running: pid=$pid"
  ps -p "$pid"
  exit 0
fi

if [ "$#" -lt 9 ]; then
  echo "ERROR: insufficient arguments"
  usage
  exit 1
fi

remote_host=$1
remote_is=$2
working_directory=${3:-}
ssh_port=${4:-22}
dry_run=${5:-false}
verbose=${6:-false}
shift 6

if [ -n "$remote_host" ]; then
  case "${remote_is,,}" in
    source) source_host="$remote_host"; target_host="" ;;
    target) source_host="";             target_host="$remote_host" ;;
    *)
      echo "ERROR: remote-is must be 'source' or 'target' when remote-host is specified"
      usage
      exit 1
      ;;
  esac
else
  source_host=""
  target_host=""
fi

case "${dry_run,,}" in
  true) dry_run_flag="--dry-run" ;;
  false) dry_run_flag="" ;;
  *)
    echo "ERROR: dry-run must be 'true' or 'false'"
    usage
    exit 1
    ;;
esac

case "${verbose,,}" in
  true|false) ;;
  *)
    echo "ERROR: verbose must be 'true' or 'false'"
    usage
    exit 1
    ;;
esac

if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
  echo "ERROR: ssh-port must be a number between 1 and 65535 (got: '$ssh_port')"
  usage
  exit 1
fi

if [ -z "$working_directory" ]; then
  working_directory="$(pwd)"
fi

if [ ! -f "$working_directory/exclude-files.txt" ]; then
  echo "ERROR: exclude-files.txt not found in $working_directory"
  exit 1
fi

stop_all=0
STOPALLFILE="$working_directory/loop/STOPALL"

trap 'stop_all=1; touch "$STOPALLFILE" 2>/dev/null || true; echo "SIGINT/SIGTERM received; terminating active transfers..."' SIGINT SIGTERM

cleanup() {
  if [ "${stop_all:-0}" -eq 1 ]; then
    echo "Cleanup: removing partial files, control files, and loop directory"

    # Remove .rsync-partial directories left by interrupted transfers on local targets
    for idx in "${!target_paths[@]}"; do
      dst_path="${target_paths[$idx]}"
      if [ -z "$target_host" ]; then
        [[ "$dst_path" != /* ]] && dst_path="$working_directory/$dst_path"
        find "$dst_path" -name ".rsync-partial" -type d -exec rm -rf {} + 2>/dev/null || true
      fi
    done

    rm -f "$working_directory/loop/"*-PROCEED 2>/dev/null || true
    rm -f "$STOPALLFILE" 2>/dev/null || true
    rmdir "$working_directory/loop" 2>/dev/null || true
  fi
}
trap cleanup EXIT


declare -a labels source_paths target_paths

while [ "$#" -gt 0 ]; do
  if [ "$#" -lt 3 ]; then
    echo "ERROR: target entries must come in label/source/target groups"
    usage
    exit 1
  fi
  labels+=("$1")
  source_paths+=("$2")
  target_paths+=("$3")
  shift 3
done

set_count=${#labels[@]}

if [ "$set_count" -le 0 ]; then
  echo "ERROR: no backup sets provided"
  usage
  exit 1
fi

declare -A _seen_labels
for _lbl in "${labels[@]}"; do
  if [ -n "${_seen_labels[$_lbl]+x}" ]; then
    echo "ERROR: duplicate label '$_lbl' — each label must be unique"
    exit 1
  fi
  _seen_labels[$_lbl]=1
done
unset _seen_labels _lbl

mkdir -p "$working_directory/loop" "$working_directory/rsynclogs"

for idx in "${!labels[@]}"; do
  proceed="${working_directory}/loop/${labels[$idx]}-PROCEED"
  touch "$proceed"
done

skip_compress=""
if [ -f "$working_directory/skip-compress.txt" ]; then
  skip_compress=$(grep -v '^[[:space:]]*#' "$working_directory/skip-compress.txt" | grep -v '^[[:space:]]*$' | tr '\n' '/')
  skip_compress="${skip_compress%/}"
fi

# Override the local rsync binary path. Leave empty to use 'rsync' from PATH.
# Set to /usr/bin/rsync for Synology NAS or any local machine where rsync is not in the default PATH.
rsync_local_path="${RSYNC_LOCAL_PATH:-rsync}"

# Override the remote rsync binary path. Leave empty to rely on the remote's PATH.
# Set to /usr/bin/rsync for Synology NAS or any remote where rsync is not in the default SSH PATH.
rsync_remote_path="${RSYNC_REMOTE_PATH:-}"

rsync_base=("$rsync_local_path" -avzh --delete --whole-file --partial-dir=.rsync-partial --timeout=20 --exclude-from="$working_directory/exclude-files.txt" --modify-window=1 --info=progress2 --no-motd --numeric-ids --stats)
[ -n "$rsync_remote_path" ] && rsync_base+=(--rsync-path="$rsync_remote_path")
[ -n "$skip_compress" ] && rsync_base+=("--skip-compress=$skip_compress")

ssh_control_path="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/rsync-warp-%r@%h:%p"
ssh_opts="ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -p $ssh_port -o ControlMaster=auto -o ControlPath=$ssh_control_path -o ControlPersist=60"

max_retries=10

# Converts \r to \n with line-buffered output so --info=progress2 updates reach the
# parser immediately rather than waiting for the pipe buffer to fill.
# Falls back to plain tr if stdbuf is unavailable.
_cr_to_lf() {
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL tr '\r' '\n'
  else
    tr '\r' '\n'
  fi
}

# Runs pre-flight connectivity and path checks, logging all output.
# Usage: preflight_check <log-file> <host-or-empty> <path> <"source"|"target">
preflight_check() {
  local log_file=$1
  local host=$2
  local path=$3
  local direction=$4

  echo "--- preflight $direction: ${host:-local}:$path ---" | tee -a "$log_file"

  if [ -n "$host" ]; then
    echo "[SSH] testing connection to $host..." | tee -a "$log_file"
    if ssh -q -o ConnectTimeout=10 -o BatchMode=yes -p "$ssh_port" "$host" echo "ssh-ok" 2>&1 | tee -a "$log_file"; then
      echo "[SSH] connection OK" | tee -a "$log_file"
      echo "[SSH] remote rsync version:" | tee -a "$log_file"
      ssh -p "$ssh_port" "$host" "rsync --version 2>&1 | head -1" 2>&1 | tee -a "$log_file" || true
      echo "[$direction] path check: $path" | tee -a "$log_file"
      ssh -p "$ssh_port" "$host" "ls -lad \"$path\" 2>&1" 2>&1 | tee -a "$log_file" || true
    else
      echo "[SSH] connection FAILED to $host" | tee -a "$log_file"
    fi
  else
    echo "[$direction] local path check: $path" | tee -a "$log_file"
    ls -lad "$path" 2>&1 | tee -a "$log_file" || true
  fi

  echo "--- end preflight $direction ---" | tee -a "$log_file"
}

# Renders a live per-set status table, refreshing every second using ANSI cursor movement.
# Reads <working-dir>/loop/<label>-STATUS files written by run_set.
# Status file format (pipe-delimited):
#   RUNNING|<attempt>|<pct>|<speed>|<current-file>
#   RETRYING|<attempt>|<wake-epoch>|<exit-code>|
#   DONE|<attempt>|||
#   FAILED|<attempt>|<exit-code>||
display_loop() {
  [ -t 1 ] || return 0   # only render to an interactive terminal
  trap - EXIT             # reset the parent's EXIT trap; don't run cleanup in this subshell
  trap 'printf "\033[999B\n"' EXIT  # on exit, move cursor past banner + table

  local n="${#labels[@]}"
  local total=$(( n + 4 ))  # header + top separator + column headers + n sets + bottom separator
  local start_time; start_time=$(date +%s)
  local sep; sep=$(printf '─%.0s' $(seq 1 72))

  # Clear screen and print fixed ASCII art banner above the status table
  printf '\033[2J\033[H'
  cat <<'BANNER'
                          __        ___    ____  ____
 _ __ ___ _   _ _ __   ___\ \      / / \  |    \|  _ \
| '__/ __| | | | '_ \ / __|\ \ /\ / / ¤ \ | |¯) | |_) |
| |  \__ \ |_| | | | | (__  \ V  V / /—\ \|  ¯ <|  __/
|_|  |___/\__, |_| |_|\___|  \_/\_/_/   \_\_|¯\_\_|
          |___/             
BANNER

  local wd_disp="$working_directory"
  [ "${#wd_disp}" -gt 78 ] && wd_disp="…${wd_disp: -77}"
  local rh_disp="${remote_host:-(local)}"
  [ "${#rh_disp}" -gt 84 ] && rh_disp="…${rh_disp: -83}"

  # Colors
  local _bd=$'\033[90m'    # dark gray     — borders
  local _lb=$'\033[36m'    # cyan          — labels
  local _vl=$'\033[93m'    # bright yellow — values
  local _rs=$'\033[0m'     # reset
  local _c_run=$'\033[92m' # bright green  — running ▶
  local _c_ret=$'\033[93m' # bright yellow — retrying ⟳
  local _c_don=$'\033[33m' # gold          — done ✓
  local _c_err=$'\033[91m' # bright red    — failed ✗

  # Table: total width 100, inner 98
  # Row 3 cell content widths: 32 | 22 | 21 | 20  (sum=95, +3 internal + 2 outer │ = 100)
  local _d98; _d98=$(printf '─%.0s' $(seq 1 98))
  local _d32; _d32=$(printf '─%.0s' $(seq 1 32))
  local _d22; _d22=$(printf '─%.0s' $(seq 1 22))
  local _d21; _d21=$(printf '─%.0s' $(seq 1 21))
  local _d20; _d20=$(printf '─%.0s' $(seq 1 20))

  printf "${_bd}┌%s┐${_rs}\n" "$_d98"
  printf "${_bd}│${_rs} ${_lb}working-directory:${_rs} ${_vl}%-78s${_rs}${_bd}│${_rs}\n" "$wd_disp"
  printf "${_bd}├%s┤${_rs}\n" "$_d98"
  printf "${_bd}│${_rs} ${_lb}remote-host:${_rs} ${_vl}%-84s${_rs}${_bd}│${_rs}\n" "$rh_disp"
  printf "${_bd}├%s┬%s┬%s┬%s┤${_rs}\n" "$_d32" "$_d22" "$_d21" "$_d20"
  printf "${_bd}│${_rs} ${_lb}remote-is:${_rs} ${_vl}%-20s${_rs}${_bd}│${_rs} ${_lb}ssh-port:${_rs} ${_vl}%-11s${_rs}${_bd}│${_rs} ${_lb}dry-run:${_rs} ${_vl}%-11s${_rs}${_bd}│${_rs} ${_lb}verbose:${_rs} ${_vl}%-10s${_rs}${_bd}│${_rs}\n" \
    "${remote_is:-(local)}" "$ssh_port" "$dry_run" "$verbose"
  printf "${_bd}└%s┴%s┴%s┴%s┘${_rs}\n" "$_d32" "$_d22" "$_d21" "$_d20"
  printf '\n'

  # Reserve display space for the status table
  local i; for (( i = 0; i < total; i++ )); do printf '\n'; done

  while true; do
    printf '\033[%dA' "$total"  # move cursor back to top of display area

    local elapsed=$(( $(date +%s) - start_time ))
    printf ' rsync-warp  ●  %d set(s)  ·  elapsed %02d:%02d\033[K\n' \
      "$n" "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"
    printf '%s\033[K\n' "$sep"
    # Column headers — SET% is overall bytes transferred across the whole set, not per-file
    printf '  %-14s  %-4s  %-4s  %-8s  %-12s  %s\033[K\n' \
      "LABEL" "ST" "ATT" "SET %" "SPEED" "CURRENT FILE"

    local idx
    for idx in "${!labels[@]}"; do
      local lbl="${labels[$idx]}"
      local sf="$working_directory/loop/${lbl}-STATUS"
      local state="" attempt="" f3="" f4="" f5=""
      [ -f "$sf" ] && IFS='|' read -r state attempt f3 f4 f5 < "$sf" || true

      case "${state:-WAITING}" in
        RUNNING)
          local disp="${f5:--}"
          [ "${#disp}" -gt 28 ] && disp="…${disp: -27}"
          printf "  %-14s  ${_c_run}▶${_rs}     %-4s  %-8s  %-12s  %s\033[K\n" \
            "$lbl" "$attempt" "${f3:----}" "${f4:------}" "$disp"
          ;;
        RETRYING)
          local remaining=$(( ${f3:-0} - $(date +%s) ))
          [ "$remaining" -lt 0 ] && remaining=0
          printf "  %-14s  ${_c_ret}⟳${_rs}     %-4s  retrying in %ds  (attempt %s/%s, exit %s)\033[K\n" \
            "$lbl" "$attempt" "$remaining" "$attempt" "$max_retries" "${f4:--}"
          ;;
        DONE)
          printf "  %-14s  ${_c_don}✓${_rs}     %-4s  completed\033[K\n" "$lbl" "$attempt"
          ;;
        FAILED)
          printf "  %-14s  ${_c_err}✗${_rs}     %-4s  failed (exit %s)\033[K\n" "$lbl" "$attempt" "$f3"
          ;;
        *)
          printf '  %-14s  ·     waiting\033[K\n' "$lbl"
          ;;
      esac
    done

    printf '%s\033[K\n' "$sep"
    sleep 1 || true
  done
}

run_set() {
  local idx=$1
  local label=${labels[$idx]}
  local src_path=${source_paths[$idx]}
  local dst_path=${target_paths[$idx]}
  local stopfile="$working_directory/loop/${label}-PROCEED"
  local status_file="$working_directory/loop/${label}-STATUS"
  local curfile_tmp="$working_directory/loop/${label}-curfile"
  local attempt=0
  local base_delay=5

  local LOG_FILE="${working_directory}/rsynclogs/${label}-$(date +%Y-%m-%d_%H-%M-%S).txt"

  # Resolve source path
  local rsync_src
  if [ -n "$source_host" ]; then
    rsync_src="$source_host:$src_path"
  elif [[ "$src_path" == /* ]]; then
    rsync_src="$src_path"
  else
    rsync_src="$working_directory/$src_path"
  fi

  # Resolve target path
  local rsync_dst
  if [ -n "$target_host" ]; then
    rsync_dst="$target_host:$dst_path"
  elif [[ "$dst_path" == /* ]]; then
    rsync_dst="$dst_path"
  else
    rsync_dst="$working_directory/$dst_path"
  fi

  echo "label=$label src=$rsync_src dst=$rsync_dst log=$LOG_FILE" >> "$LOG_FILE"
  printf 'WAITING|0||||\n' > "$status_file"

  if [ "${verbose,,}" = "true" ]; then
    preflight_check "$LOG_FILE" "$source_host" "$src_path" "source" >/dev/null
    preflight_check "$LOG_FILE" "$target_host" "$dst_path" "target" >/dev/null
  fi

  while true; do
    if [ -f "$STOPALLFILE" ]; then
      echo "STOPALL file exists: canceling $label" >> "$LOG_FILE"
      printf 'FAILED|%s|stopped||\n' "$attempt" > "$status_file"
      return 1
    fi

    if [ ! -f "$stopfile" ]; then
      echo "$stopfile does not exist: canceling $label" >> "$LOG_FILE"
      printf 'FAILED|%s|stopped||\n' "$attempt" > "$status_file"
      return 1
    fi

    echo "Attempt: $((attempt + 1))" >> "$LOG_FILE"
    printf 'RUNNING|%s|---|---|starting\n' "$((attempt + 1))" > "$status_file"

    local rsync_exit_tmp="$working_directory/loop/${label}-exitcode"
    local rsync_cmd
    rsync_cmd=("${rsync_base[@]}" ${dry_run_flag:+"$dry_run_flag"} -e "$ssh_opts" --log-file="$LOG_FILE" "$rsync_src" "$rsync_dst")
    [ "${verbose,,}" = "true" ] && rsync_cmd+=("--verbose")

    # Run rsync piped through a progress parser that updates the status file.
    # tr converts \r (used by --info=progress2) to \n for line-by-line reading.
    # The exit code is written to a temp file since PIPESTATUS is unreliable after ||.
    {
      set +o pipefail
      set +e
      "${rsync_cmd[@]}" 2>&1
      printf '%s\n' "$?" > "$rsync_exit_tmp"
    } | _cr_to_lf | while IFS= read -r line; do
      # Progress line: "   1,234,567  45%   2.34MB/s    0:00:15 (xfr#5, to-chk=42/100)"
      if [[ "$line" =~ ^[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+)%[[:space:]]+([0-9.]+[kKMGTP]?B/s) ]]; then
        local cf; cf=$(cat "$curfile_tmp" 2>/dev/null || printf '%s' '-')
        printf 'RUNNING|%s|%s%%|%s|%s\n' \
          "$((attempt + 1))" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${cf//|/?}" \
          > "$status_file"
      # Filename line: non-empty, starts with non-space, not a stats/message line
      elif [[ -n "$line" ]] && [[ "$line" =~ ^[^[:space:]] ]] && \
           ! [[ "$line" =~ ^(sent\ |received\ |total\ |Total\ |Number\ |File\ list|Literal|Matched|creating\ |rsync:\ |building|delta-|sending\ incremental|done\ count|created\ dir|opening\ connection|\.[cdLDS]) ]]; then
        printf '%s\n' "$line" > "$curfile_tmp"
        printf 'RUNNING|%s|---|---|%s\n' "$((attempt + 1))" "${line:0:100}" > "$status_file"
      fi
    done || true

    local status
    status=$(cat "$rsync_exit_tmp" 2>/dev/null || printf '1')
    rm -f "$rsync_exit_tmp" "$curfile_tmp"

    if [ "$status" -eq 0 ]; then
      rm -f "$stopfile"
      echo "rsync completed successfully" >> "$LOG_FILE"
      echo "***********************************************" >> "$LOG_FILE"
      printf 'DONE|%s|||\n' "$((attempt + 1))" > "$status_file"
      return 0
    fi

    case "$status" in
      10|12|30|32|35|255)
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_retries" ]; then
          echo "rsync failed with exit $status after $attempt retries; giving up" >> "$LOG_FILE"
          echo "***********************************************" >> "$LOG_FILE"
          rm -f "$stopfile"
          printf 'FAILED|%s|%s||\n' "$attempt" "$status" > "$status_file"
          return 1
        fi
        echo "rsync transient failure exit $status; retrying in $base_delay seconds" >> "$LOG_FILE"
        echo "***********************************************" >> "$LOG_FILE"
        local wake_at=$(( $(date +%s) + base_delay ))
        printf 'RETRYING|%s|%s|%s|\n' "$attempt" "$wake_at" "$status" > "$status_file"
        sleep $base_delay
        base_delay=$((base_delay * 2))
        [ "$base_delay" -gt 300 ] && base_delay=300
        # Close any stale ControlMaster socket so the next attempt opens a fresh connection
        local ctrl_host="${source_host:-$target_host}"
        if [ -n "$ctrl_host" ]; then
          ssh -O exit -o "ControlPath=$ssh_control_path" -p "$ssh_port" "$ctrl_host" 2>/dev/null || true
        fi
        if [ "${verbose,,}" = "true" ]; then
          preflight_check "$LOG_FILE" "$source_host" "$src_path" "source" >/dev/null
          preflight_check "$LOG_FILE" "$target_host" "$dst_path" "target" >/dev/null
        fi
        continue
        ;;
      *)
        local err_msg
        case "$status" in
          1)  err_msg="syntax or usage error — check script arguments" ;;
          2)  err_msg="protocol incompatibility — check rsync versions on both ends" ;;
          3)  err_msg="source or destination path error — verify paths exist and are accessible" ;;
          4)  err_msg="requested action not supported by remote rsync" ;;
          5)  err_msg="error starting client-server protocol — check SSH and rsync daemon config" ;;
          6)  err_msg="rsync daemon could not write to log file on remote" ;;
          11) err_msg="file I/O error — check disk space and file permissions on remote" ;;
          13) err_msg="program diagnostics error" ;;
          14) err_msg="IPC error" ;;
          20) err_msg="received SIGINT or SIGUSR1 — transfer was interrupted" ;;
          21) err_msg="waitpid() error" ;;
          22) err_msg="out of memory — insufficient RAM to complete transfer" ;;
          23) err_msg="partial transfer — some files could not be transferred (check permissions or disk space)" ;;
          24) err_msg="partial transfer — some source files vanished during transfer" ;;
          25) err_msg="transfer halted — --max-delete limit reached" ;;
          *)  err_msg="unknown error" ;;
        esac
        echo "rsync failed (exit $status): $err_msg" >> "$LOG_FILE"
        echo "***********************************************" >> "$LOG_FILE"
        rm -f "$stopfile"
        printf 'FAILED|%s|%s||\n' "$((attempt + 1))" "$status" > "$status_file"
        return 1
        ;;
    esac
  done
}

display_loop &
display_pid=$!

declare -a pids
for idx in "${!labels[@]}"; do
  run_set "$idx" &
  pids+=($!)
done

exit_code=0
for pid in "${pids[@]}"; do
  wait "$pid" || exit_code=1
done

kill "$display_pid" 2>/dev/null || true
wait "$display_pid" 2>/dev/null || true
rm -f "$working_directory/loop/"*-STATUS 2>/dev/null || true
rmdir "$working_directory/loop" 2>/dev/null || true

if [ "$exit_code" -eq 0 ]; then
  echo "All sets completed successfully."
else
  echo "One or more sets failed — check logs in $working_directory/rsynclogs/"
fi

exit "$exit_code"
