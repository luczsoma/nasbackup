#!/usr/bin/env zsh

# nasbackup
# A zsh-based tool that backs up local directories to a remote location via rsync over SSH, with optional launchd or cron scheduling.
# https://github.com/luczsoma/nasbackup

typeset -ri \
    __NASBACKUP_JOB_EXIT_CODE_BITMASK_RSYNC_ERROR=1 \
    __NASBACKUP_JOB_EXIT_CODE_BITMASK_NO_RSYNC_LOGFILE_ERROR=2 \
    __NASBACKUP_JOB_EXIT_CODE_BITMASK_RSYNC_LOGFILE_UPLOAD_ERROR=4 \
    __NASBACKUP_EXIT_CODE_GENERIC_ERROR=8 \
    __NASBACKUP_EXIT_CODE_CONFIG_ERROR=9 \
    __NASBACKUP_EXIT_CODE_LOCK_ACQUISITION_ERROR=10 \
    __NASBACKUP_EXIT_CODE_LOCAL_ENV_SETUP_ERROR=11 \
    __NASBACKUP_EXIT_CODE_REMOTE_ENV_SETUP_ERROR=12 \
    __NASBACKUP_EXIT_CODE_SCHEDULING_ERROR=13 \
    __NASBACKUP_EXIT_CODE_SIGNAL_HUP=129 \
    __NASBACKUP_EXIT_CODE_SIGNAL_INT=130 \
    __NASBACKUP_EXIT_CODE_SIGNAL_QUIT=131 \
    __NASBACKUP_EXIT_CODE_SIGNAL_TERM=143

typeset -r __NASBACKUP_LOCK_DIRECTORY="/tmp/nasbackup.lock"

typeset -r __NASBACKUP_LAUNCHD_LABEL="io.github.luczsoma.nasbackup"
typeset -r __NASBACKUP_LAUNCHD_PLIST_PATH="$HOME/Library/LaunchAgents/$__NASBACKUP_LAUNCHD_LABEL.plist"
typeset -r __NASBACKUP_CRON_MARKER="# nasbackup-managed"

# Detect date implementation at load time: GNU coreutils (Linux) vs BSD date (macOS)
if date --version > /dev/null 2>&1; then
    typeset -ri __NASBACKUP_DATE_IS_GNU=1
else
    typeset -ri __NASBACKUP_DATE_IS_GNU=0
fi

