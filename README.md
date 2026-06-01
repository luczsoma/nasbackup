# nasbackup

Backs up local directories to a remote location via rsync over SSH.

## Prerequisites

- `rsync` installed on the remote and accessible at a known path (default: `/bin/rsync`)
- An SSH host named configured in `~/.ssh/config` that you can set `__NASBACKUP_REMOTE_HOST` to
- A writable backup directory on the remote (default: `/nasbackup`)

## Setup

**1. Copy the example config and fill in your values:**

```zsh
cp nasbackup.config.zsh.example nasbackup.config.zsh
```

The config file is gitignored. See [nasbackup.config.zsh.example](nasbackup.config.zsh.example) for all available settings with descriptions.

**2. Edit the rsync filter:**

[rsync-filter/default.rsync-filter](rsync-filter/default.rsync-filter) is applied to all backup jobs. You can also create per-job filter files named `<job_name>.rsync-filter` in the same directory.

**3. Make the script executable and run it:**

```zsh
chmod +x nasbackup.zsh
./nasbackup.zsh backup
```

Or symlink / add to `$PATH` for shorter invocation:

```zsh
nasbackup backup
```

## Usage

```
nasbackup [backup|logs|status|help]
```

| Subcommand         | Description                                                  |
| ------------------ | ------------------------------------------------------------ |
| `backup` (default) | Run all configured backup jobs                               |
| `logs`             | Open the local log directory in Finder                       |
| `status`           | Show whether a backup is running, last run, and last success |
| `help`             | Print usage                                                  |

## Configuration

All settings live in `nasbackup.config.zsh` (sourced at runtime). See [nasbackup.config.zshexample.](nasbackup.config.zshexample.) for the full reference.

All jobs share `rsync-filter/default.rsync-filter`. For per-job filtering, create `rsync-filter/<job_name>.rsync-filter`.

## Healthchecks.io

Set `__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY` and `__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG` in the config to enable monitoring. The script sends:

- a **start** ping before the first job
- a **log** ping at the start of each job
- a **finish** ping (with exit code) after all jobs complete — even if the NAS is unreachable or a job fails

## Exit codes

| Code              | Meaning                                                                                                    |
| ----------------- | ---------------------------------------------------------------------------------------------------------- |
| `0`               | Success                                                                                                    |
| `1`               | Generic error                                                                                              |
| `2–31`            | Per-job bitmask (bit1 = rsync failed, bit2 = no log file, bit3 = no output file, bit4 = log upload failed) |
| `99`              | Config failed                                                                                              |
| `100`             | Local environment setup failed                                                                             |
| `101`             | NAS unreachable or remote environment setup failed                                                         |
| `102`             | Lock acquisition failed (another backup already running)                                                   |
| `129/130/131/143` | Killed by HUP/INT/QUIT/TERM                                                                                |

## Logs

Each job produces two local log files under `__NASBACKUP_LOCAL_LOG_DIRECTORY`:

- `nasbackup-<date>-<run_id>-<job_name>-rsynclogfile.log` — structured per-file rsync log (`--log-file`)
- `nasbackup-<date>-<run_id>-<job_name>-rsyncoutput.log` — rsync stdout/stderr

Both are merged into a combined log and uploaded to `__NASBACKUP_REMOTE_LOG_DIRECTORY` on the NAS. On job failure, the combined log is also copied to `~/Desktop/NASBACKUP_ERROR_*.log`.

Local and remote logs older than `__NASBACKUP_LOCAL_LOG_RETENTION_DAYS` / `__NASBACKUP_REMOTE_LOG_RETENTION_DAYS` days are deleted at the start of each run.
