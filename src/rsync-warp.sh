#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage:
  $0 <source-host> <target-host> <working-dir> <dry-run:true|false> <ssh-port> <verbose:true|false> <label> <source> <target> [<label> <source> <target> ...]

  source-host: SSH host to read source paths from. Pass "" for local machine.
  target-host: SSH host to write target paths to. Pass "" for local machine.
  working-dir: Local working directory for logs and control files. Pass "" for current directory.
  ssh-port:    SSH port number (default: 22). Used for whichever host is remote.
  verbose:     true enables pre-flight SSH/path checks before each attempt and
               increases rsync logging detail. false for normal operation.

  Note: at least one of source-host or target-host must be empty. Remote-to-remote
        transfers are not supported.

  Local path resolution:
    Paths starting with "/" are treated as absolute.
    All other paths are resolved relative to working-dir.

Examples:
  Local to remote:
    $0 "" remote.example.com /var/backups false 22 false mydata /data /remote/data

  Remote to local:
    $0 remote.example.com "" /var/backups false 22 false mydata /remote/data /local/data

  Local to local:
    $0 "" "" /var/backups false 22 false mydata /data /local/backup

  Local to remote with diagnostics enabled:
    $0 "" remote.example.com /var/backups false 22 true mydata /data /remote/data
EOF
}

if [ "$#" -eq 1 ] && [ "$1" = "--status" ]; then
  pid=$(pgrep -f "[r]sync-warp.sh" | head -n 1) || true
  if [ -z "$pid" ]; then
    echo "rsync-warp is not running"
    exit 1
  fi
  echo "rsync-warp running: pid=$pid"
  ps -o pid,stat,cmd -p "$pid"
  exit 0
fi

if [ "$#" -lt 7 ]; then
  echo "ERROR: insufficient arguments"
  usage
  exit 1
fi

source_host=$1
target_host=$2
working_directory=$3
dry_run=$4
ssh_port=${5:-22}
verbose=$6
shift 6


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

if [ -z "$working_directory" ]; then
  working_directory="$(pwd)"
fi

if [ -n "$source_host" ] && [ -n "$target_host" ]; then
  echo "ERROR: remote-to-remote transfers are not supported; at least one of source-host or target-host must be empty"
  exit 1
fi

stop_all=0
STOPALLFILE="$working_directory/loop/STOPALL"

trap 'stop_all=1; touch "$STOPALLFILE" 2>/dev/null || true; echo "SIGINT/SIGTERM received; terminating active transfers..."' SIGINT SIGTERM