__nasbackup_get_process_start_epoch_or_empty() {
    if (( $# != 1 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_get_process_start_epoch_or_empty requires 1 argument"
        return 0
    fi

    local -r pid="$1"
    local -r raw="$(LC_ALL=C ps -o lstart= -p "$pid" 2> /dev/null | tr -s ' ' | sed 's/^ //;s/ *$//')"
    if [[ -z "$raw" ]]; then
        return 0
    fi

    local epoch
    if (( __NASBACKUP_DATE_IS_GNU )); then
        epoch="$(date -d "$raw" +%s 2> /dev/null)"
    else
        epoch="$(LC_ALL=C date -j -f '%a %b %d %H:%M:%S %Y' "$raw" +%s 2> /dev/null)"
    fi
    if [[ "$epoch" == <-> ]]; then
        print "$epoch"
    fi
}

__nasbackup_format_epoch() {
    if (( $# != 2 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_format_epoch requires 2 arguments"
        return 1
    fi
    local -r epoch="$1"
    local -r fmt="$2"
    if (( __NASBACKUP_DATE_IS_GNU )); then
        date -d "@$epoch" "$fmt" 2> /dev/null
    else
        date -r "$epoch" "$fmt" 2> /dev/null
    fi
}

__nasbackup_get_lock_pid_or_empty() {
    local pid=""

    if [[ -f "$__NASBACKUP_LOCK_DIRECTORY/pid" ]]; then
        pid="$(< "$__NASBACKUP_LOCK_DIRECTORY/pid")"
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

    if [[ -f "$__NASBACKUP_LOCK_DIRECTORY/started_at" ]]; then
        started_at="$(< "$__NASBACKUP_LOCK_DIRECTORY/started_at")"
        # remove whitespace characters
        started_at="${started_at//[[:space:]]/}"

        # if only numeric
        if [[ "$started_at" == <-> ]]; then
            print "$started_at"
        fi
    fi
}

__nasbackup_try_acquire_lock_atomic() {
    # try to acquire lock
    if mkdir "$__NASBACKUP_LOCK_DIRECTORY" 2> /dev/null; then
        # write pid and process start time as epoch (for pid reuse detection)
        local -r start_epoch="$(__nasbackup_get_process_start_epoch_or_empty $$)"
        if [[ -n "$start_epoch" ]] \
            && print "$$" > "$__NASBACKUP_LOCK_DIRECTORY/pid" \
            && print "$start_epoch" > "$__NASBACKUP_LOCK_DIRECTORY/started_at"; then
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
        local -r actual_start="$(__nasbackup_get_process_start_epoch_or_empty "$lock_pid")"
        if [[ -n "$stored_start" && -n "$actual_start" && "$stored_start" != "$actual_start" ]]; then
            # pid was reused by a different process => stale
            lock_is_stale=true
        fi
    fi

    if $lock_is_stale; then
        # TOCTOU: two processes can both reach here and both delete+reacquire.
        # No shell-level atomic primitive covers delete+mkdir together; flock would.
        # Accepted: the window is microseconds on a script invoked at most a few times a day.
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

__nasbackup_delete_lock_unchecked() {
    rm -rf "$__NASBACKUP_LOCK_DIRECTORY"
}

__nasbackup_release_lock() {
    # check if lock is owned by the current process
    # no started_at check needed: pid reuse is an acquisition-time concern, not release-time
    if [[ "$(__nasbackup_get_lock_pid_or_empty)" == "$$" ]]; then
        # delete lock
        __nasbackup_delete_lock_unchecked
    fi
}

__nasbackup_ensure_config() {
    # zsh-improved version of `$(realpath $0)` and `$(dirname $(realpath $0))`
    __NASBACKUP_SCRIPT_PATH="${${(%):-%x}:A}"
    __NASBACKUP_SCRIPT_DIRECTORY="${__NASBACKUP_SCRIPT_PATH:h}"

    __NASBACKUP_CONFIG_FILE="$__NASBACKUP_SCRIPT_DIRECTORY/nasbackup.config.zsh"
    if [[ ! -f "$__NASBACKUP_CONFIG_FILE" ]]; then
        print -u2 "[nasbackup] ERROR: config file not found: $__NASBACKUP_CONFIG_FILE"
        return 1
    fi
    source "$__NASBACKUP_CONFIG_FILE"

    # validate backup settings

    # validate jobs: must have an even number of non-empty values
    if (( ${#__NASBACKUP_JOBS[@]} == 0 )); then
        print -u2 "[nasbackup] ERROR: config: __NASBACKUP_JOBS must not be empty"
        return 1
    fi
    if (( ${#__NASBACKUP_JOBS[@]} % 2 != 0 )); then
        print -u2 "[nasbackup] ERROR: config: __NASBACKUP_JOBS must have an even number of values (job_name, source_directory) pairs"
        return 1
    fi
    local i
    for (( i = 1; i <= ${#__NASBACKUP_JOBS[@]}; i++ )); do
        if [[ -z "${__NASBACKUP_JOBS[$i]}" ]]; then
            print -u2 "[nasbackup] ERROR: config: __NASBACKUP_JOBS[$i] must not be empty"
            return 1
        fi
    done

    # validate job_names: must be unique and only contain letters, digits, hyphens, or underscores
    local job_names_seen=()
    for (( i = 1; i <= ${#__NASBACKUP_JOBS[@]}; i += 2 )); do
        local job_name="${__NASBACKUP_JOBS[$i]}"
        if [[ ! "$job_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            print -u2 "[nasbackup] ERROR: config: job_name \"$job_name\" must only contain letters, digits, hyphens, or underscores"
            return 1
        fi
        if [[ "$job_name" == "default" ]]; then
            print -u2 "[nasbackup] ERROR: config: job_name \"default\" is reserved"
            return 1
        fi
        if [[ "${job_names_seen[(re)$job_name]}" == "$job_name" ]]; then
            print -u2 "[nasbackup] ERROR: config: duplicate job_name \"$job_name\""
            return 1
        fi
        job_names_seen+=("$job_name")
    done

    # validate local settings
    [[ -n "$__NASBACKUP_LOCAL_LOG_DIRECTORY" ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_LOCAL_LOG_DIRECTORY must not be empty"; return 1; }
    { [[ -v __NASBACKUP_LOCAL_LOG_RETENTION_DAYS ]] && [[ -z "$__NASBACKUP_LOCAL_LOG_RETENTION_DAYS" || "$__NASBACKUP_LOCAL_LOG_RETENTION_DAYS" == <0-> ]]; } || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_LOCAL_LOG_RETENTION_DAYS must be defined as a non-negative integer or empty (empty means no restriction)"; return 1; }
    [[ -n "$__NASBACKUP_LOCAL_RSYNC_PATH" ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_LOCAL_RSYNC_PATH must not be empty"; return 1; }

    # validate remote settings
    [[ -n "$__NASBACKUP_REMOTE_HOST" ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_REMOTE_HOST must not be empty"; return 1; }
    [[ -n "$__NASBACKUP_REMOTE_ROOT" ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_REMOTE_ROOT must not be empty"; return 1; }
    [[ -n "$__NASBACKUP_REMOTE_LOG_DIRECTORY" ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_REMOTE_LOG_DIRECTORY must not be empty"; return 1; }
    { [[ -v __NASBACKUP_REMOTE_LOG_RETENTION_DAYS ]] && [[ -z "$__NASBACKUP_REMOTE_LOG_RETENTION_DAYS" || "$__NASBACKUP_REMOTE_LOG_RETENTION_DAYS" == <0-> ]]; } || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_REMOTE_LOG_RETENTION_DAYS must be defined as a non-negative integer or empty (empty means no restriction)"; return 1; }
    [[ -n "$__NASBACKUP_REMOTE_RSYNC_PATH" ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_REMOTE_RSYNC_PATH must not be empty"; return 1; }

    # validate monitoring settings
    [[ -v __NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY must be defined (set to empty string to disable Healthchecks.io pings)"; return 1; }
    [[ -v __NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG must be defined (set to empty string to disable Healthchecks.io pings)"; return 1; }

    # validate scheduling settings
    [[ -v __NASBACKUP_SCHEDULE ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE must be defined (set to empty string if you won’t run \`nasbackup enable\`)"; return 1; }
    if [[ -n "$__NASBACKUP_SCHEDULE" ]]; then
        if [[ "${__NASBACKUP_SCHEDULE//[^=]/}" != "=" ]]; then
            print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE must be in the format \"launchd=<expression>\" or \"cron=<expression>\""
            return 1
        fi
        local -r schedule_type="${__NASBACKUP_SCHEDULE%=*}"
        local -r schedule_value="${__NASBACKUP_SCHEDULE#*=}"
        case "$schedule_type" in
            launchd)
                if [[ "$OSTYPE" != darwin* ]]; then
                    print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE type \"launchd\" is only supported on macOS; use \"cron=...\" instead"
                    return 1
                fi
                if [[ -z "$schedule_value" ]]; then
                    print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE launchd expression must not be empty"
                    return 1
                fi
                local -ra launchd_entries=("${(@s:;:)schedule_value}")
                if (( ${#launchd_entries} == 0 )); then
                    print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE launchd expression must have at least one entry"
                    return 1
                fi
                local -ra launchd_key_names=(Minute Hour Day Weekday Month)
                local -ra launchd_field_ranges=("0-59" "0-23" "1-31" "0-7" "1-12")
                local launchd_entry launchd_comma_count
                local -a launchd_fields
                local lfi launchd_field launchd_range_glob
                for launchd_entry in "${launchd_entries[@]}"; do
                    if [[ -z "$launchd_entry" ]]; then
                        print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE launchd expression must not contain empty entries (check for leading, trailing, or consecutive semicolons)"
                        return 1
                    fi
                    launchd_comma_count="${launchd_entry//[^,]/}"
                    if (( ${#launchd_comma_count} != 4 )); then
                        print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE launchd entry \"$launchd_entry\" must have exactly 5 comma-separated fields (Minute,Hour,Day,Weekday,Month)"
                        return 1
                    fi
                    launchd_fields=("${(@s:,:)launchd_entry}")
                    for lfi in {1..5}; do
                        launchd_field="${launchd_fields[$lfi]}"
                        if [[ -n "$launchd_field" ]]; then
                            launchd_range_glob="<${launchd_field_ranges[$lfi]}>"
                            if [[ "$launchd_field" != ${~launchd_range_glob} ]]; then
                                print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE launchd entry \"$launchd_entry\" ${launchd_key_names[$lfi]} field \"$launchd_field\" must be empty (wildcard) or an integer in range ${launchd_field_ranges[$lfi]}"
                                return 1
                            fi
                        fi
                    done
                done
                ;;
            cron)
                if [[ "$OSTYPE" == darwin* ]]; then
                    print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE type \"cron\" is not supported on macOS; use \"launchd=...\" instead"
                    return 1
                fi
                if [[ -z "$schedule_value" ]]; then
                    print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE cron expression must not be empty"
                    return 1
                fi
                ;;
            *)
                print -u2 "[nasbackup] ERROR: config: __NASBACKUP_SCHEDULE type \"$schedule_type\" is not supported; must be \"launchd\" or \"cron\""
                return 1
                ;;
        esac
    fi

    # validate advanced settings
    [[ -v __NASBACKUP_EXTRA_RSYNC_ARGS ]] || { print -u2 "[nasbackup] ERROR: config: __NASBACKUP_EXTRA_RSYNC_ARGS must be defined (set to an empty array to add no extra args)"; return 1; }

    # cross-validate: no job name may resolve to the remote log directory
    for (( i = 1; i <= ${#__NASBACKUP_JOBS[@]}; i += 2 )); do
        local job_name="${__NASBACKUP_JOBS[$i]}"
        if [[ "$__NASBACKUP_REMOTE_ROOT/$job_name" == "$__NASBACKUP_REMOTE_LOG_DIRECTORY" ]]; then
            print -u2 "[nasbackup] ERROR: config: job_name \"$job_name\" conflicts with __NASBACKUP_REMOTE_LOG_DIRECTORY"
            return 1
        fi
    done

    # create variables based on config values
    __NASBACKUP_LAST_RUN_FILE="$__NASBACKUP_LOCAL_LOG_DIRECTORY/last-run"
    __NASBACKUP_LAST_SUCCESS_FILE="$__NASBACKUP_LOCAL_LOG_DIRECTORY/last-success"
    __NASBACKUP_RSYNC_FILTER_DIRECTORY="$__NASBACKUP_SCRIPT_DIRECTORY/rsync-filters"
}

__nasbackup_ensure_local_environment() {
    mkdir -p "$__NASBACKUP_LOCAL_LOG_DIRECTORY" || {
        print -u2 "[nasbackup] ERROR: failed to create local log directory"
        return 1
    }

    if [[ -n "$__NASBACKUP_LOCAL_LOG_RETENTION_DAYS" ]]; then
        local mtime_predicate=""
        (( __NASBACKUP_LOCAL_LOG_RETENTION_DAYS > 0 )) && mtime_predicate="-mtime +$__NASBACKUP_LOCAL_LOG_RETENTION_DAYS"
        find "$__NASBACKUP_LOCAL_LOG_DIRECTORY" -type f -name 'nasbackup-*.log' ${=mtime_predicate} -delete > /dev/null 2>&1 \
            || print -u2 "[nasbackup] WARNING: local log cleanup failed"
    fi
}

__nasbackup_ensure_remote_environment() {
    local -r remote_env_setup="{ test -x ${(q)__NASBACKUP_REMOTE_RSYNC_PATH} && mkdir -p ${(q)__NASBACKUP_REMOTE_LOG_DIRECTORY}; } || exit 1"
    local mtime_predicate=""
    (( __NASBACKUP_REMOTE_LOG_RETENTION_DAYS > 0 )) && mtime_predicate="-mtime +$__NASBACKUP_REMOTE_LOG_RETENTION_DAYS"
    local -r remote_log_cleanup="find ${(q)__NASBACKUP_REMOTE_LOG_DIRECTORY} -type f -name 'nasbackup-*.log' ${mtime_predicate} -delete || exit 2"

    ssh -o ConnectTimeout=5 -o BatchMode=yes "$__NASBACKUP_REMOTE_HOST" \
        "${remote_env_setup}${__NASBACKUP_REMOTE_LOG_RETENTION_DAYS:+; $remote_log_cleanup}" \
        2> /dev/null
    local -r ssh_remote_command_exit_code="$?"

    if (( ssh_remote_command_exit_code == 2 )); then
        print -u2 "[nasbackup] WARNING: remote log cleanup failed"
        return 0
    fi

    if (( ssh_remote_command_exit_code != 0 )); then
        print -u2 "[nasbackup] ERROR: remote ($__NASBACKUP_REMOTE_HOST) is not reachable, rsync not found at $__NASBACKUP_REMOTE_RSYNC_PATH, or remote log directory creation failed"
        return 1
    fi
}

__nasbackup_healthchecks_ping() {
    if (( $# < 2 || $# > 3 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_healthchecks_ping requires 2 or 3 arguments"
        return 1
    fi

    if [[ -z "$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY" || -z "$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG" ]]; then
        print -u2 "[nasbackup] ERROR: __nasbackup_healthchecks_ping requires __NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY and __NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG to be set"
        return 1
    fi

    local -r signal="$1"
    local -r rid="$2"
    local -r body="${3:-}"

    if [[ "$signal" != "start" && "$signal" != "log" && "$signal" != <0-255> ]]; then
        print -u2 "[nasbackup] ERROR: __nasbackup_healthchecks_ping: invalid signal: $signal"
        return 1
    fi

    if (( $# == 3 )) && [[ "$signal" != "log" ]]; then
        print -u2 "[nasbackup] ERROR: __nasbackup_healthchecks_ping: body parameter is only valid for signal=log"
        return 1
    fi

    local -a curl_args=(
        --fail
        --silent
        --show-error
        --max-time 10
        --retry 5
        --request POST
        --url "https://hc-ping.com/$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY/$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG/$signal?rid=$rid"
        --output /dev/null
    )
    if [[ -n "$body" ]]; then
        curl_args+=(--data "$body")
    fi

    curl "${curl_args[@]}" \
        || print -u2 "[nasbackup] WARNING: Healthchecks.io ping failed (signal=$signal, rid=$rid)"
}

__nasbackup_launchd_enable() {
    __nasbackup_ensure_local_environment || return 1

    mkdir -p "$HOME/Library/LaunchAgents" 2> /dev/null || {
        print -u2 "[nasbackup] ERROR: could not create ~/Library/LaunchAgents"
        return 1
    }

    {
        print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        print "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
        print "<plist version=\"1.0\">"
        print "<dict>"
        print "    <key>Label</key>"
        print "    <string>$__NASBACKUP_LAUNCHD_LABEL</string>"
        print "    <key>ProgramArguments</key>"
        print "    <array>"
        print "        <string>/bin/zsh</string>"
        print "        <string>$__NASBACKUP_SCRIPT_PATH</string>"
        print "        <string>backup</string>"
        print "    </array>"
        print "    <key>StartCalendarInterval</key>"

        local -r schedule_value="${__NASBACKUP_SCHEDULE#launchd=}"
        local -ra launchd_entries=("${(@s:;:)schedule_value}")
        local pfi
        local -ra launchd_key_names=(Minute Hour Day Weekday Month)

        if (( ${#launchd_entries} == 1 )); then
            print "    <dict>"
            local -a launchd_fields=("${(@s:,:)launchd_entries[1]}")
            for pfi in {1..5}; do
                if [[ -n "${launchd_fields[$pfi]}" ]]; then
                    print "        <key>${launchd_key_names[$pfi]}</key>"
                    print "        <integer>${launchd_fields[$pfi]}</integer>"
                fi
            done
            print "    </dict>"
        else
            print "    <array>"
            local launchd_entry
            for launchd_entry in "${launchd_entries[@]}"; do
                print "        <dict>"
                local -a plist_fields=("${(@s:,:)launchd_entry}")
                for pfi in {1..5}; do
                    if [[ -n "${plist_fields[$pfi]}" ]]; then
                        print "            <key>${launchd_key_names[$pfi]}</key>"
                        print "            <integer>${plist_fields[$pfi]}</integer>"
                    fi
                done
                print "        </dict>"
            done
            print "    </array>"
        fi
        print "    <key>RunAtLoad</key>"
        print "    <false/>"
        print "    <key>ProcessType</key>"
        print "    <string>Background</string>"
        print "    <key>StandardOutPath</key>"
        print "    <string>$__NASBACKUP_LOCAL_LOG_DIRECTORY/launchd.out.log</string>"
        print "    <key>StandardErrorPath</key>"
        print "    <string>$__NASBACKUP_LOCAL_LOG_DIRECTORY/launchd.err.log</string>"
        print "    <key>NasbackupSchedule</key>"
        print "    <string>${__NASBACKUP_SCHEDULE#launchd=}</string>"
        print "</dict>"
        print "</plist>"
    } > "$__NASBACKUP_LAUNCHD_PLIST_PATH"

    launchctl bootout "gui/$(id -u)/$__NASBACKUP_LAUNCHD_LABEL" 2> /dev/null
    launchctl bootstrap "gui/$(id -u)" "$__NASBACKUP_LAUNCHD_PLIST_PATH" 2> /dev/null || {
        rm -f "$__NASBACKUP_LAUNCHD_PLIST_PATH"
        print -u2 "[nasbackup] ERROR: launchctl bootstrap failed"
        return 1
    }

    print -u2 "[nasbackup] scheduled backups enabled (launchd, schedule: ${__NASBACKUP_SCHEDULE#launchd=})"
}

__nasbackup_launchd_disable() {
    launchctl bootout "gui/$(id -u)/$__NASBACKUP_LAUNCHD_LABEL" 2> /dev/null
    rm -f "$__NASBACKUP_LAUNCHD_PLIST_PATH"
    print -u2 "[nasbackup] scheduled backups disabled (launchd)"
}

__nasbackup_cron() {
    if (( $# != 1 )) || [[ "$1" != "enable" && "$1" != "disable" && "$1" != "status" ]]; then
        print -u2 "[nasbackup] ERROR: __nasbackup_cron requires an argument: enable|disable|status"
        return 1
    fi

    command -v crontab > /dev/null 2>&1 || {
        print -u2 "[nasbackup] ERROR: crontab not found"
        return 1
    }

    local existing_crontab
    existing_crontab="$(crontab -l 2> /dev/null)"
    local -r crontab_read_exit="$?"
    if (( crontab_read_exit != 0 )); then
        local -r crontab_err="$(crontab -l 2>&1 > /dev/null)"
        if [[ "$crontab_err" != *"no crontab"* ]]; then
            print -u2 "[nasbackup] ERROR: failed to read current crontab: $crontab_err"
            return 1
        fi
        existing_crontab=""
    fi

    if [[ "$1" == "status" ]]; then
        if [[ -n "$existing_crontab" ]]; then
            local -r cron_line="$(print -r -- "$existing_crontab" | grep -F "$__NASBACKUP_CRON_MARKER" | head -1)"
            print "${cron_line%% /bin/zsh *}"
        fi
        return 0
    fi

    {
        if [[ -n "$existing_crontab" ]]; then
            print -r -- "$existing_crontab" | grep -vF "$__NASBACKUP_CRON_MARKER"
        fi
        if [[ "$1" == "enable" ]]; then
            print -r -- "${__NASBACKUP_SCHEDULE#cron=} /bin/zsh $__NASBACKUP_SCRIPT_PATH backup $__NASBACKUP_CRON_MARKER"
        fi
    } | crontab - || {
        print -u2 "[nasbackup] ERROR: failed to update crontab entry"
        return 1
    }

    case "$1" in
        enable)
            print -u2 "[nasbackup] scheduled backups enabled (cron, schedule: ${__NASBACKUP_SCHEDULE#cron=})"
            ;;
        disable)
            print -u2 "[nasbackup] scheduled backups disabled (cron)"
            ;;
        *)
            print -u2 "[nasbackup] ERROR: invalid execution path in __nasbackup_cron"
            return 1
            ;;
    esac
}

__nasbackup_write_status_file() {
    if (( $# != 4 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_write_status_file requires 4 arguments"
        return 1
    fi

    if [[ -z "$__NASBACKUP_LAST_RUN_FILE" ]]; then
        print -u2 "[nasbackup] ERROR: __NASBACKUP_LAST_RUN_FILE is not set"
        return 1
    fi

    if [[ -z "$__NASBACKUP_LAST_SUCCESS_FILE" ]]; then
        print -u2 "[nasbackup] ERROR: __NASBACKUP_LAST_SUCCESS_FILE is not set"
        return 1
    fi

    local -r status_type="$1"
    local -r run_id="$2"
    local -r finished_at="$3"
    local -r exit_code="$4"

    local status_file=""

    case "$status_type" in
        last_run)
            status_file="$__NASBACKUP_LAST_RUN_FILE"
            ;;
        last_success)
            status_file="$__NASBACKUP_LAST_SUCCESS_FILE"
            ;;
        *)
            print -u2 "[nasbackup] ERROR: invalid status file type: $status_type"
            return 1
            ;;
    esac

    __nasbackup_ensure_local_environment || return 1

    local -r started_at="$(__nasbackup_get_process_start_epoch_or_empty $$)"
    if [[ -z "$started_at" ]]; then
        print -u2 "[nasbackup] WARNING: could not determine process start time for status file"
    fi

    {
        print "run_id=$run_id"
        print "pid=$$"
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

    if [[ -z "$__NASBACKUP_LAST_RUN_FILE" ]]; then
        print -u2 "[nasbackup] ERROR: __NASBACKUP_LAST_RUN_FILE is not set"
        return 1
    fi

    if [[ -z "$__NASBACKUP_LAST_SUCCESS_FILE" ]]; then
        print -u2 "[nasbackup] ERROR: __NASBACKUP_LAST_SUCCESS_FILE is not set"
        return 1
    fi

    local -r status_type="$1"
    local status_file=""
    local status_label=""

    case "$status_type" in
        last_run)
            status_file="$__NASBACKUP_LAST_RUN_FILE"
            status_label="Last run"
            ;;
        last_success)
            status_file="$__NASBACKUP_LAST_SUCCESS_FILE"
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
        started_at="$(__nasbackup_format_epoch "$started_at_epoch" "+%Y-%m-%dT%H:%M:%S%z")"
    fi

    local finished_at="unknown"
    local -r finished_at_epoch="$(__nasbackup_get_status_value_or_empty "$status_file" finished_at)"
    if [[ "$finished_at_epoch" == <-> ]]; then
        finished_at="$(__nasbackup_format_epoch "$finished_at_epoch" "+%Y-%m-%dT%H:%M:%S%z")"
    fi

    local -r exit_code="$(__nasbackup_get_status_value_or_empty "$status_file" exit_code)"

    print -u2 "$status_label: ${run_id:-unknown} (pid=${pid:-unknown}) from $started_at to $finished_at with exit_code=${exit_code:-unknown}"
}

__nasbackup_backup_directory_to_nas() {
    if (( $# != 3 )); then
        print -u2 "[nasbackup] ERROR: __nasbackup_backup_directory_to_nas requires 3 arguments"
        return $__NASBACKUP_EXIT_CODE_GENERIC_ERROR
    fi

    local -r job_name="$1"
    local -r source_dir="${2%/}"
    local -r run_id="$3"

    local is_tty=0
    # test stderr, not stdout: output goes to fd 2, so fd 2 reflects whether we have a terminal
    [[ -t 2 ]] && is_tty=1

    local -r log_banner="Starting backup job: $job_name ($source_dir)"
    if (( is_tty )); then
        print -u2 "========================================================================"
        print -u2 " $log_banner"
        print -u2 "========================================================================"
    fi

    if [[ -n "$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY" && -n "$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG" ]]; then
        __nasbackup_healthchecks_ping "log" "$run_id" "$log_banner"
    fi

    if [[ ! -d "$source_dir" ]]; then
        print -u2 "[nasbackup] [$job_name] ERROR: source is not a directory: $source_dir"
        return $__NASBACKUP_EXIT_CODE_CONFIG_ERROR
    fi

    local -r started_at_epoch="$(__nasbackup_get_process_start_epoch_or_empty $$)"
    if [[ -z "$started_at_epoch" ]]; then
        print -u2 "[nasbackup] [$job_name] ERROR: could not determine process start time"
        return $__NASBACKUP_EXIT_CODE_GENERIC_ERROR
    fi
    local -r started_at_formatted="$(__nasbackup_format_epoch "$started_at_epoch" "+%Y%m%d-%H%M%S")"
    if [[ -z "$started_at_formatted" ]]; then
        print -u2 "[nasbackup] [$job_name] ERROR: could not format process start time"
        return $__NASBACKUP_EXIT_CODE_GENERIC_ERROR
    fi

    local -r local_rsynclogfile="$__NASBACKUP_LOCAL_LOG_DIRECTORY/nasbackup-$started_at_formatted-$run_id-$job_name.log"

    local -a rsync_filter_args=()
    local -r default_filter_file="$__NASBACKUP_RSYNC_FILTER_DIRECTORY/default.rsync-filter"
    local -r job_filter_file="$__NASBACKUP_RSYNC_FILTER_DIRECTORY/$job_name.rsync-filter"
    [[ -f "$default_filter_file" ]] && rsync_filter_args+=("--filter=merge $default_filter_file")
    [[ -f "$job_filter_file"     ]] && rsync_filter_args+=("--filter=merge $job_filter_file")

    local -ra rsync_args=(
        --recursive
        --links
        --perms
        --times

        # BACKUP: do not use update, backup source is the source of truth
        # RESTORE: use update, so newer files on backup source are not overwritten
        # --update

        # BACKUP: use delete, backup source is the source of truth
        # RESTORE: do not use delete, so existing files on backup source are not deleted
        --delete

        "${rsync_filter_args[@]}"
        --rsync-path="$__NASBACKUP_REMOTE_RSYNC_PATH"
        --info=progress2,stats2
        --human-readable
        --log-file="$local_rsynclogfile"
        --log-file-format="%i %f%L (size = %'lB = %''l, mtime = %M)"
        "${__NASBACKUP_EXTRA_RSYNC_ARGS[@]}"
    )

    # TTY: print progress & stats to stderr (so it doesn’t pollute stdout with user info)
    # non-TTY: discard stdout progress & stats (so it doesn’t pollute launchd/cron logs)
    local stdout_target
    if (( is_tty )); then
        stdout_target=/dev/stderr
    else
        stdout_target=/dev/null
    fi

    "$__NASBACKUP_LOCAL_RSYNC_PATH" "${rsync_args[@]}" "$source_dir/" "$__NASBACKUP_REMOTE_HOST:$__NASBACKUP_REMOTE_ROOT/$job_name" \
        > $stdout_target &
    local -r rsync_pid=$!
    wait $rsync_pid
    local -r rsync_exit_code="$?"
    # received_signal is set by the traps in __nasbackup_backup; if it fired during wait,
    # rsync is still alive (wait returned early) -> forward the signal so it actually stops
    if (( received_signal )); then
        kill -$(( received_signal - 128 )) $rsync_pid 2> /dev/null
        wait $rsync_pid 2> /dev/null
    fi

    "$__NASBACKUP_LOCAL_RSYNC_PATH" \
        --rsync-path="$__NASBACKUP_REMOTE_RSYNC_PATH" \
        "$local_rsynclogfile" \
        "$__NASBACKUP_REMOTE_HOST:$__NASBACKUP_REMOTE_LOG_DIRECTORY" \
        >&2
    local -r log_upload_exit_code="$?"

    local job_exit_code=0

    if (( rsync_exit_code != 0 && !received_signal )); then
        print -u2 "[nasbackup] [$job_name] ERROR: rsync failed (exit code $rsync_exit_code)"
        (( job_exit_code |= __NASBACKUP_JOB_EXIT_CODE_BITMASK_RSYNC_ERROR ))
    fi
    if [[ ! -f "$local_rsynclogfile" ]] && (( !received_signal )); then
        print -u2 "[nasbackup] [$job_name] ERROR: rsync produced no log file"
        (( job_exit_code |= __NASBACKUP_JOB_EXIT_CODE_BITMASK_NO_RSYNC_LOGFILE_ERROR ))
    fi
    if (( log_upload_exit_code != 0 && !received_signal )); then
        print -u2 "[nasbackup] [$job_name] ERROR: log upload failed"
        (( job_exit_code |= __NASBACKUP_JOB_EXIT_CODE_BITMASK_RSYNC_LOGFILE_UPLOAD_ERROR ))
    fi

    return "$job_exit_code"
}

__nasbackup_backup() {
    local backup_exit_code=0

    {
        local received_signal=0
        trap "received_signal=$__NASBACKUP_EXIT_CODE_SIGNAL_HUP"  HUP
        trap "received_signal=$__NASBACKUP_EXIT_CODE_SIGNAL_INT"  INT
        trap "received_signal=$__NASBACKUP_EXIT_CODE_SIGNAL_QUIT" QUIT
        trap "received_signal=$__NASBACKUP_EXIT_CODE_SIGNAL_TERM" TERM

        local -r run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

        __nasbackup_ensure_config || return $(( received_signal ? received_signal : __NASBACKUP_EXIT_CODE_CONFIG_ERROR ))

        __nasbackup_acquire_lock || return $(( received_signal ? received_signal : __NASBACKUP_EXIT_CODE_LOCK_ACQUISITION_ERROR ))

        if [[ -n "$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY" && -n "$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG" ]]; then
            __nasbackup_healthchecks_ping "start" "$run_id"
        fi
        (( received_signal )) && return $received_signal

        __nasbackup_ensure_local_environment || return $(( received_signal ? received_signal : __NASBACKUP_EXIT_CODE_LOCAL_ENV_SETUP_ERROR ))
        __nasbackup_ensure_remote_environment || return $(( received_signal ? received_signal : __NASBACKUP_EXIT_CODE_REMOTE_ENV_SETUP_ERROR ))

        set -- "${__NASBACKUP_JOBS[@]}"
        while (( $# >= 2 )); do
            __nasbackup_backup_directory_to_nas "$1" "$2" "$run_id" || return $(( received_signal ? received_signal : $? ))
            (( received_signal )) && return $received_signal
            shift 2
        done
    } always {
        backup_exit_code="$?"

        local -r finished_at="$(date +%s)"

        if [[ -n "$__NASBACKUP_LAST_RUN_FILE" && -n "$__NASBACKUP_LAST_SUCCESS_FILE" ]]; then
            __nasbackup_write_status_file last_run "$run_id" "$finished_at" "$backup_exit_code" \
                || print -u2 "[nasbackup] WARNING: failed to write last-run status file"
            if (( backup_exit_code == 0 )); then
                __nasbackup_write_status_file last_success "$run_id" "$finished_at" "$backup_exit_code" \
                    || print -u2 "[nasbackup] WARNING: failed to write last-success status file"
            fi
        fi

        if [[ -n "$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_KEY" && -n "$__NASBACKUP_SECRETS_HEALTHCHECKS_PING_SLUG" ]]; then
            __nasbackup_healthchecks_ping "$backup_exit_code" "$run_id"
        fi

        __nasbackup_release_lock
        trap - HUP INT QUIT TERM
    }

    return "$backup_exit_code"
}

__nasbackup_logs() {
    __nasbackup_ensure_config || return $__NASBACKUP_EXIT_CODE_CONFIG_ERROR

    if [[ -d "$__NASBACKUP_LOCAL_LOG_DIRECTORY" ]]; then
        print "$__NASBACKUP_LOCAL_LOG_DIRECTORY"
    else
        print -u2 "[nasbackup] no logs yet (directory does not exist: $__NASBACKUP_LOCAL_LOG_DIRECTORY)"
    fi
}

__nasbackup_status() {
    __nasbackup_ensure_config || return $__NASBACKUP_EXIT_CODE_CONFIG_ERROR

    if [[ ! -d "$__NASBACKUP_LOCK_DIRECTORY" ]]; then
        print -u2 "[nasbackup] no backup is currently in progress"
    else
        print -u2 "[nasbackup] another backup is currently in progress"

        local -r lock_pid="$(__nasbackup_get_lock_pid_or_empty)"
        print -u2 "PID: ${lock_pid:-unknown}"

        local -r lock_started_at_epoch="$(__nasbackup_get_lock_started_at_or_empty)"
        local -r lock_started_at="${lock_started_at_epoch:+$(__nasbackup_format_epoch "$lock_started_at_epoch" "+%Y-%m-%dT%H:%M:%S%z")}"
        print -u2 "Started at: ${lock_started_at:-unknown}"

        print -u2 "See logs: \`nasbackup logs\`"
    fi

    print -u2 ""
    __nasbackup_print_status_file last_run
    __nasbackup_print_status_file last_success

    print -u2 ""
    local installed_schedule
    if [[ "$OSTYPE" == darwin* ]]; then
        if [[ -f "$__NASBACKUP_LAUNCHD_PLIST_PATH" ]]; then
            installed_schedule="$(plutil -extract NasbackupSchedule raw -o - "$__NASBACKUP_LAUNCHD_PLIST_PATH" 2> /dev/null)"
            print -u2 "Scheduled backups: enabled (launchd, schedule: ${installed_schedule:-unknown})"
        else
            print -u2 "Scheduled backups: disabled"
        fi
    else
        installed_schedule="$(__nasbackup_cron status)"
        if [[ -n "$installed_schedule" ]]; then
            print -u2 "Scheduled backups: enabled (cron, schedule: $installed_schedule)"
        else
            print -u2 "Scheduled backups: disabled"
        fi
    fi

    return 0
}

__nasbackup_enable() {
    __nasbackup_ensure_config || return $__NASBACKUP_EXIT_CODE_CONFIG_ERROR

    if [[ -z "$__NASBACKUP_SCHEDULE" ]]; then
        print -u2 "[nasbackup] ERROR: no schedule configured; set __NASBACKUP_SCHEDULE in the config"
        return $__NASBACKUP_EXIT_CODE_SCHEDULING_ERROR
    fi

    if [[ "$OSTYPE" == darwin* ]]; then
        __nasbackup_launchd_enable || return $__NASBACKUP_EXIT_CODE_SCHEDULING_ERROR
    else
        __nasbackup_cron enable || return $__NASBACKUP_EXIT_CODE_SCHEDULING_ERROR
    fi
}

__nasbackup_disable() {
    __nasbackup_ensure_config || return $__NASBACKUP_EXIT_CODE_CONFIG_ERROR

    if [[ "$OSTYPE" == darwin* ]]; then
        __nasbackup_launchd_disable || return $__NASBACKUP_EXIT_CODE_SCHEDULING_ERROR
    else
        __nasbackup_cron disable || return $__NASBACKUP_EXIT_CODE_SCHEDULING_ERROR
    fi
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

__nasbackup_main() {
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
            return $__NASBACKUP_EXIT_CODE_GENERIC_ERROR
            ;;
    esac
}

if [[ "$ZSH_EVAL_CONTEXT" == "toplevel" ]]; then
    __nasbackup_main "$@"
fi
