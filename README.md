# nasbackup

A macOS tool that backs up local directories to a remote location via rsync over SSH, with optional launchd scheduling.

## Prerequisites

- `rsync` installed on both ends, accessible at a known path on the remote
- An SSH host configured in `~/.ssh/config` that you can set `__NASBACKUP_REMOTE_HOST` to
- A writable backup directory on the remote

## Setup

**1. Copy the example config and fill in your values:**

```zsh
cp nasbackup.config.example.zsh nasbackup.config.zsh
```

The config file is gitignored. See [nasbackup.config.example.zsh](nasbackup.config.example.zsh) for all available settings with descriptions.

**2. Make the script executable and run it:**

```zsh
chmod u+x nasbackup.zsh
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
| `backup` (default) | Run all configured jobs sequentially in the order they are defined in the config                         |
| `logs`             | Open the local log directory in Finder                                                                   |
| `status`           | Show whether a backup is running, last run, last success, and launchd agent status (not yet implemented) |
| `enable`           | Enable the launchd agent (not yet implemented)                                                           |
| `disable`          | Disable the launchd agent (not yet implemented)                                                          |
| `help`             | Print usage                                                                                              |

## Backup runs and jobs

Each `backup` run executes all configured jobs sequentially in the order they are defined in the config, using rsync with `--recursive --links --perms --times --delete` (customizable, see config). If a job fails, the run stops and remaining jobs are not executed.

## Configuration

All settings live in `nasbackup.config.zsh` (sourced at runtime). See [nasbackup.config.example.zsh](nasbackup.config.example.zsh) for the full reference.

## Filtering

You can control what gets included or excluded from backups with rsync’s versatile filtering. See [rsync-filters/README.md](rsync-filters/README.md) for filtering details.

## Healthchecks.io

Set `__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY` and `__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG` in the config to enable monitoring. The script sends:

- a **start** ping at the start of a backup run
- a **log** ping at the start of each job
- a **finish** ping (with exit code) at the end of a backup run

## Exit codes

| Code              | Meaning                                                                                                                            |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `0`               | Success                                                                                                                            |
| `1–7`             | A backup job failed: bitmask of bit0 (LSB) = rsync failed, bit1 = rsync produced no log file, bit2 (MSB) = rsync log upload failed |
| `8`               | Generic error                                                                                                                      |
| `9`               | Config error (missing or invalid config)                                                                                           |
| `10`              | Lock acquisition failed (another backup already running)                                                                           |
| `11`              | Local environment setup failed                                                                                                     |
| `12`              | Remote unreachable or remote environment setup failed                                                                              |
| `129/130/131/143` | Killed by HUP/INT/QUIT/TERM                                                                                                        |

## Logs

Each job writes a structured per-file rsync log (`--log-file`) to `__NASBACKUP_LOCAL_LOG_DIRECTORY`:

```
nasbackup-<date>-<run_id>-<job_name>.log
```

After a job completes, its log file is uploaded to `__NASBACKUP_REMOTE_LOG_DIRECTORY` on the remote.

At the start of each run, local logs older than `__NASBACKUP_LOCAL_LOG_RETENTION_DAYS` days are deleted (if set), and remote logs older than `__NASBACKUP_REMOTE_LOG_RETENTION_DAYS` days are deleted (if set).
