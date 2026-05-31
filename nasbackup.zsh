#!/usr/bin/env zsh

# Assumes that "nas" is set as an SSH host (usually in ~/.ssh/config),
# and that there is a writable /volume1/nasbackup folder on the NAS.

# TODO:
# launchd (enable/disable/status):
#   run it every 15 minutes (StartCalendarInterval)
#   man launchctl
#   man launchd.plist

NASBACKUP_SCRIPT_DIRECTORY="${${(%):-%x}:A:h}"

NASBACKUP_REMOTE_HOST="nas"
NASBACKUP_REMOTE_ROOT="/volume1/nasbackup"
NASBACKUP_REMOTE_RSYNC_PATH="/bin/rsync"
NASBACKUP_RSYNC_FILTER_FILE="$NASBACKUP_SCRIPT_DIRECTORY/nasbackup.rsync-filter"
NASBACKUP_SECRETS_FILE="$NASBACKUP_SCRIPT_DIRECTORY/nasbackup_secrets.zsh"

NASBACKUP_LOCAL_LOG_DIRECTORY="$HOME/Library/Logs/nasbackup"
NASBACKUP_LAST_RUN_FILE="$NASBACKUP_LOCAL_LOG_DIRECTORY/last-run"
NASBACKUP_LAST_SUCCESS_FILE="$NASBACKUP_LOCAL_LOG_DIRECTORY/last-success"
NASBACKUP_LAST_SUCCESS_MAX_AGE_SECONDS=3600
NASBACKUP_REMOTE_LOG_DIRECTORY="$NASBACKUP_REMOTE_ROOT/_logs"
NASBACKUP_LOCK_DIRECTORY="/tmp/nasbackup.lock"
NASBACKUP_LOG_RETENTION_DAYS=365

