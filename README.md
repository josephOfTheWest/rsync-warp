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
- **rsync** installed at `/usr/local/bin/rsync` (adjust path in script if needed)
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
bash src/rsync-warp.sh <remote-host> <working-dir> <dry-run> <ssh-port> <label> <source> <target> [<label> <source> <target> ...]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `remote-host` | Hostname or IP of the remote SSH endpoint |
| `working-dir` | Local directory for logs and run-control files. Pass an empty string `""` to use the current directory |
| `dry-run` | `true` to simulate the transfer without writing any files; `false` for a live run |
| `ssh-port` | SSH port on the remote host. Defaults to `22` if not specified |
| `label` | Unique name for this transfer set. Used for log file names and run-control files |
| `source` | Local path to sync from |
| `target` | Remote path on `remote-host` to sync to |

Multiple `label source target` groups can be appended to run several sets in one invocation. All sets run in parallel.

---

### Examples

**Single set, dry run — preview what would be transferred:**
```bash
bash src/rsync-warp.sh \
  remote.example.com \
  /var/rsync-warp \
  true \
  22 \
  photos /mnt/data/photos /backup/photos
```

**Single set, live run on standard SSH port:**
```bash
bash src/rsync-warp.sh \
  remote.example.com \
  /var/rsync-warp \
  false \
  22 \
  photos /mnt/data/photos /backup/photos
```

**Single set, live run on a non-standard SSH port:**
```bash
bash src/rsync-warp.sh \
  remote.example.com \
  /var/rsync-warp \
  false \
  2222 \
  photos /mnt/data/photos /backup/photos
```

**Multiple sets in parallel — photos, documents, and videos synced simultaneously:**
```bash
bash src/rsync-warp.sh \
  remote.example.com \
  /var/rsync-warp \
  false \
  22 \
  photos    /mnt/data/photos    /backup/photos \
  documents /mnt/data/documents /backup/documents \
  videos    /mnt/data/videos    /backup/videos
```

**Using current directory as working directory:**
```bash
bash src/rsync-warp.sh remote.example.com "" false 22 mydata /data /remote/data
```

**Check whether rsync-warp is currently running:**
```bash
bash src/rsync-warp.sh --status
```

---

## How It Works

### Parallel Execution

Each `label source target` group is launched as a background process. All sets run concurrently — a slow or large set does not block others. The script waits for all sets to complete and exits with a non-zero code if any set failed.

### Retry and Backoff

rsync-warp automatically retries on transient network errors (rsync exit codes 10, 30, 32, 255). The retry delay starts at 5 seconds and doubles after each failure, capped at 300 seconds (5 minutes). After 10 consecutive failures the set is abandoned.

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

The control socket is created at `/tmp/rsync-warp-<user>@<host>:<port>` and persists for 60 seconds after the last connection closes.

### Compression

In-transit compression (`-z`) is enabled for all transfers. File types that are already compressed (images, video, audio, archives, etc.) are excluded from compression via `--skip-compress`, preventing wasted CPU cycles. The list of skipped extensions is loaded from `skip-compress.txt` in the working directory.

### Logging

Each transfer set writes a single log file for the entire session (including all retry attempts) to:
```
<working-dir>/rsynclogs/<label>-YYYY-MM-DD_HH-MM-SS.txt
```

Each log includes per-file transfer details (`--info=progress2`), a transfer summary with byte counts and rates (`--stats`), and success/failure markers between attempts.

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

Prints the PID and process state if rsync-warp is running, or exits with code 1 if it is not.

### Stop All Sets

**From the terminal running rsync-warp:** press `Ctrl+C`.

**From another terminal:**
```bash
kill -SIGINT "$(pgrep -f '[r]sync-warp.sh')"
```

**Convenience alias** (add to your shell profile):
```bash
alias rsync-warp-stop='kill -SIGINT "$(pgrep -f "[r]sync-warp.sh")"'
```

**Via the STOPALL file:**
```bash
touch /var/rsync-warp/loop/STOPALL
```

In all cases, the currently active rsync transfer runs to completion before the script exits. Partial files are retained on the remote (via `--partial`) and will resume on the next run.

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
bash src/rsync-warp.sh remote.example.com /var/rsync-warp false 22 \
  photos /mnt/data/photos /backup/photos
```

rsync will pick up where it left off thanks to `--partial` and `--whole-file`.

---

## Customization

All tunable values are near the top of `run_set` and at the `rsync_base`/`ssh_opts` lines in `src/rsync-warp.sh`.

| Setting | Location | Default | Notes |
|---------|----------|---------|-------|
| rsync binary path | `rsync_base` line | `/usr/local/bin/rsync` | Change if rsync is elsewhere |
| SSH port | `ssh-port` argument | `22` | Pass as the 4th positional argument |
| SSH cipher | `ssh_opts` line | `aes128-gcm@openssh.com` | Optimized for AES-NI hardware |
| Max retries | `max_retries` | `10` | Number of retry attempts per set |
| Initial retry delay | `base_delay` | `5` seconds | Doubles after each failure, capped at 300 s |
| Transfer timeout | `rsync_base` | `20` seconds | rsync `--timeout` value |
| Modify window | `rsync_base` | `1` second | Timestamp tolerance (`--modify-window`) |

---

## Troubleshooting

**rsync fails immediately with exit code 255**
SSH connection refused or key not accepted. Verify with:
```bash
ssh -p 22 user@remote.example.com echo ok
```

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
Each invocation creates one log file per set. Prune old logs with:
```bash
find /var/rsync-warp/rsynclogs -name "*.txt" -mtime +30 -delete
```
