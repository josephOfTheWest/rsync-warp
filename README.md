# rsync-warp

A Bash wrapper around `rsync` that optimizes and controls file transfers between a local machine and a remote SSH endpoint. Designed for reliable, resumable, multi-set transfers with parallel execution, intelligent retry logic, and fine-grained run control.

---

## Table of Contents

- [Requirements](#requirements)
- [Repository Structure](#repository-structure)
- [SSH Key Setup](#ssh-key-setup)
- [Setup](#setup)
- [Configuration Files](#configuration-files)
  - [exclude-files.txt](#exclude-filestxt)
  - [skip-compress.txt](#skip-compresstxt)
- [Usage](#usage)
  - [Syntax](#syntax)
  - [Arguments](#arguments)
  - [Examples](#examples)
- [How It Works](#how-it-works)
  - [Parallel Execution](#parallel-execution)
  - [Retry and Backoff](#retry-and-backoff)
  - [SSH ControlMaster](#ssh-controlmaster)
  - [Compression](#compression)
  - [Logging](#logging)
  - [Run Control Files](#run-control-files)
- [Controlling a Running Session](#controlling-a-running-session)
  - [Check Status](#check-status)
  - [Stop All Sets](#stop-all-sets)
  - [Cancel a Single Set](#cancel-a-single-set)
  - [Resume a Cancelled Set](#resume-a-cancelled-set)
- [Customization](#customization)
- [Troubleshooting](#troubleshooting)

---

## Requirements

- **Bash** 4.0 or later (uses arrays and `${var,,}` case folding)
- **rsync** installed on both local and remote machines. If rsync is not in the default PATH on either side (e.g. Synology NAS), set `RSYNC_LOCAL_PATH` or `RSYNC_REMOTE_PATH` — see [Customization](#customization)
- **SSH** access to the remote host with key-based authentication
- **setsid** available (standard on Linux; used to isolate rsync from SIGINT)

---

## Repository Structure

```
rsync-warp/
├── src/
│   ├── rsync-warp.sh          # Main script
│   ├── exclude-files.txt      # rsync exclude patterns (copy to working directory)
│   └── skip-compress.txt      # File types to skip compression (copy to working directory)
└── README.md
```

---

## SSH Key Setup

rsync-warp uses SSH key-based authentication — passwords are not supported because rsync runs non-interactively. If you have not set up SSH keys before, follow these steps.

### Step 1 — Generate a key pair

Run this on the **local machine** (the one running rsync-warp):

```bash
ssh-keygen -t ed25519 -C "rsync-warp"
```

- When prompted for a file location, press **Enter** to accept the default (`~/.ssh/id_ed25519`)
- When prompted for a passphrase, either:
  - Press **Enter** twice to use no passphrase (simplest for automated/scheduled use)
  - Enter a passphrase for added security (you will need `ssh-agent` to avoid being prompted on each run — see Step 3)

This creates two files:

| File | Description |
|------|-------------|
| `~/.ssh/id_ed25519` | Private key — keep this secret, never share it |
| `~/.ssh/id_ed25519.pub` | Public key — this is what you install on the remote host |

### Step 2 — Install the public key on the remote host

```bash
ssh-copy-id -p 22 user@remote.example.com
```

Replace `user` with your username on the remote host. If `ssh-copy-id` is not available (e.g. on macOS without Homebrew), use this equivalent:

```bash
cat ~/.ssh/id_ed25519.pub | ssh -p 22 user@remote.example.com "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### Step 3 — (Optional) Use ssh-agent for passphrase keys

If you set a passphrase in Step 1, add the key to `ssh-agent` so rsync-warp can authenticate without prompting:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

To have the key loaded automatically at login, add both lines to your `~/.bashrc` or `~/.bash_profile`.

### Step 4 — Verify the connection

```bash
ssh -p 22 user@remote.example.com echo ok
```

You should see `ok` printed with no password prompt. If this works, rsync-warp is ready to use.

### Troubleshooting SSH key setup

**`Permission denied (publickey)`**
The public key is not installed on the remote, or the remote's `~/.ssh/authorized_keys` has wrong permissions. On the remote host, run:
```bash
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

**Still prompted for a password**
The remote's `sshd` may not allow key authentication. Check `/etc/ssh/sshd_config` on the remote for `PubkeyAuthentication yes`.

**Multiple keys on the same machine**
If you have more than one key pair, you can pin which key rsync-warp uses by adding a `Host` block to `~/.ssh/config`:
```
Host remote.example.com
    IdentityFile ~/.ssh/id_ed25519
    Port 22
```

---

## Setup

1. **Copy the script** to a location on your `PATH`, or invoke it directly.

2. **Create a working directory** — this is where rsync-warp stores logs and run-control files:
   ```bash
   mkdir -p /var/rsync-warp
   ```

3. **Copy the configuration files** to the working directory:
   ```bash
   cp src/exclude-files.txt /var/rsync-warp/
   cp src/skip-compress.txt /var/rsync-warp/
   ```

4. **Verify SSH access** to the remote host before running:
   ```bash
   ssh -p 22 user@remote.example.com echo ok
   ```

---

## Configuration Files

Both files must be present in the working directory. The `src/` copies in this repository are the canonical templates — edit them there and redeploy, or edit in place in your working directory.

### exclude-files.txt

Defines rsync exclude patterns — files and directories that will never be transferred. Patterns match anywhere in the path (no leading wildcard needed). Edit this file to add project-specific exclusions under the `# Job specific Excludes` section.

**Default exclusions:**

| Pattern | Description |
|---------|-------------|
| `rsync-warp.sh` | This script |
| `exclude-files.txt` | This exclude file |
| `skip-compress.txt` | Compression skip list |
| `rsynclogs/` | rsync-warp log directory |
| `loop/` | rsync-warp run-control directory |
| `System Volume Information/` | Windows VSS / restore point data |
| `FileHistory/` | Windows File History backups |
| `$Recycle.Bin/` | Windows recycle bin (Vista+) |
| `$RECYCLE.BIN/` | Windows recycle bin (alternate casing) |
| `RECYCLER/` | Windows recycle bin (XP) |
| `pagefile.sys` | Windows page file |
| `swapfile.sys` | Windows swap file |
| `hiberfil.sys` | Windows hibernation file |
| `@eaDir/` | Synology extended attributes store |
| `@SynoEAStream/` | Synology EA streams |
| `@sharebin/` | Synology per-share recycle bin |
| `@tmp/` | Synology temp files |
| `@Recently-Snapshot/` | Synology recent snapshots |
| `@database/` | Synology internal database |
| `@appstore/` | Synology Package Center data |
| `@LogCenter/` | Synology Log Center data |
| `#recycle/` | Synology recycle bin directories |
| `#snapshot/` | Synology snapshot directories |
| `.bzvol/` | Backblaze volume metadata |

**Adding job-specific exclusions:**

Uncomment and edit the placeholder at the bottom of the file:
```
# Job specific Excludes
/media/photos/raw-archive/*
/media/videos/source/*
```

Paths starting with `/` are anchored to the source root. Paths without `/` match anywhere in the tree.

---

### skip-compress.txt

Lists file extensions (one per line, no leading dot) that rsync will **not** compress during transfer. These are already-compressed formats where re-compressing wastes CPU with no size benefit.

The file is read at startup and the extension list is passed to rsync via `--skip-compress`. Lines starting with `#` and blank lines are ignored.

**To add an extension:**
```
# My custom types
lz5
cab
```

---

## Usage

### Syntax

```bash
bash src/rsync-warp.sh <remote-host> <remote-is> <working-dir> <ssh-port> <dry-run> <verbose> <label> <source-path> <target-path> [<label> <source-path> <target-path> ...]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `remote-host` | SSH hostname or IP for the remote endpoint. Pass `""` for local-to-local transfers |
| `remote-is` | `"source"` if the remote provides files; `"target"` if it receives them. Pass `""` for local-to-local |
| `working-dir` | Local directory for logs and run-control files. Pass `""` to use the current directory (default) |
| `ssh-port` | SSH port for the remote host. Pass `""` to use the default (`22`) |
| `dry-run` | `true` to simulate the transfer without writing files; `false` for a live run. Default: `false` |
| `verbose` | `true` enables pre-flight SSH/path checks and increased rsync log detail. Default: `false` |
| `label` | Unique name for this transfer set. Used for log file names and run-control files. Only letters, numbers, hyphens, and underscores are allowed |
| `source-path` | Path to sync from. Absolute if starting with `/`; otherwise relative to `working-dir` |
| `target-path` | Path to sync to. Absolute if starting with `/`; otherwise relative to `working-dir` |

**Notes:**
- `remote-host` and `remote-is` together replace the former separate `source-host` and `target-host` parameters, making it explicit that only one endpoint can be remote.
- Default values apply when `""` is passed for `working-dir`, `ssh-port`, `dry-run`, or `verbose`.
- When `remote-host` is `""`, `remote-is` is ignored and the transfer runs locally.

**Trailing slashes on source-path and target-path**

rsync treats a trailing slash on the source path as a meaningful directive — its presence or absence changes *what* gets transferred:

| source-path | Effect |
|-------------|--------|
| `/data/photos` | Transfers the `photos` directory itself into the target, resulting in `<target>/photos/…` |
| `/data/photos/` | Transfers the *contents* of `photos` directly into the target, resulting in `<target>/file1`, `<target>/file2`, … |

A trailing slash on `target-path` has no effect — rsync always writes into the target directory regardless.

In practice, omitting the trailing slash from `source-path` is usually the safer default: it preserves the top-level directory name at the destination and makes the transfer easier to reason about. Add a trailing slash only when you explicitly want to merge the source contents directly into an existing target directory.

Multiple `label source-path target-path` groups can be appended to run several sets in one invocation. All sets run in parallel.

---

### Examples

**Pull from remote source to local target:**
```bash
bash src/rsync-warp.sh \
  remote.example.com source \
  /var/rsync-warp \
  "" "" false \
  photos /remote/photos /mnt/local/photos
```

**Push from local source to remote target — dry run preview:**
```bash
bash src/rsync-warp.sh \
  remote.example.com target \
  /var/rsync-warp \
  "" true false \
  photos /mnt/data/photos /backup/photos
```

**Push from local source to remote target — live run:**
```bash
bash src/rsync-warp.sh \
  remote.example.com target \
  /var/rsync-warp \
  "" "" false \
  photos /mnt/data/photos /backup/photos
```

**Local to local — copy between two local paths:**
```bash
bash src/rsync-warp.sh \
  "" "" \
  /var/rsync-warp \
  "" "" false \
  photos /mnt/data/photos /mnt/backup/photos
```

**Non-standard SSH port:**
```bash
bash src/rsync-warp.sh \
  remote.example.com target \
  /var/rsync-warp \
  2222 "" false \
  photos /mnt/data/photos /backup/photos
```

**Verbose mode for troubleshooting:**
```bash
bash src/rsync-warp.sh \
  remote.example.com target \
  /var/rsync-warp \
  "" "" true \
  photos /mnt/data/photos /backup/photos
```

**Multiple sets in parallel — photos, documents, and videos synced simultaneously:**
```bash
bash src/rsync-warp.sh \
  remote.example.com target \
  /var/rsync-warp \
  "" "" false \
  photos    /mnt/data/photos    /backup/photos \
  documents /mnt/data/documents /backup/documents \
  videos    /mnt/data/videos    /backup/videos
```

**Using current directory as working directory:**
```bash
bash src/rsync-warp.sh remote.example.com target "" "" "" false mydata /data /remote/data
```

**Check whether rsync-warp is currently running:**
```bash
bash src/rsync-warp.sh --status
```

---

## How It Works

### Parallel Execution

Each `label source-path target-path` group is launched as a background process. All sets run concurrently — a slow or large set does not block others. The script waits for all sets to complete and exits with a non-zero code if any set failed.

To prevent simultaneous SSH handshakes from exceeding the remote sshd `MaxStartups` limit (which causes immediate exit-255 failures), each set delays its startup by `N × stagger_secs` seconds, where N is the set's zero-based position in the argument list and `stagger_secs` defaults to 8. The first set starts immediately; subsequent sets start 8 s, 16 s, 24 s… after it. Override with the `RSYNC_WARP_STAGGER` environment variable.

### Live Progress (FILES column)

The status display shows a `FILES` column with an `X/Y` file-count progress indicator:

- **Local source** — rsync-warp runs `find` on the source tree before rsync starts to get a fixed total. The denominator is stable from the very first progress update.
- **Remote source** — a pre-count would require an extra SSH channel concurrently with rsync, which disrupts in-flight transfers on some SSH implementations. Instead, rsync-warp locks the denominator from rsync's own `to-chk=N/M` counter the first time it appears (once the scan phase finishes, `M` is stable). During the preceding scan phase the denominator grows as rsync discovers files, then snaps to the locked value once transfers begin.

In both cases the numerator is cached between rsync progress updates so the column stays stable during multi-gigabyte file transfers (rsync only emits the file counter on the final progress line of each file).

### Retry and Backoff

rsync-warp automatically retries on transient network errors (rsync exit codes 10, 12, 30, 32, 35, 255). The retry delay starts at 5 seconds and doubles after each failure, capped at 300 seconds (5 minutes). After 10 consecutive failures the set is abandoned.

| Attempt | Delay before retry |
|---------|--------------------|
| 1 | 5 s |
| 2 | 10 s |
| 3 | 20 s |
| 4 | 40 s |
| 5 | 80 s |
| 6 | 160 s |
| 7–10 | 300 s (capped) |

Non-transient errors (e.g. permission denied, bad source path) cause immediate failure without retry.

### SSH ControlMaster

rsync-warp uses SSH ControlMaster to multiplex all rsync connections — including retries — over a single persistent SSH session. This eliminates repeated TCP handshakes and SSH key exchanges, which is especially beneficial on high-latency links or when retries are frequent.

The control socket is created at `/tmp/rsync-warp-<user>@<host>:<port>` (one socket per user/host/port tuple, shared across all sets targeting the same host) and persists for 60 seconds after the last connection closes. rsync establishes the socket on its first connection attempt; the stagger delay ensures no two sets race to create it simultaneously.

### Compression

In-transit compression (`-z`) is enabled for all transfers. File types that are already compressed (images, video, audio, archives, etc.) are excluded from compression via `--skip-compress`, preventing wasted CPU cycles. The list of skipped extensions is loaded from `skip-compress.txt` in the working directory.

### Partial Files

Interrupted transfers (due to network errors or Ctrl+C) store partially received data in a `.rsync-partial/` subdirectory inside each destination path, rather than leaving a partially-written file in place. On Ctrl+C, these directories are automatically removed. On network-error retries, rsync finds and reuses them to avoid retransferring data already received.

### Logging

Each transfer set writes a single log file for the entire session (including all retry attempts) to:
```
<working-dir>/rsynclogs/<label>-YYYY-MM-DD_HH-MM-SS.txt
```

Each log includes per-file transfer details (`--info=progress2`), a transfer summary with byte counts and rates (`--stats`), and success/failure markers between attempts.

Log files older than 30 days are automatically deleted each time rsync-warp starts.

### Run Control Files

rsync-warp uses files in `<working-dir>/loop/` to control execution:

| File | Purpose |
|------|---------|
| `<label>-PROCEED` | Created at startup for each set. Checked before every retry attempt. Removing it cancels that set after the current transfer completes. Deleted automatically on success or permanent failure. |
| `STOPALL` | If this file exists (or is created), all sets abort after their current transfer completes. |

---

## Controlling a Running Session

### Check Status

```bash
bash src/rsync-warp.sh --status
```

Prints the PID and process state if rsync-warp is running, or exits with code 1 if it is not. If multiple instances are running (e.g. for different working directories), the PID of one of them is shown — use `pgrep -a -f rsync-warp.sh` to list all.

### Stop All Sets

**From the terminal running rsync-warp:** press `Ctrl+C`.

**From another terminal:**
```bash
pkill -SIGINT -f '[r]sync-warp.sh'
```

**Convenience alias** (add to your shell profile):
```bash
alias rsync-warp-stop='pkill -SIGINT -f "[r]sync-warp.sh"'
```

**Via the STOPALL file:**
```bash
touch /var/rsync-warp/loop/STOPALL
```

Active rsync transfers are terminated immediately. Any partially transferred files are cleaned up from the destination automatically. The loop control directory is also removed.

### Cancel a Single Set

Remove the set's PROCEED file while the script is running:
```bash
rm /var/rsync-warp/loop/photos-PROCEED
```

The `photos` set will stop after its current transfer attempt completes. Other sets continue unaffected.

### Resume a Cancelled Set

If a set was cancelled before completion, recreate its PROCEED file and re-run the script with the same arguments:
```bash
touch /var/rsync-warp/loop/photos-PROCEED
bash src/rsync-warp.sh remote.example.com target /var/rsync-warp "" "" false \
  photos /mnt/data/photos /backup/photos
```

rsync will pick up where it left off thanks to `--partial-dir` and `--whole-file`.

---

## Customization

All tunable values are near the top of `run_set` and at the `rsync_base`/`ssh_opts` lines in `src/rsync-warp.sh`.

| Setting | Location | Default | Notes |
|---------|----------|---------|-------|
| Local rsync binary path | `RSYNC_LOCAL_PATH` env var | `rsync` | Set to `/usr/bin/rsync` when the local machine's PATH does not include rsync (e.g. running on a Synology NAS) |
| Remote rsync binary path | `RSYNC_REMOTE_PATH` env var | _(empty — use remote PATH)_ | Set to `/usr/bin/rsync` when the remote's SSH PATH does not include rsync (e.g. Synology NAS) |
| SSH port | `ssh-port` argument | `22` | Pass as the 4th positional argument; pass `""` for default |
| Verbose/diagnostic mode | `verbose` argument | `false` | Pass as the 6th positional argument; pass `true` to enable pre-flight checks and increased rsync logging |
| Dry run | `dry-run` argument | `false` | Pass as the 5th positional argument; pass `true` to simulate without writing files |
| Max retries | `max_retries` | `10` | Number of retry attempts per set |
| Initial retry delay | `base_delay` | `5` seconds | Doubles after each failure, capped at 300 s |
| Transfer timeout | `rsync_base` | `120` seconds | rsync `--timeout` idle-data value — triggers a retry if no bytes are received for this long |
| Modify window | `rsync_base` | `1` second | Timestamp tolerance (`--modify-window`) |
| Startup stagger | `RSYNC_WARP_STAGGER` env var | `8` seconds | Seconds between each set's SSH startup. Set 0 starts immediately; set N waits `N × stagger_secs`. Set to `0` to disable. |

---

## Troubleshooting

### rsync Exit Code Reference

| Exit code | Type | Meaning |
|-----------|------|---------|
| 10 | Transient | Socket I/O error |
| 12 | Transient | Error in rsync protocol data stream (network interruption mid-transfer) |
| 30 | Transient | Timeout in data send/receive |
| 32 | Transient | Remote shell failed |
| 35 | Transient | Timeout waiting for daemon connection |
| 255 | Transient | Unexplained error (SSH exit code propagated) |
| 1 | Permanent | Syntax or usage error — check script arguments |
| 2 | Permanent | Protocol incompatibility — check rsync versions on both ends |
| 3 | Permanent | Source or destination path error — verify paths exist and are accessible |
| 4 | Permanent | Requested action not supported by remote rsync |
| 5 | Permanent | Error starting client-server protocol — check SSH and rsync daemon config |
| 6 | Permanent | rsync daemon could not write to log file on remote |
| 11 | Permanent | File I/O error — check disk space and file permissions on remote |
| 13 | Permanent | Program diagnostics error |
| 14 | Permanent | IPC error |
| 20 | Permanent | Received SIGINT or SIGUSR1 — transfer was interrupted |
| 22 | Permanent | Out of memory — insufficient RAM to complete transfer |
| 23 | Permanent | Partial transfer — some files could not be transferred (check permissions or disk space) |
| 24 | Permanent | Partial transfer — some source files vanished during transfer |
| 25 | Permanent | Transfer halted — `--max-delete` limit reached |

Transient errors are retried automatically with exponential backoff. Permanent errors are logged with a descriptive message and the set is abandoned immediately.

---

**rsync fails with exit code 12 against a Synology NAS (or similar appliance)**
The SSH session may not include `/usr/bin` in its PATH, causing rsync to fail when starting the remote protocol handshake. Use `RSYNC_REMOTE_PATH` when the remote is a Synology, or `RSYNC_LOCAL_PATH` when the local machine is a Synology:
```bash
# Remote is Synology
export RSYNC_REMOTE_PATH=/usr/bin/rsync
bash src/rsync-warp.sh nas.example.com target /var/rsync-warp "" "" false mydata /data /backup

# Local machine is Synology
export RSYNC_LOCAL_PATH=/usr/bin/rsync
bash src/rsync-warp.sh remote.example.com target /var/rsync-warp "" "" false mydata /data /backup
```
Or inline for a single run:
```bash
RSYNC_REMOTE_PATH=/usr/bin/rsync bash src/rsync-warp.sh ...
RSYNC_LOCAL_PATH=/usr/bin/rsync bash src/rsync-warp.sh ...
```
To verify the correct path on either side, run:
```bash
# Remote
ssh -p 22 user@nas.example.com "which rsync || command -v rsync"
# Local
which rsync || command -v rsync
```

**rsync fails immediately with exit code 255**
SSH connection refused or key not accepted. Verify with:
```bash
ssh -p 22 user@remote.example.com echo ok
```
Replace `user@remote.example.com` with your remote-host as appropriate.

When running multiple sets simultaneously, all sets connecting at once can exceed the remote sshd `MaxStartups` limit (default `10:30:100`), causing some connections to be refused before any data is exchanged. rsync-warp staggers startup by 8 seconds per set to spread handshakes. If failures persist, increase the stagger:
```bash
RSYNC_WARP_STAGGER=15 bash src/rsync-warp.sh …
```
Or raise `MaxStartups` in `/etc/ssh/sshd_config` on the remote host.

**Transfer stalls and never completes**
The `ServerAliveInterval=30` and `ServerAliveCountMax=5` SSH options will detect a dead connection after ~150 seconds and trigger a retry automatically.

**A set is stuck in a retry loop**
Check the log for the repeated error:
```bash
tail -f /var/rsync-warp/rsynclogs/<label>-*.txt
```
If the source path or remote path is wrong, cancel the set and correct the arguments.

**STOPALL file was left behind from a previous run**
```bash
rm /var/rsync-warp/loop/STOPALL
```
Sets will refuse to start while this file exists.

**Disk full on remote**
rsync exits with code 11. This is treated as a permanent (non-retryable) failure. Free space on the remote and re-run.

**Log directory filling up**
Log files older than 30 days are pruned automatically on each startup. To prune manually:
```bash
find /var/rsync-warp/rsynclogs -name "*.txt" -mtime +30 -delete
```