__nasbackup_get_process_start_epoch() {
    if (( $# != 1 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_get_process_start_epoch requires 1 argument"
        return 1
    fi

    local -r pid="$1"
    local -r raw="$(LC_ALL=C ps -o lstart= -p "$pid" 2> /dev/null | tr -s ' ' | sed 's/^ //;s/ *$//')"
    if [[ -z "$raw" ]]; then
        return 1
    fi
    date -j -f '%a %b %d %H:%M:%S %Y' "$raw" +%s 2> /dev/null
}

__nasbackup_try_acquire_lock_atomic() {
    # try to acquire lock
    if mkdir "$NASBACKUP_LOCK_DIRECTORY" 2> /dev/null; then
        # write pid and process start time as epoch (for pid reuse detection)
        local -r start_epoch="$(__nasbackup_get_process_start_epoch $$)"
        if [[ -n "$start_epoch" ]] \
            && print "$$" > "$NASBACKUP_LOCK_DIRECTORY/pid" \
            && print "$start_epoch" > "$NASBACKUP_LOCK_DIRECTORY/started_at"; then
            return 0
        fi

        # could not write pid or start time => delete lock
        __nasbackup_delete_lock_unchecked

        # could not acquire lock (could not write pid or start time)
        return 1
    fi

    # could not acquire lock (already locked)
    return 1
}

__nasbackup_delete_lock_unchecked() {
    rm -rf "$NASBACKUP_LOCK_DIRECTORY"
}

__nasbackup_get_lock_pid_or_empty() {
    local pid=""

    if [[ -f "$NASBACKUP_LOCK_DIRECTORY/pid" ]]; then
        pid="$(< "$NASBACKUP_LOCK_DIRECTORY/pid")"
        # remove whitespace characters
        pid="${pid//[[:space:]]/}"

        # if only numeric
        if [[ "$pid" == <-> ]]; then
            print "$pid"
        fi
    fi
}

__nasbackup_get_lock_started_at_or_empty() {
    local started_at=""

    if [[ -f "$NASBACKUP_LOCK_DIRECTORY/started_at" ]]; then
        started_at="$(< "$NASBACKUP_LOCK_DIRECTORY/started_at")"
        # remove whitespace characters
        started_at="${started_at//[[:space:]]/}"

        # if only numeric
        if [[ "$started_at" == <-> ]]; then
            print "$started_at"
        fi
    fi
}

__nasbackup_acquire_lock() {
    # try to acquire lock
    if __nasbackup_try_acquire_lock_atomic; then
        # locked successfully
        return 0
    fi

    # could not acquire lock (valid or stale lock) => try to read pid
    local -r lock_pid="$(__nasbackup_get_lock_pid_or_empty)"

    local lock_is_stale=false

    if [[ -z "$lock_pid" ]]; then
        # no readable pid => assume stale
        lock_is_stale=true
    elif ! kill -0 "$lock_pid" 2> /dev/null; then
        # process no longer exists => stale
        lock_is_stale=true
    else
        # process exists: verify process start time to detect possible pid reuse
        local -r stored_start="$(__nasbackup_get_lock_started_at_or_empty)"
        local -r actual_start="$(__nasbackup_get_process_start_epoch "$lock_pid")"
        if [[ -n "$stored_start" && -n "$actual_start" && "$stored_start" != "$actual_start" ]]; then
            # pid was reused by a different process => stale
            lock_is_stale=true
        fi
    fi

    if $lock_is_stale; then
        __nasbackup_delete_lock_unchecked
        if __nasbackup_try_acquire_lock_atomic; then
            # locked successfully after clearing stale lock
            return 0
        fi
    fi

    # lock is not stale
    print -u2 "[nasbackup] another backup is already in progress"
    # could not acquire lock (already locked)
    return 1
}

__nasbackup_release_lock() {
    # check if lock is owned by the current process
    # no started_at check needed: pid reuse is an acquisition-time concern, not release-time
    if [[ "$(__nasbackup_get_lock_pid_or_empty)" == "$$" ]]; then
        # delete lock
        __nasbackup_delete_lock_unchecked
    fi
}

__nasbackup_ensure_local_log_directory() {
    mkdir -p "$NASBACKUP_LOCAL_LOG_DIRECTORY"
    if (( $? != 0 )); then
        print -u2 "[nasbackup] ERROR: failed to create local log directory"
        return 1
    fi
}

__nasbackup_ensure_remote_log_directory() {
    ssh -o ConnectTimeout=5 -o BatchMode=yes "$NASBACKUP_REMOTE_HOST" "mkdir -p ${(q)NASBACKUP_REMOTE_LOG_DIRECTORY}"
    if (( $? != 0 )); then
        print -u2 "[nasbackup] ERROR: failed to create remote log directory"
        return 1
    fi
}

__nasbackup_cleanup_old_logs() {
    find "$NASBACKUP_LOCAL_LOG_DIRECTORY" -type f -name 'nasbackup-*.log' -mtime +"$NASBACKUP_LOG_RETENTION_DAYS" -delete > /dev/null 2>&1 \
        || print -u2 "[nasbackup] WARNING: local log cleanup failed"

    ssh -o ConnectTimeout=5 -o BatchMode=yes "$NASBACKUP_REMOTE_HOST" \
        "find ${(q)NASBACKUP_REMOTE_LOG_DIRECTORY} -type f -name 'nasbackup-*.log' -mtime +${NASBACKUP_LOG_RETENTION_DAYS} -delete" \
        > /dev/null 2>&1 \
        || print -u2 "[nasbackup] WARNING: remote log cleanup failed"
}

__nasbackup_write_status_file() {
    if (( $# != 6 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_write_status_file requires 6 arguments"
        return 1
    fi

    local -r status_type="$1"
    local -r run_id="$2"
    local -r pid="$3"
    local -r started_at="$4"
    local -r finished_at="$5"
    local -r exit_code="$6"

    local status_file=""

    case "$status_type" in
        last_run)
            status_file="$NASBACKUP_LAST_RUN_FILE"
            ;;
        last_success)
            status_file="$NASBACKUP_LAST_SUCCESS_FILE"
            ;;
        *)
            print -u2 "[nasbackup] ERROR: invalid status file type: $status_type"
            return 1
            ;;
    esac

    __nasbackup_ensure_local_log_directory || return 1

    {
        print "run_id=$run_id"
        print "pid=$pid"
        print "started_at=$started_at"
        print "finished_at=$finished_at"
        print "exit_code=$exit_code"
    } > "$status_file"
}

__nasbackup_get_status_value_or_empty() {
    if (( $# != 2 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_get_status_value_or_empty requires 2 arguments"
        return 1
    fi

    local -r status_file="$1"
    local -r key="$2"

    if [[ -f "$status_file" ]]; then
        grep -E "^${key}=" "$status_file" | head -1 | cut -d '=' -f 2-
    fi
}

__nasbackup_print_status_file() {
    if (( $# != 1 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_print_status_file requires 1 argument"
        return 1
    fi

    local -r status_type="$1"
    local status_file=""
    local status_label=""

    case "$status_type" in
        last_run)
            status_file="$NASBACKUP_LAST_RUN_FILE"
            status_label="Last run"
            ;;
        last_success)
            status_file="$NASBACKUP_LAST_SUCCESS_FILE"
            status_label="Last successful run"
            ;;
        *)
            print -u2 "[nasbackup] ERROR: invalid status file type: $status_type"
            return 1
            ;;
    esac

    if [[ ! -f "$status_file" ]]; then
        print -u2 "$status_label: never"
        return 0
    fi

    local -r run_id="$(__nasbackup_get_status_value_or_empty "$status_file" run_id)"
    local -r pid="$(__nasbackup_get_status_value_or_empty "$status_file" pid)"

    local started_at="unknown"
    local -r started_at_epoch="$(__nasbackup_get_status_value_or_empty "$status_file" started_at)"
    if [[ "$started_at_epoch" == <-> ]]; then
        started_at="$(date -r "$started_at_epoch" "+%Y-%m-%dT%H:%M:%S%z")"
    fi

    local finished_at="unknown"
    local -r finished_at_epoch="$(__nasbackup_get_status_value_or_empty "$status_file" finished_at)"
    if [[ "$finished_at_epoch" == <-> ]]; then
        finished_at="$(date -r "$finished_at_epoch" "+%Y-%m-%dT%H:%M:%S%z")"
    fi

    local -r exit_code="$(__nasbackup_get_status_value_or_empty "$status_file" exit_code)"

    print -u2 "$status_label: ${run_id:-unknown} (pid=${pid:-unknown}) from $started_at to $finished_at with exit_code=${exit_code:-unknown}"
}

__nasbackup_last_success_is_overdue() {
    if [[ ! -f "$NASBACKUP_LAST_SUCCESS_FILE" ]]; then
        return 0
    fi

    local -r last_success_finished_at="$(__nasbackup_get_status_value_or_empty "$NASBACKUP_LAST_SUCCESS_FILE" finished_at)"
    if [[ -z "$last_success_finished_at" || "$last_success_finished_at" != <-> ]]; then
        return 0
    fi

    local -r now_epoch="$(date '+%s')"
    (( now_epoch - last_success_finished_at > NASBACKUP_LAST_SUCCESS_MAX_AGE_SECONDS ))
}

__nasbackup_backup_directory_to_nas() {
    if (( $# != 4 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_backup_directory_to_nas requires 4 arguments"
        return 1
    fi

    local -r job_name="$1"
    local -r source_dir_without_trailing_slash="${2%/}"
    local -r run_id="$3"
    local -r started_at="$4"

    print -u2 "========================================================================"
    print -u2 " Starting backup job: $job_name ($source_dir_without_trailing_slash)"
    print -u2 "========================================================================"

    if [[ ! -d "$source_dir_without_trailing_slash" ]]; then
        print -u2 "[nasbackup] [$job_name] ERROR: source is not a directory: $source_dir_without_trailing_slash"
        return 1
    fi

    if [[ ! -d "$NASBACKUP_LOCAL_LOG_DIRECTORY" ]]; then
        print -u2 "[nasbackup] [$job_name] ERROR: local log directory does not exist: $NASBACKUP_LOCAL_LOG_DIRECTORY"
        return 1
    fi

    local started_at_formatted
    started_at_formatted="$(date -r "$started_at" "+%Y%m%d-%H%M%S" 2> /dev/null)"
    if (( $? != 0 )) || [[ -z "$started_at_formatted" ]]; then
        print -u2 "[nasbackup] [$job_name] ERROR: invalid started_at epoch: $started_at"
        return 1
    fi

    local -r log_prefix="nasbackup-$started_at_formatted-$run_id-$job_name"

    local -r rsynclogfile_file_name="$log_prefix-rsynclogfile.log"
    local -r local_rsynclogfile_file="$NASBACKUP_LOCAL_LOG_DIRECTORY/$rsynclogfile_file_name"
    
    local -r rsyncoutput_file_name="$log_prefix-rsyncoutput.log"
    local -r local_rsyncoutput_file="$NASBACKUP_LOCAL_LOG_DIRECTORY/$rsyncoutput_file_name"

    local -r combinedlog_file_name="$log_prefix-combined.log"
    local -r local_combinedlog_file="$NASBACKUP_LOCAL_LOG_DIRECTORY/$combinedlog_file_name"

    local -ra rsync_args=(
        --recursive
        --links
        --perms
        --times

        # BACKUP: do not use update, MacBook is the source of truth
        # RESTORE: use update
        # --update
        
        # BACKUP: use delete, MacBook is the source of truth
        # RESTORE: do not use delete
        --delete
        
        --filter="merge $NASBACKUP_RSYNC_FILTER_FILE"
        --rsync-path="$NASBACKUP_REMOTE_RSYNC_PATH"
        --info=progress2,stats2
        --human-readable
        --log-file="$local_rsynclogfile_file"
        --log-file-format="%i %f%L (size = %'lB = %''l, mtime = %M)"
    )

    if [[ -t 1 ]]; then
        rsync \
            "${rsync_args[@]}" \
            "$source_dir_without_trailing_slash" \
            "$NASBACKUP_REMOTE_HOST:$NASBACKUP_REMOTE_ROOT" \
            2>&1 | tee "$local_rsyncoutput_file" >&2
        local -r rsync_exit_code="${pipestatus[1]}"
    else
        rsync \
            "${rsync_args[@]}" \
            "$source_dir_without_trailing_slash" \
            "$NASBACKUP_REMOTE_HOST:$NASBACKUP_REMOTE_ROOT" \
            > "$local_rsyncoutput_file" 2>&1
        local -r rsync_exit_code="$?"
    fi

    : > "$local_combinedlog_file"

    if [[ -f "$local_rsynclogfile_file" ]]; then
        cat "$local_rsynclogfile_file" >> "$local_combinedlog_file"
    else
        print "ERROR: rsync produced no log file" >> "$local_combinedlog_file"
    fi

    {
        print ""
        print "=========================================================================================="
        print ""
    } >> "$local_combinedlog_file"

    if [[ -f "$local_rsyncoutput_file" ]]; then
        cat "$local_rsyncoutput_file" >> "$local_combinedlog_file"
    else
        print "ERROR: no rsync stdout/stderr log file was produced" >> "$local_combinedlog_file"
    fi

    rsync \
        --rsync-path="$NASBACKUP_REMOTE_RSYNC_PATH" \
        "$local_combinedlog_file" \
        "$NASBACKUP_REMOTE_HOST:$NASBACKUP_REMOTE_LOG_DIRECTORY/$combinedlog_file_name" \
        > /dev/null 2>&1
    local -r log_upload_exit_code="$?"

    local return_value=0
    local errors=""

    if (( rsync_exit_code != 0 )); then
        errors+=$'\n rsync failed (exit code '$rsync_exit_code')'
        print -u2 "[nasbackup] [$job_name] ERROR: rsync failed (exit code $rsync_exit_code)"
        (( return_value |= 1 ))
    fi

    if [[ ! -f "$local_rsynclogfile_file" ]]; then
        errors+=$'\n rsync produced no log file'
        print -u2 "[nasbackup] [$job_name] ERROR: rsync produced no log file"
        (( return_value |= 2 ))
    fi

    if [[ ! -f "$local_rsyncoutput_file" ]]; then
        errors+=$'\n no rsync stdout/stderr log file was produced'
        print -u2 "[nasbackup] [$job_name] ERROR: no rsync stdout/stderr log file was produced"
        (( return_value |= 4 ))
    fi

    if (( log_upload_exit_code != 0 )); then
        errors+=$'\n log upload failed'
        print -u2 "[nasbackup] [$job_name] ERROR: log upload failed"
        (( return_value |= 8 ))
    fi

    local -r desktop_error_file="$HOME/Desktop/NASBACKUP_ERROR_$combinedlog_file_name"
    if (( return_value != 0 )); then
        if cp "$local_combinedlog_file" "$desktop_error_file" 2> /dev/null; then
            {
                print ""
                print "=========================================================================================="
                print "ERRORS:"
            } >> "$desktop_error_file"
            print "$errors" >> "$desktop_error_file"
        else
            print -u2 "[nasbackup] [$job_name] WARNING: could not write error file to Desktop"
        fi
    fi

    return "$return_value"
}

__nasbackup_backup() {
    local backup_exit_code=0

    {
        trap '__nasbackup_release_lock; return 129' HUP
        trap '__nasbackup_release_lock; return 130' INT
        trap '__nasbackup_release_lock; return 131' QUIT
        trap '__nasbackup_release_lock; return 143' TERM

        local -r run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
        local -r started_at="$(__nasbackup_get_process_start_epoch $$)"

        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$NASBACKUP_REMOTE_HOST" "test -x ${(q)NASBACKUP_REMOTE_RSYNC_PATH}" 2> /dev/null; then
            print -u2 "[nasbackup] ERROR: NAS ($NASBACKUP_REMOTE_HOST) is not reachable or rsync not found at $NASBACKUP_REMOTE_RSYNC_PATH"
            return 100
        fi

        if ! __nasbackup_acquire_lock; then
            return 101
        fi
        if [[ ! -f "$NASBACKUP_SECRETS_FILE" ]]; then
            print -u2 "[nasbackup] ERROR: $NASBACKUP_SECRETS_FILE does not exist"
            return 1
        else
            source "$NASBACKUP_SECRETS_FILE"
        fi

        if [[ -z "${NASBACKUP_SECRETS_HEALTHCHECKS_PING_URL:-}" ]]; then
            print -u2 "[nasbackup] ERROR: NASBACKUP_SECRETS_HEALTHCHECKS_PING_URL is not set"
            return 1
        fi

        if [[ "$NASBACKUP_RSYNC_FILTER_FILE" == *' '* ]]; then
            print -u2 "[nasbackup] ERROR: filter file path must not contain spaces: $NASBACKUP_RSYNC_FILTER_FILE"
            return 1
        fi

        if [[ ! -f "$NASBACKUP_RSYNC_FILTER_FILE" ]]; then
            print -u2 "[nasbackup] ERROR: missing rsync filter file: $NASBACKUP_RSYNC_FILTER_FILE"
            return 1
        fi

        __nasbackup_ensure_local_log_directory || return 1
        __nasbackup_ensure_remote_log_directory || return 1

        curl \
            --fail \
            --silent \
            --show-error \
            --max-time 10 \
            --retry 5 \
            --request POST \
            --url "$NASBACKUP_SECRETS_HEALTHCHECKS_PING_URL/start?rid=$run_id" \
            --output /dev/null \
            || print -u2 "[nasbackup] WARNING: Healthchecks.io start ping failed"

        __nasbackup_cleanup_old_logs

        # Keep backup jobs last in this block: the always block captures this block's exit status via $?.
        __nasbackup_backup_directory_to_nas "documents" "$HOME/Documents" "$run_id" "$started_at" || return
        __nasbackup_backup_directory_to_nas "git" "$HOME/git" "$run_id" "$started_at" || return
        __nasbackup_backup_directory_to_nas "vaultkeychain" "$HOME/Vault Keychain" "$run_id" "$started_at" || return
    } always {
        backup_exit_code="$?"

        local -r finished_at="$(date +%s)"

        __nasbackup_write_status_file last_run "$run_id" "$$" "$started_at" "$finished_at" "$backup_exit_code" \
            || print -u2 "[nasbackup] WARNING: failed to write last-run status file"
        if (( backup_exit_code == 0 )); then
            __nasbackup_write_status_file last_success "$run_id" "$$" "$started_at" "$finished_at" "$backup_exit_code" \
                || print -u2 "[nasbackup] WARNING: failed to write last-success status file"
        fi

        if [[ -n "${NASBACKUP_SECRETS_HEALTHCHECKS_PING_URL:-}" ]]; then
            curl \
                --fail \
                --silent \
                --show-error \
                --max-time 10 \
                --retry 5 \
                --request POST \
                --url "$NASBACKUP_SECRETS_HEALTHCHECKS_PING_URL/$backup_exit_code?rid=$run_id" \
                --output /dev/null \
                || print -u2 "[nasbackup] WARNING: Healthchecks.io finish ping failed"
        fi

        __nasbackup_release_lock
        trap - HUP INT QUIT TERM
    }

    return "$backup_exit_code"
}

__nasbackup_logs() {
    if [[ ! -d "$NASBACKUP_LOCAL_LOG_DIRECTORY" ]]; then
        print -u2 "[nasbackup] no logs yet (directory does not exist: $NASBACKUP_LOCAL_LOG_DIRECTORY)"
        return 1
    fi
    open "$NASBACKUP_LOCAL_LOG_DIRECTORY"
}

__nasbackup_status() {
    # TODO: enabled/disabled

    if [[ ! -d "$NASBACKUP_LOCK_DIRECTORY" ]]; then
        print -u2 "[nasbackup] no backup is currently in progress"
    else
        print -u2 "[nasbackup] another backup is currently in progress"

        local -r lock_pid="$(__nasbackup_get_lock_pid_or_empty)"
        print -u2 "PID: ${lock_pid:-unknown}"

        local -r lock_started_at_epoch="$(__nasbackup_get_lock_started_at_or_empty)"
        local -r lock_started_at="${lock_started_at_epoch:+$(date -r "$lock_started_at_epoch" "+%Y-%m-%dT%H:%M:%S%z")}"
        print -u2 "Started at: ${lock_started_at:-unknown}"

        print -u2 "See logs: \`nasbackup logs\`"
    fi

    print -u2 ""
    __nasbackup_print_status_file last_run
    __nasbackup_print_status_file last_success

    if __nasbackup_last_success_is_overdue; then
        print -u2 "WARNING: last successful backup is missing or older than $NASBACKUP_LAST_SUCCESS_MAX_AGE_SECONDS seconds"
    fi

    return 0
}

__nasbackup_enable() {
    print -u2 "[nasbackup] ERROR: enable is not implemented yet"
    return 1
}

__nasbackup_disable() {
    print -u2 "[nasbackup] ERROR: disable is not implemented yet"
    return 1
}

__nasbackup_help() {
    print -u2 "Usage:"
    print -u2 "  nasbackup"
    print -u2 "  nasbackup backup"
    print -u2 "  nasbackup logs"
    print -u2 "  nasbackup status"
    print -u2 "  nasbackup enable"
    print -u2 "  nasbackup disable"
    print -u2 "  nasbackup help"
}

nasbackup() {
    if (( $# == 0 )); then
        __nasbackup_backup
        return
    fi

    case "$1" in
        backup)
            __nasbackup_backup
            ;;
        logs)
            __nasbackup_logs
            ;;
        status)
            __nasbackup_status
            ;;
        enable)
            __nasbackup_enable
            ;;
        disable)
            __nasbackup_disable
            ;;
        help)
            __nasbackup_help
            ;;
        *)
            __nasbackup_help
            return 1
            ;;
    esac
}
