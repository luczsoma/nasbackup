###################
# BACKUP SETTINGS #
###################
# Each backup job is a (job_name, source_directory) pair:
#
# job_name     - used in log file names; must be unique and only contain letters, digits, hyphens, or underscores
# source_dir   - local directory to back up; trailing slash is optional
#
# If rsync-filters/default.rsync-filter exists, it is applied to all backup jobs as the base filter.
# If a file named rsync-filters/<job_name>.rsync-filter exists, it is merged on top of the default filter and applied to that job only.
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
# If the last successful backup finished more than this many seconds ago, the status command will display a warning; 0 means always warn; empty means never warn
__NASBACKUP_LAST_SUCCESS_MAX_AGE_SECONDS=3600

###################
# REMOTE SETTINGS #
###################
# The remote host as it is configured for SSH (usually in ~/.ssh/config)
__NASBACKUP_REMOTE_HOST="nas"
# The root directory on the remote into which the backup jobs’ source directories will be backed up
__NASBACKUP_REMOTE_ROOT="/nasbackup"
# The directory on the remote host into which log files are copied
__NASBACKUP_REMOTE_LOG_DIRECTORY="$__NASBACKUP_REMOTE_ROOT/_logs"
# Remote log files older than this many days will be deleted on the next run; 0 means delete all logs on each run; empty means keep logs indefinitely
__NASBACKUP_REMOTE_LOG_RETENTION_DAYS=365
# The path of rsync on the remote (the value of --rsync-path)
__NASBACKUP_REMOTE_RSYNC_PATH="/bin/rsync"

############################
# HEALTHCHECKS.IO SETTINGS #
############################
# If either one is empty, Healthchecks.io pings will not be sent.
# Your Healthchecks.io project’s Ping Key
__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY=""
# Your Healthchecks.io check’s slug
__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG=""