cleanup() {
  if [ "${stop_all:-0}" -eq 1 ]; then
    echo "Cleanup: removing partial files, control files, and loop directory"

    # Remove .rsync-partial directories left by interrupted transfers on local targets
    for idx in "${!targets[@]}"; do
      dst="${targets[$idx]}"
      if [ -z "$target_host" ]; then
        [[ "$dst" != /* ]] && dst="$working_directory/$dst"
        find "$dst" -name ".rsync-partial" -type d -exec rm -rf {} + 2>/dev/null || true
      fi
    done

    rm -f "$working_directory/loop/"*-PROCEED 2>/dev/null || true
    rm -f "$STOPALLFILE" 2>/dev/null || true
    rmdir "$working_directory/loop" 2>/dev/null || true
  fi
}
trap cleanup EXIT


declare -a labels sources targets

while [ "$#" -gt 0 ]; do
  if [ "$#" -lt 3 ]; then
    echo "ERROR: target entries must come in label/source/target groups"
    usage
    exit 1
  fi
  labels+=("$1")
  sources+=("$2")
  targets+=("$3")
  shift 3
done

set_count=${#labels[@]}

if [ "$set_count" -le 0 ]; then
  echo "ERROR: no backup sets provided"
  usage
  exit 1
fi

echo "Source Host: ${source_host:-local}"
echo "Target Host: ${target_host:-local}"
echo "SSH Port:    $ssh_port"
echo "Working Dir: $working_directory"
echo "Dry Run:     $dry_run"
echo "Verbose:     $verbose"
echo "Set Count:   $set_count"

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

# Override the remote rsync binary path. Leave empty to rely on the remote's PATH.
# Set to /usr/bin/rsync for Synology NAS or any remote where rsync is not in the default SSH PATH.
rsync_remote_path="${RSYNC_REMOTE_PATH:-}"

rsync_base=(rsync -avzh --delete --whole-file --partial-dir=.rsync-partial --timeout=20 --exclude-from="$working_directory/exclude-files.txt" --modify-window=1 --info=progress2 --no-motd --numeric-ids --stats)
[ -n "$rsync_remote_path" ] && rsync_base+=(--rsync-path="$rsync_remote_path")
[ -n "$skip_compress" ] && rsync_base+=("--skip-compress=$skip_compress")

ssh_opts="ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -p $ssh_port -o ControlMaster=auto -o ControlPath=/tmp/rsync-warp-%r@%h:%p -o ControlPersist=60"

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
 _ __ ___ _   _ _ __   ___  -  __        ___    ____  ____
| '__/ __| | | | '_ \ / __|    \ \      / / \  |  _ \|  _ \
| |  \__ \ |_| | | | | (__      \ \ /\ / / _ \ | |_) || |_) |
|_|  |___/\__, |_| |_|\___| -   \ V  V / ___ \|  _ < |  __/
          |___/                   \_/\_/_/   \_\_| \_\_|
BANNER

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
          printf '  %-14s  ▶   %-4s  %-8s  %-12s  %s\033[K\n' \
            "$lbl" "$attempt" "${f3:----}" "${f4:------}" "$disp"
          ;;
        RETRYING)
          local remaining=$(( ${f3:-0} - $(date +%s) ))
          [ "$remaining" -lt 0 ] && remaining=0
          printf '  %-14s  ⟳   %-4s  retrying in %ds  (attempt %s/%s, exit %s)\033[K\n' \
            "$lbl" "$attempt" "$remaining" "$attempt" "$max_retries" "${f4:--}"
          ;;
        DONE)
          printf '  %-14s  ✓   %-4s  completed\033[K\n' "$lbl" "$attempt"
          ;;
        FAILED)
          printf '  %-14s  ✗   %-4s  failed (exit %s)\033[K\n' "$lbl" "$attempt" "$f3"
          ;;
        *)
          printf '  %-14s  ·        waiting\033[K\n' "$lbl"
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
  local src=${sources[$idx]}
  local dst=${targets[$idx]}
  local stopfile="$working_directory/loop/${label}-PROCEED"
  local status_file="$working_directory/loop/${label}-STATUS"
  local curfile_tmp="$working_directory/loop/${label}-curfile"
  local attempt=0
  local base_delay=5

  local LOG_FILE="${working_directory}/rsynclogs/${label}-$(date +%Y-%m-%d_%H-%M-%S).txt"

  # Resolve source path
  local rsync_src
  if [ -n "$source_host" ]; then
    rsync_src="$source_host:$src"
  elif [[ "$src" == /* ]]; then
    rsync_src="$src"
  else
    rsync_src="$working_directory/$src"
  fi

  # Resolve target path
  local rsync_dst
  if [ -n "$target_host" ]; then
    rsync_dst="$target_host:$dst"
  elif [[ "$dst" == /* ]]; then
    rsync_dst="$dst"
  else
    rsync_dst="$working_directory/$dst"
  fi

  echo "label=$label src=$rsync_src dst=$rsync_dst log=$LOG_FILE" >> "$LOG_FILE"
  printf 'WAITING|0||||\n' > "$status_file"

  if [ "${verbose,,}" = "true" ]; then
    preflight_check "$LOG_FILE" "$source_host" "$src" "source" >/dev/null
    preflight_check "$LOG_FILE" "$target_host" "$dst" "target" >/dev/null
  fi

  while true; do
    if [ "${stop_all:-0}" -eq 1 ]; then
      echo "Signal: stop_all=1; canceling $label" >> "$LOG_FILE"
      printf 'FAILED|%s|stopped||\n' "$attempt" > "$status_file"
      return 1
    fi

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
    [ "${verbose,,}" = "true" ] && rsync_cmd+=("--verbose" "--verbose")

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
      if [[ "$line" =~ ^[[:space:]]+[0-9,]+[[:space:]]+([0-9]+)%[[:space:]]+([0-9.]+[kKMGTP]?B/s) ]]; then
        local cf; cf=$(cat "$curfile_tmp" 2>/dev/null || printf '%s' '-')
        printf 'RUNNING|%s|%s%%|%s|%s\n' \
          "$((attempt + 1))" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${cf//|/?}" \
          > "$status_file"
      # Filename line: non-empty, starts with non-space, not a stats/message line
      elif [[ -n "$line" ]] && [[ "$line" =~ ^[^[:space:]] ]] && \
           ! [[ "$line" =~ ^(sent\ |received\ |total\ |Number\ |File\ list|Literal|Matched|creating\ |rsync:\ |building|delta-|sending\ incremental|done\ count|created\ dir|opening\ connection|\.[cdLDS]) ]]; then
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
          ssh -O exit -o "ControlPath=/tmp/rsync-warp-%r@%h:%p" -p "$ssh_port" "$ctrl_host" 2>/dev/null || true
        fi
        if [ "${verbose,,}" = "true" ]; then
          preflight_check "$LOG_FILE" "$source_host" "$src" "source" >/dev/null
          preflight_check "$LOG_FILE" "$target_host" "$dst" "target" >/dev/null
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

cd "$working_directory"

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

if [ "$exit_code" -eq 0 ]; then
  echo "All sets completed successfully."
else
  echo "One or more sets failed — check logs in $working_directory/rsynclogs/"
fi

exit "$exit_code"
