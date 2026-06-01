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

# Note: if multiple instances are running (different working dirs), --status reports
# an arbitrary one — pgrep returns whichever PID comes first in the process table.
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
        # Guard: skip obviously dangerous or empty paths before running rm -rf via find
        if [ -n "$dst_path" ] && [ "$dst_path" != "/" ]; then
          find "$dst_path" -name ".rsync-partial" -type d -exec rm -rf {} + 2>/dev/null || true
        fi
      fi
    done

    rm -f "$working_directory/loop/"*-PROCEED 2>/dev/null || true
    rm -f "$working_directory/loop/"*-STATUS.tmp 2>/dev/null || true
    rm -f "$working_directory/loop/"*-curfile 2>/dev/null || true
    rm -f "$working_directory/loop/"*-exitcode 2>/dev/null || true
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
  if ! [[ "$_lbl" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: label '$_lbl' — only letters, numbers, hyphens, and underscores are allowed"
    exit 1
  fi
  if [ -n "${_seen_labels[$_lbl]+x}" ]; then
    echo "ERROR: duplicate label '$_lbl' — each label must be unique"
    exit 1
  fi
  _seen_labels[$_lbl]=1
done
unset _seen_labels _lbl

mkdir -p "$working_directory/loop" "$working_directory/rsynclogs"

# Prune log files older than 30 days to prevent unbounded accumulation.
find "$working_directory/rsynclogs" -name "*.txt" -mtime +30 -delete 2>/dev/null || true

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

# --timeout=120: idle-data timeout (no bytes received for 120 s triggers retry).
# --log-file is intentionally NOT here; it is appended per-invocation in run_set so
# each set writes to its own dated log file rather than a shared one.
rsync_base=("$rsync_local_path" -avzh --delete --whole-file --partial-dir=.rsync-partial --timeout=120 --exclude-from="$working_directory/exclude-files.txt" --modify-window=1 --info=progress2 --no-motd --numeric-ids --stats)
[ -n "$rsync_remote_path" ] && rsync_base+=(--rsync-path="$rsync_remote_path")
[ -n "$skip_compress" ] && rsync_base+=("--skip-compress=$skip_compress")

ssh_control_path="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/rsync-warp-%r@%h:%p"
ssh_opts="ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -p $ssh_port -o ControlMaster=auto -o ControlPath=$ssh_control_path -o ControlPersist=60"

max_retries=10

# Seconds between each set's startup when multiple sets run in parallel.
# Spreads SSH handshakes so they don't all race to establish connections simultaneously,
# which can exceed the remote sshd MaxStartups limit and cause immediate exit-255 failures.
# Override with RSYNC_WARP_STAGGER=N (set to 0 to disable).
stagger_secs="${RSYNC_WARP_STAGGER:-8}"

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
      # printf '%q' shell-quotes $path so remote metacharacters can't cause injection.
      local path_q; path_q=$(printf '%q' "$path")
      ssh -p "$ssh_port" "$host" "ls -lad $path_q 2>&1" 2>&1 | tee -a "$log_file" || true
    else
      echo "[SSH] connection FAILED to $host" | tee -a "$log_file"
    fi
  else
    echo "[$direction] local path check: $path" | tee -a "$log_file"
    ls -lad "$path" 2>&1 | tee -a "$log_file" || true
  fi

  echo "--- end preflight $direction ---" | tee -a "$log_file"
}

# Counts files in the source tree so the progress display has a stable denominator.
# rsync's own file counter (ir-chk=N/M) has a growing M during the scan phase; using
# a pre-counted total from find gives a fixed number from the start.
# Simple name patterns from the rsync exclude-from file are applied; directory-anchored
# patterns (containing '/') and include rules ('+') are skipped — translating the full
# rsync filter syntax to find is out of scope, so the count may be slightly high when
# those more complex rules are in use.
# Args: <host-or-empty> <path> <port> <exclude-file>
# Prints the count to stdout; prints 0 on any error.
count_source_files() {
  local host="$1" path="$2" port="$3" exclude_file="$4"

  local -a name_excl=()
  if [ -f "$exclude_file" ]; then
    local rule
    while IFS= read -r rule || [ -n "$rule" ]; do
      [[ -z "${rule//[[:space:]]/}" ]]             && continue  # empty / whitespace-only
      [[ "$rule" =~ ^[[:space:]]*# ]]              && continue  # comment
      [[ "$rule" =~ ^[[:space:]]*\+[[:space:]] ]]  && continue  # include rule — skip
      rule="${rule#- }"                                          # strip "- " exclude prefix
      rule="${rule#"${rule%%[![:space:]]*}"}"                    # strip leading whitespace
      [ -z "$rule" ] && continue
      [[ "$rule" == */* ]] && continue                          # dir-anchored — skip
      name_excl+=("$rule")
    done < "$exclude_file"
  fi

  local count=0
  if [ -n "$host" ]; then
    local cmd; cmd="find $(printf '%q' "$path") -type f"
    local p; for p in "${name_excl[@]}"; do
      cmd+=" -not -name $(printf '%q' "$p")"
    done
    cmd+=" 2>/dev/null | wc -l"
    count=$(ssh -p "$port" -o BatchMode=yes \
      -o ControlMaster=auto -o "ControlPath=$ssh_control_path" -o ControlPersist=60 \
      -o ConnectTimeout=15 "$host" "$cmd" 2>/dev/null) || true
  else
    local -a find_args=("$path" -type f)
    local p; for p in "${name_excl[@]}"; do
      find_args+=(-not -name "$p")
    done
    count=$(find "${find_args[@]}" 2>/dev/null | wc -l) || true
  fi

  count="${count//[[:space:]]/}"     # wc -l pads with leading spaces on some platforms
  printf '%d\n' "${count:-0}" 2>/dev/null || printf '0\n'
}

# Renders a live per-set status table, refreshing every second using ANSI cursor movement.
# Reads <working-dir>/loop/<label>-STATUS files written by run_set.
# Status file format (pipe-delimited, always 5 fields / 4 pipes):
#   WAITING|0||||
#   RUNNING|<attempt>|<progress>|<speed>|<current-file>
#   <progress> is "done/total" from rsync's to-chk counter, or "pct%" as fallback
#   RETRYING|<attempt>|<wake-epoch>|<exit-code>|
#   DONE|<attempt>|||
#   FAILED|<attempt>|<exit-code>||
# Note: <current-file> has any literal '|' characters replaced with '?' to
# protect the delimiter — filenames containing pipes will display with '?'.
display_loop() {
  [ -t 1 ] || return 0   # only render to an interactive terminal
  trap - EXIT             # reset the parent's EXIT trap; don't run cleanup in this subshell
  trap 'printf "\033[999B\n"' EXIT  # on exit, move cursor past banner + table

  local n="${#labels[@]}"
  local total=$(( n + 4 ))  # elapsed + top separator + column headers + n rows + bottom separator
  local _disp_start=$SECONDS  # bash builtin — no subshell needed

  # Terminal width: inherited from the parent shell (set just before display_loop &),
  # where tput cols has reliable TTY access. All three tables use this single value.
  local term_cols="${term_cols:-100}"
  local _inner=$(( term_cols - 2 ))

  # Params table — full-width row value widths (label widths are fixed):
  #   " working-directory: " = 1+18+1 = 20  →  value fills the rest
  #   " remote-host: "       = 1+12+1 = 14  →  value fills the rest
  local _wd_w=$(( _inner - 20 ))
  local _rh_w=$(( _inner - 14 ))

  # Params table — 4-cell row: values scale proportionally to the base 20/11/11/10
  # ratio (sum=52). Fixed label+spacing overhead per cell: 12+11+10+10=43; 3 dividers.
  local _val_total=$(( term_cols - 48 ))
  local _v2=$(( _val_total * 11 / 52 ))
  local _v3=$(( _val_total * 11 / 52 ))
  local _v4=$(( _val_total * 10 / 52 ))
  local _v1=$(( _val_total - _v2 - _v3 - _v4 ))  # gets integer-division slack

  # Sets table — LABEL cell fixed (10-char content + 2 padding = 12);
  # SOURCE/TARGET split the remainder. _st_path_w2 absorbs the 1-char slack on odd widths.
  local _st_path_w=$(( (term_cols - 20) / 2 ))
  local _st_path_w2=$(( term_cols - 20 - _st_path_w ))

  # Status table — file columns fill remaining space after the fixed columns (52 + 2 separator)
  # Fixed overhead: 2+10+2+6+4+2+10+2+12+2 = 52, plus the 2-char sep before PATH = 54
  local _file_avail=$(( term_cols - 54 ))
  local _name_w=$(( _file_avail / 3 ))
  [ "$_name_w" -lt 12 ] && _name_w=12  # must fit "CURRENT FILE" header without overflowing
  local _path_w=$(( _file_avail - _name_w ))

  # Dash strings derived from the widths above
  local _d_inner;   _d_inner=$(printf  '─%.0s' $(seq 1 "$_inner"))
  local _dc1;       _dc1=$(printf      '─%.0s' $(seq 1 $(( 12 + _v1 ))))
  local _dc2;       _dc2=$(printf      '─%.0s' $(seq 1 $(( 11 + _v2 ))))
  local _dc3;       _dc3=$(printf      '─%.0s' $(seq 1 $(( 10 + _v3 ))))
  local _dc4;       _dc4=$(printf      '─%.0s' $(seq 1 $(( 10 + _v4 ))))
  local _d_stlabel; _d_stlabel=$(printf '─%.0s' $(seq 1 12))
  local _d_stpath1; _d_stpath1=$(printf '─%.0s' $(seq 1 $(( _st_path_w  + 2 ))))
  local _d_stpath2; _d_stpath2=$(printf '─%.0s' $(seq 1 $(( _st_path_w2 + 2 ))))
  local sep;        sep=$(printf        '─%.0s' $(seq 1 "$term_cols"))

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
  [ "${#wd_disp}" -gt "$_wd_w" ] && wd_disp="…${wd_disp: -(( _wd_w - 1 ))}"
  local rh_disp="${remote_host:-(local)}"
  [ "${#rh_disp}" -gt "$_rh_w" ] && rh_disp="…${rh_disp: -(( _rh_w - 1 ))}"

  # Colors
  local _bd=$'\033[90m'    # dark gray     — borders
  local _lb=$'\033[36m'    # cyan          — labels
  local _vl=$'\033[93m'    # bright yellow — values
  local _rs=$'\033[0m'     # reset
  local _c_run=$'\033[92m' # bright green  — running ▶
  local _c_ret=$'\033[93m' # bright yellow — retrying ⟳
  local _c_don=$'\033[33m' # gold          — done ✓
  local _c_err=$'\033[91m' # bright red    — failed ✗

  printf "${_bd}┌%s┐${_rs}\n" "$_d_inner"
  printf "${_bd}│${_rs} ${_lb}working-directory:${_rs} ${_vl}%-${_wd_w}s${_rs}${_bd}│${_rs}\n" "$wd_disp"
  printf "${_bd}├%s┤${_rs}\n" "$_d_inner"
  printf "${_bd}│${_rs} ${_lb}remote-host:${_rs} ${_vl}%-${_rh_w}s${_rs}${_bd}│${_rs}\n" "$rh_disp"
  printf "${_bd}├%s┬%s┬%s┬%s┤${_rs}\n" "$_dc1" "$_dc2" "$_dc3" "$_dc4"
  printf "${_bd}│${_rs} ${_lb}remote-is:${_rs} ${_vl}%-${_v1}s${_rs}${_bd}│${_rs} ${_lb}ssh-port:${_rs} ${_vl}%-${_v2}s${_rs}${_bd}│${_rs} ${_lb}dry-run:${_rs} ${_vl}%-${_v3}s${_rs}${_bd}│${_rs} ${_lb}verbose:${_rs} ${_vl}%-${_v4}s${_rs}${_bd}│${_rs}\n" \
    "${remote_is:-(local)}" "$ssh_port" "$dry_run" "$verbose"
  printf "${_bd}└%s┴%s┴%s┴%s┘${_rs}\n" "$_dc1" "$_dc2" "$_dc3" "$_dc4"
  printf '\n'
  printf ' rsync-warp  ●  %d set(s)\n' "$n"
  printf '\n'

  printf "${_bd}┌%s┬%s┬%s┐${_rs}\n" "$_d_stlabel" "$_d_stpath1" "$_d_stpath2"
  printf "${_bd}│${_rs} ${_lb}%-10s${_rs} ${_bd}│${_rs} ${_lb}%-${_st_path_w}s${_rs} ${_bd}│${_rs} ${_lb}%-${_st_path_w2}s${_rs} ${_bd}│${_rs}\n" \
    "LABEL" "SOURCE PATH" "TARGET PATH"
  printf "${_bd}├%s┼%s┼%s┤${_rs}\n" "$_d_stlabel" "$_d_stpath1" "$_d_stpath2"
  local _si
  for _si in "${!labels[@]}"; do
    local _lbl_s="${labels[$_si]}"
    local _sp="${source_paths[$_si]}"
    local _tp="${target_paths[$_si]}"
    [ "${#_lbl_s}" -gt 10 ] && _lbl_s="${_lbl_s:0:9}…"
    [ "${#_sp}" -gt "$_st_path_w"  ] && _sp="${_sp:0:$(( _st_path_w  - 1 ))}…"
    [ "${#_tp}" -gt "$_st_path_w2" ] && _tp="${_tp:0:$(( _st_path_w2 - 1 ))}…"
    printf "${_bd}│${_rs} ${_vl}%-10s${_rs} ${_bd}│${_rs} ${_vl}%-${_st_path_w}s${_rs} ${_bd}│${_rs} ${_vl}%-${_st_path_w2}s${_rs} ${_bd}│${_rs}\n" \
      "$_lbl_s" "$_sp" "$_tp"
  done
  printf "${_bd}└%s┴%s┴%s┘${_rs}\n" "$_d_stlabel" "$_d_stpath1" "$_d_stpath2"
  printf '\n'

  # Reserve display space for the status table
  local i; for (( i = 0; i < total; i++ )); do printf '\n'; done

  while true; do
    printf '\033[%dA' "$total"  # move cursor back to top of display area

    local elapsed=$(( SECONDS - _disp_start ))
    printf ' elapsed %02d:%02d\033[K\n' \
      "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"
    printf '%s\033[K\n' "$sep"
    # Column headers — FILES shows rsync to-chk progress (files done / total files in set)
    printf "  %-10s  %-4s  %-4s  %-10s  %-12s  %-*s  %s\033[K\n" \
      "LABEL" "ST" "ATT" "FILES" "SPEED" "$_name_w" "CURRENT FILE" "PATH"

    local idx
    for idx in "${!labels[@]}"; do
      local lbl="${labels[$idx]}"
      local lbl_disp="$lbl"
      [ "${#lbl_disp}" -gt 10 ] && lbl_disp="${lbl_disp:0:9}…"
      local sf="$working_directory/loop/${lbl}-STATUS"
      local state="" attempt="" f3="" f4="" f5=""
      [ -f "$sf" ] && IFS='|' read -r state attempt f3 f4 f5 < "$sf" || true

      case "${state:-WAITING}" in
        RUNNING)
          local fname fdir
          if [ -z "$f5" ] || [ "$f5" = "-" ]; then
            fname="-"; fdir=""
          else
            fname="${f5##*/}"
            fdir="${f5%/*}"; [ "$fdir" = "$f5" ] && fdir=""
            # When source-path has no trailing slash, rsync prefixes paths with the
            # source directory name (e.g. "photos/subdir/file"). Strip that prefix
            # since the source dir is already visible in the static sets table above.
            local _src_base="${source_paths[$idx]%/}"; _src_base="${_src_base##*/}"
            [ "$fdir" = "$_src_base" ] && fdir=""
            [[ "$fdir" == "$_src_base/"* ]] && fdir="${fdir#"$_src_base/"}"
          fi
          [ "${#fname}" -gt "$_name_w" ] && fname="${fname:0:$(( _name_w - 1 ))}…"
          [ "${#fdir}" -gt "$_path_w" ] && fdir="${fdir:0:$(( _path_w - 1 ))}…"
          printf "  %-10s  ${_c_run}▶${_rs}     %-4s  %-10s  %-12s  %-*s  %s\033[K\n" \
            "$lbl_disp" "$attempt" "${f3:----}" "${f4:------}" "$_name_w" "$fname" "$fdir"
          ;;
        RETRYING)
          local remaining=$(( ${f3:-0} - $(date +%s) ))
          [ "$remaining" -lt 0 ] && remaining=0
          printf "  %-10s  ${_c_ret}⟳${_rs}     %-4s  retrying in %ds  (attempt %s/%s, exit %s)\033[K\n" \
            "$lbl_disp" "$attempt" "$remaining" "$attempt" "$max_retries" "${f4:--}"
          ;;
        DONE)
          printf "  %-10s  ${_c_don}✓${_rs}     %-4s  completed\033[K\n" "$lbl_disp" "$attempt"
          ;;
        FAILED)
          printf "  %-10s  ${_c_err}✗${_rs}     %-4s  failed (exit %s)\033[K\n" "$lbl_disp" "$attempt" "$f3"
          ;;
        *)
          printf '  %-10s  ·     waiting\033[K\n' "$lbl_disp"
          ;;
      esac
    done

    printf '%s\033[K\n' "$sep"
    # Exit as soon as every set is in a terminal state so the final render
    # (drawn above) remains visible before the main script prints its summary.
    # Without this the main script kills the display mid-cycle, leaving the
    # last-completed set still showing ▶ on a quick console inspection.
    local _all_done=1 _di _sf _st
    for _di in "${!labels[@]}"; do
      _sf="$working_directory/loop/${labels[$_di]}-STATUS"
      _st=""
      [ -f "$_sf" ] && IFS='|' read -r _st _ _ _ _ < "$_sf" || true
      case "${_st:-}" in DONE|FAILED) ;; *) _all_done=0; break ;; esac
    done
    [ "$_all_done" -eq 1 ] && break
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

  # Per-set ControlMaster socket: embed the label so each set gets its own
  # independent SSH connection. Sharing one master across concurrent sets causes
  # every new set's rsync handshake to inject traffic into a connection that may
  # already be saturated (e.g. streaming a 500K-file list), disrupting it with
  # exit-255 failures. Retries still benefit from the master — same label = same
  # socket = same persistent connection.
  local ssh_control_path="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/rsync-warp-${label}-%r@%h:%p"
  local ssh_opts="ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -p $ssh_port -o ControlMaster=auto -o ControlPath=$ssh_control_path -o ControlPersist=60"

  # Stagger startup: set N waits N*stagger_secs before doing any SSH work.
  # Prevents all sets from racing to establish SSH connections simultaneously.
  [ "$idx" -gt 0 ] && [ "${stagger_secs:-0}" -gt 0 ] && sleep "$(( idx * stagger_secs ))"

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

  # Pre-count source files for a stable progress denominator — local sources only.
  # For remote sources (source_host set) we skip this: running an SSH find concurrently
  # with rsync adds a channel to the shared ControlMaster connection, which disrupts the
  # in-flight rsync on some NAS SSH implementations. Remote sources instead lock the
  # denominator from rsync's own first to-chk=N/M line (see progress parser below).
  local file_total=0
  if [ -z "${source_host:-}" ]; then
    local _cnt_path
    [[ "$src_path" == /* ]] && _cnt_path="$src_path" || _cnt_path="$working_directory/$src_path"
    file_total=$(count_source_files "" "$_cnt_path" \
      "$ssh_port" "$working_directory/exclude-files.txt") || file_total=0
    echo "source file count: $file_total" >> "$LOG_FILE"
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
      # Progress line (scan phase):    "   1,234,567   0%    0.00kB/s    0:00:00 (xfr#1, ir-chk=42/100)"
      # Progress line (transfer phase): "   1,234,567  45%   2.34MB/s    0:00:15 (xfr#5, to-chk=42/100)"
      if [[ "$line" =~ ^[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+)%[[:space:]]+([0-9.]+[kKMGTP]?B/s) ]]; then
        local cf; cf=$(cat "$curfile_tmp" 2>/dev/null || printf '%s' '-')
        local pct="${BASH_REMATCH[1]}" speed="${BASH_REMATCH[2]}"
        local progress
        # Track file-count progress from rsync's ir-chk / to-chk counters.
        #   ir-chk=N/M  scan phase: N files remaining to discover, M grows as rsync scans
        #   to-chk=N/M  transfer phase: N files remaining, M is stable (scan complete)
        # files_done = M - N (files processed so far in either phase).
        #
        # Denominator priority (highest → lowest):
        #   1. file_total  — find pre-count (local source only); fully stable from t=0
        #   2. _locked_total — rsync's M from the first to-chk line; stable once set
        #   3. rsync's live M — grows during ir-chk, used only until option 2 is available
        #
        # For remote sources we can't run a pre-count without adding an extra SSH channel
        # that disrupts the in-flight rsync connection, so we rely on options 2 and 3.
        # During to-chk, the counter only appears on the final (100%) line of each file;
        # intermediate byte-level updates have no counter. We cache the last known value
        # in _last_file_progress so the column stays stable between counter updates.
        if [[ "$line" =~ (to-chk|ir-chk)=([0-9]+)/([0-9]+) ]]; then
          local files_done=$(( ${BASH_REMATCH[3]} - ${BASH_REMATCH[2]} ))
          if [[ "${BASH_REMATCH[1]}" == "to-chk" ]] && [ -z "${_locked_total:-}" ]; then
            _locked_total="${BASH_REMATCH[3]}"
          fi
          local denom="${_locked_total:-${BASH_REMATCH[3]}}"
          [ "${file_total:-0}" -gt 0 ] && denom="$file_total"
          _last_file_progress="${files_done}/${denom}"
          progress="$_last_file_progress"
        else
          progress="${_last_file_progress:-${pct}%}"
        fi
        # Filenames containing '|' (valid on Unix) are sanitised with '?' to protect
        # the pipe-delimited status file format; display only — no data is lost.
        printf 'RUNNING|%s|%s|%s|%s\n' \
          "$((attempt + 1))" "$progress" "$speed" "${cf//|/?}" \
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
      # Close the ControlMaster socket now that this set is finished; it would
      # expire on its own after ControlPersist=60 s but explicit cleanup is cleaner.
      local ctrl_host="${source_host:-$target_host}"
      [ -n "$ctrl_host" ] && ssh -O exit -o "ControlPath=$ssh_control_path" -p "$ssh_port" "$ctrl_host" 2>/dev/null || true
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
        sleep "$base_delay"
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

# Read terminal width in the parent shell where tput has reliable TTY access.
# display_loop inherits this value; tput cols is unreliable in background processes.
term_cols=$(tput cols 2>/dev/null || echo 100)
[ "$term_cols" -lt 80 ] && term_cols=80

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
rm -f "$working_directory/loop/"*-STATUS "$working_directory/loop/"*-STATUS.tmp 2>/dev/null || true
rmdir "$working_directory/loop" 2>/dev/null || true

if [ "$exit_code" -eq 0 ]; then
  echo "All sets completed successfully."
else
  echo "One or more sets failed — check logs in $working_directory/rsynclogs/"
fi

exit "$exit_code"
