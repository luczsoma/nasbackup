# nasbackup

A zsh-based tool that backs up local directories to a remote location via rsync over SSH, with optional cron or launchd scheduling.

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

| Subcommand         | Description                                                                      |
| ------------------ | -------------------------------------------------------------------------------- |
| `backup` (default) | Run all configured jobs sequentially in the order they are defined in the config |
| `logs`             | Print the path of the local log directory (e.g. for `cd $(nasbackup logs)`)      |
| `status`           | Show whether a backup is running, last run, last success, and scheduling status  |
| `enable`           | Install and activate the schedule (launchd on macOS, cron on other platforms)    |
| `disable`          | Remove the installed schedule entirely                                           |
| `help`             | Print usage                                                                      |

## Backup runs and jobs

A `backup` run executes all configured jobs sequentially in the order they are defined in the config, using rsync with `--recursive --links --perms --times --delete` (customizable, see config). If a job fails, the run stops and remaining jobs are not executed.

Each job rsyncs its source directory’s contents into `__NASBACKUP_REMOTE_ROOT/<job_name>/` on the remote. For example, a job named `documents` rsyncs the contents of its source directory to `<__NASBACKUP_REMOTE_ROOT>/documents/`.

## Configuration

All settings live in `nasbackup.config.zsh` (sourced at runtime). See [nasbackup.config.example.zsh](nasbackup.config.example.zsh) for the full reference.

## Filtering

You can control what gets included or excluded from backups with rsync’s versatile filtering. See [rsync-filters/README.md](rsync-filters/README.md) for filtering details.

## Exit codes

| Code              | Meaning                                                                                                                          |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `0`               | Success                                                                                                                          |
| `1–7`             | Backup job failed: bitmask of bit0 (LSB) = rsync failed, bit1 = rsync produced no log file, bit2 (MSB) = rsync log upload failed |
| `8`               | Generic error                                                                                                                    |
| `9`               | Config error (missing or invalid config)                                                                                         |
| `10`              | Lock acquisition failed (another backup already running)                                                                         |
| `11`              | Local environment setup failed                                                                                                   |
| `12`              | Remote unreachable or remote environment setup failed                                                                            |
| `13`              | Scheduling error (`enable` / `disable` failed)                                                                                   |
| `129/130/131/143` | Killed by HUP/INT/QUIT/TERM                                                                                                      |

## Logs

Each job writes a structured per-file rsync log (`--log-file`) to `__NASBACKUP_LOCAL_LOG_DIRECTORY`:

```
nasbackup-<date>-<run_id>-<job_name>.log
```

After a job completes, its log file is uploaded to `__NASBACKUP_REMOTE_LOG_DIRECTORY` on the remote.

At the start of each run, local logs older than `__NASBACKUP_LOCAL_LOG_RETENTION_DAYS` days are deleted (if set), and remote logs older than `__NASBACKUP_REMOTE_LOG_RETENTION_DAYS` days are deleted (if set).

## Monitoring

Set `__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY` and `__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG` in the config to enable monitoring via Healthchecks.io. The script sends:

- a **start** ping at the start of a backup run
- a **log** ping at the start of each job
- a **finish** ping (with exit code) at the end of a backup run

## Scheduling

Set `__NASBACKUP_SCHEDULE` in the config, then run `nasbackup enable` to install and activate automatic backups. On macOS a per-user launchd agent is installed (`~/Library/LaunchAgents/io.github.luczsoma.nasbackup.plist`); on other platforms a user crontab entry is added. Scheduling can be disabled with `nasbackup disable`, which entirely removes the launchd agent or user crontab entry. The `enable` subcommand is idempotent; re-running it replaces any previously installed schedule with the current config.

`__NASBACKUP_SCHEDULE` is a 5-field cron-style string:

```
minute hour day month weekday
```

Each field must be a single integer in valid range or `*` (any). Lists, ranges, and steps (`*/15`, `1-5`, `1,3,5`) are not supported.

| Field   | Range | Notes            |
| ------- | ----- | ---------------- |
| minute  | 0–59  |                  |
| hour    | 0–23  |                  |
| day     | 1–31  |                  |
| month   | 1–12  |                  |
| weekday | 0–7   | 0 and 7 = Sunday |

**Examples:**

```zsh
__NASBACKUP_SCHEDULE="0 3 * * *"   # every day at 03:00
__NASBACKUP_SCHEDULE="0 2 * * 0"   # every Sunday at 02:00
__NASBACKUP_SCHEDULE="0 1 1 * *"   # first day of every month at 01:00
```

**DoM + DoW caveat:** if both day-of-month and day-of-week are set (not `*`), cron ORs them while launchd ANDs them. For consistent behavior across platforms, set at most one of the two.

### Scheduled-context caveats

When a backup runs via launchd or cron, the process has a minimal environment (no interactive shell, restricted PATH, no SSH agent loaded). If your SSH key has a passphrase, authentication will likely fail. Use one of:

- A passphraseless SSH key dedicated to backup.
- A key stored in the macOS keychain (`ssh-add --apple-use-keychain`). On macOS, launchd agents run inside the user GUI session, so Keychain access is available.

To inspect the launchd agent state or see its last exit code:

```zsh
launchctl print gui/$(id -u)/io.github.luczsoma.nasbackup
```
