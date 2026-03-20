#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage:
  $0 <remote-host> <working-dir> <dry-run:true|false> <ssh-port> <label> <source> <target> [<label> <source> <target> ...]

  ssh-port: SSH port number (default: 22)

Example:
  $0 example.com /var/backups true 22 mydata /data /remote/data
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

if [ "$#" -lt 5 ]; then
  echo "ERROR: insufficient arguments"
  usage
  exit 1
fi

remote_host=$1
working_directory=$2
dry_run=$3
ssh_port=${4:-22}
shift 4


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

echo "Remote Host: $remote_host"
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

ssh_opts="ssh -c aes128-gcm@openssh.com -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -p $ssh_port -o ControlMaster=auto -o ControlPath=/tmp/rsync-warp-%r@%h:%p -o ControlPersist=60"

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
  echo "Backing up label=$label source=$src target=$dst, log=$LOG_FILE"

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

    rsync_cmd=("${rsync_base[@]}" ${dry_run_flag:+"$dry_run_flag"} -e "$ssh_opts" --log-file="$LOG_FILE" "$src" "$remote_host:$dst")

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
      10|30|32|255)
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
        echo "rsync failed with exit $status" | tee -a "$LOG_FILE"
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
