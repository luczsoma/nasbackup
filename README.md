# nasbackup

A zsh-based tool that backs up local directories to a remote location via rsync over SSH, with optional launchd or cron scheduling.

**The nasbackup tool maintains a live mirror, not a versioned backup.** Each run brings the remote into sync with the current state of the source. Files deleted or overwritten on the source are deleted or overwritten on the remote on the next run; no previous versions are kept. If you need point-in-time snapshots or file history, consider layering your remote’s snapshot feature (e.g. Synology Btrfs snapshots) on top, or use a tool like [restic](https://restic.net) or [BorgBackup](https://www.borgbackup.org) instead.

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

A `backup` run executes all configured jobs sequentially in the order they are defined in the config, using rsync with `--recursive --links --perms --times --delete` (customizable, see config). Each job rsyncs the contents of `<source_directory>` into `__NASBACKUP_REMOTE_ROOT/<job_name>` on the remote. If a job fails, the run stops and remaining jobs are not executed.

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
| `13`              | Scheduling error (`enable` or `disable` failed)                                                                                  |
| `129/130/131/143` | Killed by HUP/INT/QUIT/TERM                                                                                                      |

## Logs

### Per-job rsync logs

Each job writes a structured per-file rsync log (`--log-file`) to `__NASBACKUP_LOCAL_LOG_DIRECTORY`:

```
nasbackup--<date>--<run_id>--<job_name>.log
```

For example:

```
nasbackup--2026-06-21T00-00-00+0200--5fbd043d-3ba9-4e6e-9190-876892051388--documents.log
```

After a job completes, its log file is uploaded to `__NASBACKUP_REMOTE_LOG_DIRECTORY` on the remote.

At the start of each run, local log files are cleaned up according to `__NASBACKUP_LOCAL_LOG_RETENTION_DAYS` and remote log files according to `__NASBACKUP_REMOTE_LOG_RETENTION_DAYS`: `0` deletes all logs; a positive value deletes logs older than that many days; empty means keep logs indefinitely (no cleanup).

Note: Remote log cleanup uses `find -delete`, which is a GNU findutils extension. On BusyBox-based systems such as Synology DSM, support depends on compile-time configuration (`CONFIG_FEATURE_FIND_DELETE`). If the remote `find` does not support `-delete`, cleanup is skipped and a warning is logged; the backup itself is unaffected.

### Diagnostic output

All diagnostic output (status messages, warnings, errors) goes to stderr. Nothing is written to stdout during a `backup` run.

When run interactively, stderr goes to the terminal as usual.

When run via launchd or cron, stderr is redirected to `launchd.stderr.log` or `cron.stderr.log` inside `__NASBACKUP_LOCAL_LOG_DIRECTORY`, and each line is prefixed with a timestamp (e.g., `2026-06-21T00-00-00+0200`).

At the start of each run (interactive or not) `launchd.stderr.log` and `cron.stderr.log` are cleaned up according to `__NASBACKUP_LOCAL_LOG_RETENTION_DAYS` if they exist: `0` truncates them entirely; a positive value drops lines older than that many days; empty means they are never cleaned up.

## Monitoring

Schedule-based external monitoring is highly recommended so you get alerted not only about potential backup errors, but also when backups stop running altogether (for example if your computer is off during every scheduled window, if the schedule was accidentally disabled, or if a persistent environment error prevents any run from starting).

External monitoring in nasbackup is supported via [Healthchecks.io](https://healthchecks.io). Configure a scheduled check there, then set both `__NASBACKUP_HEALTHCHECKS_PING_KEY` and `__NASBACKUP_HEALTHCHECKS_PING_SLUG` in the config to send:

- a **start** ping once all pre-flight checks pass and the backup jobs are about to begin,
- a **log** ping at the start of each individual job,
- a **finish** ping (with exit code) at the end of the run.

Only job outcomes are reported to Healthchecks.io; pre-flight failures (config errors, lock contention, environment setup) are not. The finish ping exit code is always in the `0–8` range (`0` for success, the job bitmask for `1–7`, or `8` for a generic job-level error), or a signal code (`129/130/131/143`) if the backup was killed. To diagnose a run, check stderr and the logs, and `nasbackup status`.

## Scheduling

Set `__NASBACKUP_SCHEDULE` in the config, then run `nasbackup enable` to activate automatic backups. On macOS, a per-user launchd agent is installed (`~/Library/LaunchAgents/io.github.luczsoma.nasbackup.plist`), on other platforms a user crontab entry is added. The `enable` subcommand is idempotent: re-running it replaces any previously installed schedule with the current one in the config. Run `nasbackup disable` to disable scheduling (it removes the installed schedule entirely).

The format of `__NASBACKUP_SCHEDULE` is `launchd=<launchd_expression>` or `cron=<cron_expression>`, and must match the platform:

- **macOS:** use `launchd=...` (`cron=...` is a config error on macOS)
- **other platforms:** use `cron=...` (`launchd=...` is a config error on non-macOS)

### Scheduling expressions

#### `launchd_expression`

One or more entries separated by `;`, each encoding a launchd `StartCalendarInterval` dictionary as 5 comma-separated fields:

```
Minute,Hour,Day,Weekday,Month
```

| Field     | Range | Notes            |
| --------- | ----- | ---------------- |
| `Minute`  | 0–59  |                  |
| `Hour`    | 0–23  |                  |
| `Day`     | 1–31  |                  |
| `Weekday` | 0–7   | 0 and 7 = Sunday |
| `Month`   | 1–12  |                  |

A blank field is a wildcard meaning _every_ (the key is omitted from the `StartCalendarInterval` dictionary). Multiple entries allow schedules that cron would express with a list, interval, or step (e.g. running at :00, :15, :30, :45 every hour).

```zsh
# every day at 03:00 (Minute=0, Hour=3)
__NASBACKUP_SCHEDULE="launchd=0,3,,,"
# every Sunday at 02:00 (Minute=0, Hour=2, Weekday=0)
__NASBACKUP_SCHEDULE="launchd=0,2,,0,"
# first day of every month at 01:00 (Minute=0, Hour=1, Day=1)
__NASBACKUP_SCHEDULE="launchd=0,1,1,,"
# every minute of 08:xx every day (Minute=wildcard, Hour=8)
__NASBACKUP_SCHEDULE="launchd=,8,,,"
# every day at 03:00 and 15:00 (two entries)
__NASBACKUP_SCHEDULE="launchd=0,3,,,;0,15,,,"
# every 15 minutes (four entries)
__NASBACKUP_SCHEDULE="launchd=0,,,,;15,,,,;30,,,,;45,,,,"
# every 2 hours between 08:00 and 18:00 (six entries)
__NASBACKUP_SCHEDULE="launchd=0,8,,,;0,10,,,;0,12,,,;0,14,,,;0,16,,,;0,18,,,"
```

#### `cron_expression`

A standard cron expression written verbatim to the user crontab without validation by nasbackup. Supported syntax depends on the platform’s cron implementation.

```zsh
# every day at 03:00
__NASBACKUP_SCHEDULE="cron=0 3 * * *"
# every Sunday at 02:00
__NASBACKUP_SCHEDULE="cron=0 2 * * 0"
# first day of every month at 01:00
__NASBACKUP_SCHEDULE="cron=0 1 1 * *"
# every minute of 08:xx every day
__NASBACKUP_SCHEDULE="cron=* 8 * * *"
# every day at 03:00 and 15:00
__NASBACKUP_SCHEDULE="cron=0 3,15 * * *"
# every 15 minutes
__NASBACKUP_SCHEDULE="cron=*/15 * * * *"
# every 2 hours between 08:00 and 18:00
__NASBACKUP_SCHEDULE="cron=0 8-18/2 * * *"
```

### Scheduled-context caveats

When a backup runs via launchd or cron, the process has a minimal environment (no interactive shell, restricted PATH, no SSH agent loaded). If your SSH key has a passphrase, authentication will likely fail. Use one of:

- A passphraseless SSH key dedicated to backup.
- A key stored in the macOS keychain (`ssh-add --apple-use-keychain`). On macOS, the nasbackup launchd agent runs inside the user GUI session, so Keychain access is available.

To inspect the launchd agent state or see its last exit code:

```zsh
launchctl print gui/$(id -u)/io.github.luczsoma.nasbackup
```
