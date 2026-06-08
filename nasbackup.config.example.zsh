###################
# BACKUP SETTINGS #
###################
# Each backup job is a (job_name, source_directory) pair:
# job_name - identifies the job; used as the target directory name under __NASBACKUP_REMOTE_ROOT and in log file names; must be unique, must only contain letters, digits, hyphens, or underscores; must not be "default"
# source_directory - local directory to back up; trailing slash is optional
__NASBACKUP_JOBS=(
    "documents"     "$HOME/Documents"
    "pictures"      "$HOME/Pictures"
)

##################
# LOCAL SETTINGS #
##################
# The directory in which log files are stored
__NASBACKUP_LOCAL_LOG_DIRECTORY="$HOME/Library/Logs/nasbackup"
# Local log files older than this many days will be deleted on the next run; 0 means delete all logs on each run; empty means keep logs indefinitely
__NASBACKUP_LOCAL_LOG_RETENTION_DAYS=365
# The path of the local rsync binary
__NASBACKUP_LOCAL_RSYNC_PATH="/opt/homebrew/bin/rsync"
# The path of the local curl binary (used for Healthchecks.io pings)
__NASBACKUP_LOCAL_CURL_PATH="curl"

###################
# REMOTE SETTINGS #
###################
# The remote host as it is configured for SSH (usually in ~/.ssh/config)
__NASBACKUP_REMOTE_HOST="nas"
# The root directory on the remote under which each job is backed up to its own <job_name> subdirectory
__NASBACKUP_REMOTE_ROOT="/nasbackup"
# The directory on the remote host into which log files are copied
__NASBACKUP_REMOTE_LOG_DIRECTORY="$__NASBACKUP_REMOTE_ROOT/_logs"
# Remote log files older than this many days will be deleted on the next run; 0 means delete all logs on each run; empty means keep logs indefinitely
__NASBACKUP_REMOTE_LOG_RETENTION_DAYS=365
# The path of rsync on the remote (the value of --rsync-path)
__NASBACKUP_REMOTE_RSYNC_PATH="/bin/rsync"

#######################
# MONITORING SETTINGS #
#######################
# If either one is empty, Healthchecks.io pings will not be sent
# Your Healthchecks.io project’s Ping Key
__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY=""
# Your Healthchecks.io check’s slug
__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG=""

#######################
# SCHEDULING SETTINGS #
#######################
# The schedule on which automatic backups run; required by `nasbackup enable`
# Format: "launchd=<launchd_exp>" or "cron=<cron_exp>"
#
# launchd=<launchd_exp>
#   One or more StartCalendarInterval entries, separated by ";". Only supported on macOS.
#   Each entry has 5 comma-separated fields: Minute,Hour,Day,Weekday,Month
#     Minute: 0–59 | Hour: 0–23 | Day: 1–31 | Weekday: 0–7 (0 and 7 = Sunday) | Month: 1–12
#   A blank field is a wildcard (the key is omitted from StartCalendarInterval).
#   Examples:
#     - every day at 03:00 (Minute=0, Hour=3)
#       "launchd=0,3,,,"
#     - every Sunday at 02:00 (Minute=0, Hour=2, Weekday=0)
#       "launchd=0,2,,0,"
#     - first day of every month at 01:00 (Minute=0, Hour=1, Day=1)
#       "launchd=0,1,1,,"
#     - every minute of 03:xx every day (Hour=3, Minute wildcard)
#       "launchd=,3,,,"
#     - every day at 03:00 and 15:00 (two entries)
#       "launchd=0,3,,,;0,15,,,"
#     - 4 times an hour at :00, :15, :30, :45 (four entries)
#       "launchd=0,,,,;15,,,,;30,,,,;45,,,,"
#     - 12 times a day every 2 hours at :00 of each even hour (twelve entries)
#       "launchd=0,0,,,;0,2,,,;0,4,,,;0,6,,,;0,8,,,;0,10,,,;0,12,,,;0,14,,,;0,16,,,;0,18,,,;0,20,,,;0,22,,,"
#
# cron=<cron_exp>
#   A standard cron expression written verbatim into crontab. Only supported on non-macOS.
#   Examples:
#     - every day at 03:00
#       "cron=0 3 * * *"
#     - every Sunday at 02:00
#       "cron=0 2 * * 0"
#     - first day of every month at 01:00
#       "cron=0 1 1 * *"
#
# Note: run `nasbackup disable` to disable an already-installed schedule; clearing this value alone does not disable scheduling
__NASBACKUP_SCHEDULE=""

#####################
# ADVANCED SETTINGS #
#####################
# Extra rsync arguments appended after all built-in args; use with care as they can override or conflict with built-in args
__NASBACKUP_EXTRA_RSYNC_ARGS=(
    # Example: add --checksum to compare files by checksum (slow!) instead of size+mtime:
    # --checksum
    # Example: add --no-ARG to turn off a built-in arg:
    # --no-delete
)
