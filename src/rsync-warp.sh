#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage:
  $0 <source-host> <target-host> <working-dir> <dry-run:true|false> <ssh-port> <label> <source> <target> [<label> <source> <target> ...]

  source-host: SSH host to read source paths from. Pass "" for local machine.
  target-host: SSH host to write target paths to. Pass "" for local machine.
  working-dir: Local working directory for logs and control files. Pass "" for current directory.
  ssh-port:    SSH port number (default: 22). Used for whichever host is remote.

  Note: at least one of source-host or target-host must be empty. Remote-to-remote
        transfers are not supported.

  Local path resolution:
    Paths starting with "/" are treated as absolute.
    All other paths are resolved relative to working-dir.

Examples:
  Local to remote:
    $0 "" remote.example.com /var/backups false 22 mydata /data /remote/data

  Remote to local:
    $0 remote.example.com "" /var/backups false 22 mydata /remote/data /local/data

  Local to local:
    $0 "" "" /var/backups false 22 mydata /data /local/backup
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

if [ "$#" -lt 6 ]; then
  echo "ERROR: insufficient arguments"
  usage
  exit 1
fi

source_host=$1
target_host=$2
working_directory=$3
dry_run=$4
ssh_port=${5:-22}
shift 5


case "${dry_run,,}" in
  true) dry_run_flag="--dry-run" ;; 
  false) dry_run_flag="" ;; 
  *)
    echo "ERROR: dry-run must be 'true' or 'false'"
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

trap 'stop_all=1; touch "$STOPALLFILE" 2>/dev/null || true; echo "SIGINT/SIGTERM received; stopping after current rsync attempt..."' SIGINT SIGTERM

cleanup() {
  if [ "${stop_all:-0}" -eq 1 ]; then
    echo "Cleanup: removing proceed files and exiting"
    rm -f "$working_directory/loop/"*-PROCEED 2>/dev/null || true
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

rsync_base=(/usr/local/bin/rsync -avzh --delete --whole-file --partial --timeout=20 --exclude-from="$working_directory/exclude-files.txt" --modify-window=1 --info=progress2 --no-motd --numeric-ids --stats)
[ -n "$skip_compress" ] && rsync_base+=("--skip-compress=$skip_compress")

ssh_opts="ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -p $ssh_port -o ControlMaster=auto -o ControlPath=/tmp/rsync-warp-%r@%h:%p -o ControlPersist=60"

max_retries=10

run_set() {
  local idx=$1
  local label=${labels[$idx]}
  local src=${sources[$idx]}
  local dst=${targets[$idx]}
  local stopfile="$working_directory/loop/${label}-PROCEED"
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

  echo "Transferring label=$label source=$rsync_src target=$rsync_dst, log=$LOG_FILE"

  while true; do
    if [ "${stop_all:-0}" -eq 1 ]; then
      echo "Signal request: stop_all=1; canceling item $label"
      return 1
    fi

    if [ -f "$STOPALLFILE" ]; then
      echo "STOPALL file exists: canceling all jobs"
      return 1
    fi

    if [ ! -f "$stopfile" ]; then
      echo "$stopfile does not exist: canceling item"
      return 1
    fi

    echo "Attempt: $((attempt + 1)), log: $LOG_FILE"

    rsync_cmd=("${rsync_base[@]}" ${dry_run_flag:+"$dry_run_flag"} -e "$ssh_opts" --log-file="$LOG_FILE" "$rsync_src" "$rsync_dst")

    # Run rsync in a new process group so Ctrl+C/SIGINT on this script only sets stop_all and
    # does not immediately terminate the active transfer.
    if setsid "${rsync_cmd[@]}"; then
      status=0
    else
      status=$?
    fi

    if [ "$status" -eq 0 ]; then
      rm -f "$stopfile"
      echo "rsync completed successfully (exit $status)" | tee -a "$LOG_FILE"
      echo "***********************************************" | tee -a "$LOG_FILE"
      return 0
    fi

    case "$status" in
      10|12|30|32|35|255)
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_retries" ]; then
          echo "rsync failed with exit $status after $attempt retries; giving up" | tee -a "$LOG_FILE"
          rm -f "$stopfile"
          return 1
        fi
        echo "rsync transient failure exit $status; retrying in $base_delay seconds" | tee -a "$LOG_FILE"
        echo "***********************************************" | tee -a "$LOG_FILE"
        sleep $base_delay
        base_delay=$((base_delay * 2))
        [ "$base_delay" -gt 300 ] && base_delay=300
        continue
        ;;
      *)
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
        echo "rsync failed (exit $status): $err_msg" | tee -a "$LOG_FILE"
        echo "***********************************************" | tee -a "$LOG_FILE"
        rm -f "$stopfile"
        return 1
        ;;
    esac
  done
}

cd "$working_directory"

echo "Starting rsync warp backup"

declare -a pids
for idx in "${!labels[@]}"; do
  run_set "$idx" &
  pids+=($!)
done

exit_code=0
for pid in "${pids[@]}"; do
  wait "$pid" || exit_code=1
done

exit "$exit_code"
