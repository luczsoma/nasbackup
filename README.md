# nasbackup

A macOS tool that backs up local directories to a remote location via rsync over SSH, with optional launchd scheduling.

## Prerequisites

- `rsync` installed on both ends, accessible at a known path on the remote (default: `/bin/rsync`)
- An SSH host configured in `~/.ssh/config` that you can set `__NASBACKUP_REMOTE_HOST` to
- A writable backup directory on the remote (default: `/nasbackup`)

## Setup

**1. Copy the example config and fill in your values:**

```zsh
cp nasbackup.config.example.zsh nasbackup.config.zsh
```

The config file is gitignored. See [nasbackup.config.example.zsh](nasbackup.config.example.zsh) for all available settings with descriptions.

**2. Create rsync filters:**

If `rsync-filters/default.rsync-filter` exists, it is applied to all backup jobs as the base filter. If a file named `rsync-filters/<job_name>.rsync-filter` exists, it is merged on top of the default filter and applied to that job only.

**3. Make the script executable and run it:**

```zsh
chmod +x nasbackup.zsh
./nasbackup.zsh backup
```

Or alias / symlink / add to `$PATH` for shorter invocation:

```zsh
nasbackup backup
```

## Usage

```
nasbackup [backup|logs|status|enable|disable|help]
```

| Subcommand         | Description                                                                                              |
| ------------------ | -------------------------------------------------------------------------------------------------------- |
| `backup` (default) | Run all configured backup jobs                                                                           |
| `logs`             | Open the local log directory in Finder                                                                   |
| `status`           | Show whether a backup is running, last run, last success, and launchd agent status (not yet implemented) |
| `enable`           | Enable the launchd agent (not yet implemented)                                                           |
| `disable`          | Disable the launchd agent (not yet implemented)                                                          |
| `help`             | Print usage                                                                                              |

## Configuration

All settings live in `nasbackup.config.zsh` (sourced at runtime). See [nasbackup.config.example.zsh](nasbackup.config.example.zsh) for the full reference.

If `rsync-filters/default.rsync-filter` exists, it is applied to all backup jobs as the base filter. If `rsync-filters/<job_name>.rsync-filter` exists, it is merged on top of the default filter and applied to that job only.

## Healthchecks.io

Set `__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY` and `__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG` in the config to enable monitoring. The script sends:

- a **start** ping before the first job
- a **log** ping at the start of each job
- a **finish** ping (with exit code) after all jobs complete — even if the remote is unreachable or a job fails

## Exit codes

| Code              | Meaning                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------- |
| `0`               | Success                                                                                         |
| `1–7`             | Backup job failed: bitmask of bit0 = rsync failed, bit1 = no log file, bit2 = log upload failed |
| `8`               | Generic error                                                                                   |
| `9`               | Config error (missing or invalid config)                                                        |
| `10`              | Local environment setup failed                                                                  |
| `11`              | Remote unreachable or remote environment setup failed                                           |
| `12`              | Lock acquisition failed (another backup already running)                                        |
| `129/130/131/143` | Killed by HUP/INT/QUIT/TERM                                                                     |

## Logs

Each job writes a structured per-file rsync log (`--log-file`) to `__NASBACKUP_LOCAL_LOG_DIRECTORY`:

```
nasbackup-<date>-<run_id>-<job_name>.log
```

After each job completes, the log file is uploaded to `__NASBACKUP_REMOTE_LOG_DIRECTORY` on the remote.

At the start of each run, local logs older than `__NASBACKUP_LOCAL_LOG_RETENTION_DAYS` days are deleted (if set), and remote logs older than `__NASBACKUP_REMOTE_LOG_RETENTION_DAYS` days are deleted (if set).
