#!/bin/sh
#
# rman_backup.sh - RMAN backup wrapper (POSIX compatible)
#
# Usage:
#   rman_backup.sh -i <INSTANCE_NAME> -t <BACKUP_TYPE> [-c <CONFIG_FILE>] [-n] [-h]
#
#   -i <INSTANCE_NAME>   Required. Instance name/SID (must exist in ORATAB in config).
#   -t <BACKUP_TYPE>     Required. One of: L0, L1, Arch
#   -c <CONFIG_FILE>     Optional. Path to config file (defaults to /etc/rman_backup/rman_backup.conf or ./rman_backup.conf)
#   -n                   Dry-run: perform checks and print RMAN commands but do not run RMAN or delete anything.
#   -h                   Show this help and exit.
#
# Exit codes:
#   0   Success
#   1   Usage / configuration error
#   2   Instance not running
#   3   Database not PRIMARY
#   10  RMAN errors detected
#   20  Retention errors
#   100 Unexpected error
#
# Example cron (daily full at 02:30):
#   30 2 * * * /usr/local/bin/rman_backup.sh -i ORCL -t L0 -c /etc/rman_backup/rman_backup.conf
#
# Environment & security:
#   - The script uses OS authentication (connect target / as sysdba).
#   - Do NOT place credentials in this script. If you must use credentials, configure them securely and understand the security implications.
#
# Sample RMAN script blocks are printed by the script (for transparency).
#
# NOTE: This script aims to be POSIX / sh compatible. It uses "set -u" for safety and attempts "set -o pipefail" if supported.
#

# ---- safety and basic environment ----
# Enable unset variable detection
set -u

# Try set -o pipefail if supported (POSIX sh may not support it; ignore failure)
# shellcheck disable=SC3040
if (set -o 2>/dev/null | grep -q pipefail) 2>/dev/null; then
    # some shells support it
    set -o pipefail 2>/dev/null || true
fi

# Variables we'll populate
CONFIG_FILE=""
INSTANCE=""
BACKUP_TYPE=""
DRY_RUN=0

# Standardized exit function
_exit() {
    code=$1
    shift || true
    if [ "$code" -ne 0 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: $*" >&2
    fi
    exit "$code"
}

usage() {
    cat <<EOF
Usage: $0 -i <INSTANCE_NAME> -t <BACKUP_TYPE> [-c <CONFIG_FILE>] [-n] [-h]
  -i INSTANCE_NAME   : Oracle SID/instance (must exist in ORATAB)
  -t BACKUP_TYPE     : One of L0, L1, Arch
  -c CONFIG_FILE     : Optional config path. Default: /etc/rman_backup/rman_backup.conf or ./rman_backup.conf
  -n                 : Dry-run (do checks and print RMAN script; do not run RMAN or delete)
  -h                 : Help
EOF
}

# ---- parse args ----
while [ $# -gt 0 ]; do
    case "$1" in
        -i) shift; INSTANCE=${1:-}; shift;;
        -t) shift; BACKUP_TYPE=${1:-}; shift;;
        -c) shift; CONFIG_FILE=${1:-}; shift;;
        -n) DRY_RUN=1; shift;;
        -h) usage; exit 0;;
        --) shift; break;;
        -*) echo "Unknown option: $1"; usage; exit 1;;
        *) break;;
    esac
done

# Basic validation of mandatory args
if [ -z "${INSTANCE:-}" ] || [ -z "${BACKUP_TYPE:-}" ]; then
    echo "Missing required arguments." >&2
    usage
    _exit 1 "Missing required arguments"
fi

# Validate backup type
case "$BACKUP_TYPE" in
    L0|L1|Arch) ;;
    *) echo "BACKUP_TYPE must be one of: L0, L1, Arch" >&2; _exit 1 "Invalid BACKUP_TYPE: $BACKUP_TYPE";;
esac

# If config file not provided, try system then local
if [ -z "${CONFIG_FILE:-}" ]; then
    if [ -f /etc/rman_backup/rman_backup.conf ]; then
        CONFIG_FILE=/etc/rman_backup/rman_backup.conf
    elif [ -f ./rman_backup.conf ]; then
        CONFIG_FILE=./rman_backup.conf
    else
        echo "Config file not found in /etc/rman_backup/rman_backup.conf or ./rman_backup.conf" >&2
        _exit 1 "Config file missing"
    fi
fi

# Source config (safely)
if [ ! -f "$CONFIG_FILE" ]; then
    _exit 1 "Config file $CONFIG_FILE does not exist"
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE" || _exit 1 "Failed to source config $CONFIG_FILE"

# Provide sensible defaults if some entries missing (do not overwrite explicitly set ones)
: "${BASE_DIR:=/backup/rman}"
: "${BACKUP_L0_DIR:=${BASE_DIR}/L0}"
: "${BACKUP_L1_DIR:=${BASE_DIR}/L1}"
: "${BACKUP_ARCH_DIR:=${BASE_DIR}/Arch}"
: "${BACKUP_FORMAT_L0:='%d_%t_L0_%s'}"
: "${BACKUP_FORMAT_L1:='%d_%t_L1_%s'}"
: "${BACKUP_FORMAT_ARCH:='%d_%t_ARCH_%s'}"
: "${CHANNELS:=3}"
: "${CHANNEL_MAXSIZE:=100G}"
: "${RETENTION_DAYS:=3}"
: "${ORATAB:=/etc/oratab}"
: "${LOG_DIR:=${BASE_DIR}/logs}"
: "${RMAN_BINARY:=/usr/bin/rman}"
: "${COMPRESS:=N}"
: "${SPFILE_BACKUP:=Y}"
: "${ADDITIONAL_RMAN_OPTIONS:=''}"
: "${SQLPLUS_BINARY:=/usr/bin/sqlplus}"
: "${PID_DIR:=${LOG_DIR}/pids}"
: "${NOTIFY_RECIPIENT:=}"

# Paths expansion: ensure absolute LOG_DIR etc.
# Create directories if needed
mkdir -p "$LOG_DIR" || _exit 1 "Cannot create LOG_DIR $LOG_DIR"
mkdir -p "$PID_DIR" || _exit 1 "Cannot create PID_DIR $PID_DIR"

# Timestamp helpers
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_DIRNAME=$(date +%d-%b-%Y)

# Compose per-type directories
case "$BACKUP_TYPE" in
    L0) TARGET_DIR=${BACKUP_L0_DIR%/}/$DATE_DIRNAME ;;
    L1) TARGET_DIR=${BACKUP_L1_DIR%/}/$DATE_DIRNAME ;;
    Arch) TARGET_DIR=${BACKUP_ARCH_DIR%/}/$DATE_DIRNAME ;;
esac

# Logging files
MASTER_ACTIVITY_LOG=${LOG_DIR%/}/activity.log
MAIN_LOG=${LOG_DIR%/}/${INSTANCE}_${BACKUP_TYPE}_${TIMESTAMP}.log
ERROR_LOG=${LOG_DIR%/}/${INSTANCE}_${BACKUP_TYPE}_${TIMESTAMP}.err.log
RETENTION_LOG=${LOG_DIR%/}/retention_${INSTANCE}_${TIMESTAMP}.log
RETENTION_ERR_LOG=${LOG_DIR%/}/retention_${INSTANCE}_${TIMESTAMP}.err.log
PID_FILE=${PID_DIR%/}/${INSTANCE}_${BACKUP_TYPE}.pid

# Simple logging functions
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') INFO: $*" | tee -a "$MASTER_ACTIVITY_LOG" >>"$MAIN_LOG"
}
log_only() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') INFO: $*" >>"$MASTER_ACTIVITY_LOG"
}
err() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: $*" | tee -a "$ERROR_LOG" >>"$MASTER_ACTIVITY_LOG"
}

# PID lock to avoid concurrent runs for same instance/type
if [ -f "$PID_FILE" ]; then
    oldpid=$(sed -n '1p' "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        err "Another run (PID $oldpid) is active for $INSTANCE $BACKUP_TYPE. Exiting."
        _exit 1 "Concurrent run"
    else
        # stale pid file; remove
        rm -f "$PID_FILE" 2>/dev/null || true
    fi
fi
echo "$$" > "$PID_FILE" || _exit 1 "Cannot write PID file $PID_FILE"

# Ensure we remove PID file on exit
_cleanup() {
    rc=$?
    [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
    exit "$rc"
}
trap _cleanup INT TERM EXIT

# Create target and date directories safely
mkdir -p "$TARGET_DIR" || _exit 1 "Cannot create target directory $TARGET_DIR"
chmod 750 "$TARGET_DIR" 2>/dev/null || true

# Basic binary availability checks
if [ "$DRY_RUN" -eq 0 ]; then
    if [ ! -x "${RMAN_BINARY}" ]; then
        err "RMAN binary not found or not executable at $RMAN_BINARY"
        _exit 1 "RMAN not found"
    fi
fi

# ---- helper functions ----

# Parse and validate sizes like 100G, 500M, 1024K
# Output normalized value with unit uppercase (e.g., 100G)
normalize_size() {
    input="$1"
    # Allow digits and optional unit
    case "$input" in
        ''|*[!0-9a-zA-Z]*) echo "" ;; # invalid
        *) ;;
    esac
    # split number and unit
    num=$(echo "$input" | sed -E 's/([0-9]+).*/\1/')
    unit=$(echo "$input" | sed -E 's/[0-9]*([a-zA-Z]*)/\1/' | tr '[:lower:]' '[:upper:]')
    if [ -z "$num" ]; then
        echo ""
        return
    fi
    if [ -z "$unit" ]; then
        # Default to G if no unit provided
        unit=G
    fi
    case "$unit" in
        G|M|K) echo "${num}${unit}" ;;
        *) echo "" ;;
    esac
}

# Convert size to bytes (integer) for comparison (supports K, M, G)
size_to_bytes() {
    input=$(normalize_size "$1") || true
    case "$input" in
        *G) n=$(echo "$input" | sed -E 's/G$//'); awk "BEGIN{printf(\"%.0f\", $n * 1073741824)}" ;;
        *M) n=$(echo "$input" | sed -E 's/M$//'); awk "BEGIN{printf(\"%.0f\", $n * 1048576)}" ;;
        *K) n=$(echo "$input" | sed -E 's/K$//'); awk "BEGIN{printf(\"%.0f\", $n * 1024)}" ;;
        *) echo 0 ;;
    esac
}

# Build RMAN channel allocation commands given CHANNELS and CHANNEL_MAXSIZE
build_channel_allocs() {
    ch="$1"
    ch_max="$2"
    ch_max_norm=$(normalize_size "$ch_max")
    if [ -z "$ch_max_norm" ]; then
        ch_max_norm="100G"
    fi
    # Cap channel size at 1T to avoid runaway config
    cap_bytes=$(size_to_bytes "1024G")
    requested_bytes=$(size_to_bytes "$ch_max_norm")
    if [ "$requested_bytes" -gt "$cap_bytes" ]; then
        ch_max_norm="1024G"
    fi

    idx=1
    allocs=""
    while [ "$idx" -le "$ch" ]; do
        # RMAN uses MAXPIECESIZE for channels; some versions accept MAXSIZE on channel
        allocs="$allocs
allocate channel c${idx} type disk maxpiecesize $ch_max_norm;"
        idx=$((idx + 1))
    done
    echo "$allocs"
}

# Query ORATAB to find ORACLE_HOME & DB name (simple parsing)
get_dbname_from_oratab() {
    sid="$1"
    oratab_file="$2"
    if [ ! -f "$oratab_file" ]; then
        echo ""
        return
    fi
    # oratab format: <SID>:<ORACLE_HOME>:<Y|N>
    # support BSD/Linux differences (skip comment lines)
    entry=$(grep -v '^\s*#' "$oratab_file" | grep -E "^${sid}:" | head -n1 || true)
    if [ -z "$entry" ]; then
        echo ""
        return
    fi
    # Get SID portion before first colon
    echo "$sid"
}

# Check if instance exists in oratab
instance_in_oratab() {
    sid="$1"
    oratab_file="$2"
    if [ ! -f "$oratab_file" ]; then
        return 1
    fi
    grep -v '^\s*#' "$oratab_file" | grep -E "^${sid}:" >/dev/null 2>&1
}

# Check if instance is running (tries multiple strategies)
check_instance_running() {
    sid="$1"
    # 1) pmon process (portable)
    if ps -ef 2>/dev/null | grep -v grep | grep -E "ora_pmon_${sid}\b" >/dev/null 2>&1; then
        return 0
    fi
    # 2) pgrep if available
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -f "ora_pmon_${sid}" >/dev/null 2>&1; then
            return 0
        fi
    fi
    # 3) srvctl (for RAC) if available
    if command -v srvctl >/dev/null 2>&1; then
        if srvctl status database -d "$sid" 2>/dev/null | grep -i 'instance running\|starting\|running' >/dev/null 2>&1; then
            return 0
        fi
    fi
    # 4) Try minimal sqlplus connect (silent)
    if command -v "$SQLPLUS_BINARY" >/dev/null 2>&1; then
        # attempt connection as / as sysdba (may fail if not allowed)
        out=$("$SQLPLUS_BINARY" -s / as sysdba <<SQL 2>/dev/null
set heading off feedback off pagesize 0 verify off echo off
select 1 from v\$instance;
exit;
SQL
) || true
        case "$out" in
            *1*) return 0 ;;
        esac
    fi
    return 1
}

# Check DB role is PRIMARY by connecting via sqlplus
check_db_primary() {
    # minimal query to v$database.database_role
    if ! command -v "$SQLPLUS_BINARY" >/dev/null 2>&1; then
        err "sqlplus ($SQLPLUS_BINARY) not found; cannot verify database role."
        return 2
    fi
    role=$("$SQLPLUS_BINARY" -s / as sysdba <<SQL 2>/dev/null
set heading off feedback off pagesize 0 verify off echo off
select upper(database_role) from v\$database;
exit;
SQL
) || true
    # trim whitespace
    role=$(echo "$role" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if [ "$role" = "PRIMARY" ]; then
        return 0
    fi
    return 1
}

# RMAN error mapping (not exhaustive). Map common codes to human messages.
rman_error_map() {
    code="$1"
    case "$code" in
        RMAN-00571) echo "RMAN-00571: error encountered during RMAN operation (common: cannot open file, configuration issue)";;
        RMAN-03009) echo "RMAN-03009: failure during backup or restore (generic RMAN failure)";;
        ORA-19511) echo "ORA-19511: error on backup write (device/file I/O error, tape full, or file system issue)";;
        ORA-27037) echo "ORA-27037: unable to obtain file status (I/O or file permission problem)";;
        RMAN-03002) echo "RMAN-03002: failure in piece creation or channel problem";;
        RMAN-06002) echo "RMAN-06002: block corrupt or I/O error during backup";;
        ORA-31693) echo "ORA-31693: incremental backup failed (common with L1)";;
        *) echo "Unknown error code: $code";;
    esac
}

# Scan RMAN log for known patterns and produce summary in ERROR_LOG
scan_rman_log_for_errors() {
    logfile="$1"
    errfile="$2"
    # Important patterns
    grep -E 'RMAN-|ORA-|FATAL|ERROR|ALERT' "$logfile" > "${logfile}.matches" 2>/dev/null || true

    # Count total matches
    total_matches=$(wc -l < "${logfile}.matches" 2>/dev/null || echo 0)
    if [ "$total_matches" -eq 0 ]; then
        printf "%s\n" "$(date +'%Y-%m-%d %H:%M:%S') No RMAN/ORA/FATAL/ERROR/ALERT lines found in $logfile" >>"$errfile"
        return 0
    fi

    printf "%s\n" "Summary of matches ($total_matches) in $logfile:" >>"$errfile"
    # For each unique code (RMAN-xxxxx or ORA-#####)
    # Extract patterns RMAN-xxxxx and ORA-##### and show count, first occurrence, mapped message
    for code in $(grep -oE 'RMAN-[0-9]+' "${logfile}.matches" | sort -u 2>/dev/null || true) $(grep -oE 'ORA-[0-9]+' "${logfile}.matches" | sort -u 2>/dev/null || true); do
        [ -z "$code" ] && continue
        cnt=$(grep -c "$code" "${logfile}.matches" || echo 0)
        first=$(grep -m1 "$code" "${logfile}.matches" || echo "")
        mapped=$(rman_error_map "$code")
        printf "\nCode: %s\nCount: %s\nFirst: %s\nMeaning: %s\n" "$code" "$cnt" "$first" "$mapped" >>"$errfile"
    done

    # Also capture lines that contain ERROR or FATAL but no code
    grep -iE 'FATAL|ERROR|ALERT' "${logfile}.matches" | grep -vE 'RMAN-|ORA-' | sort -u >>"$errfile" 2>/dev/null || true

    # produce a short summary for exit decision
    # treat RMAN- or ORA- lines as critical
    critical_count=$(grep -E 'RMAN-|ORA-' "${logfile}.matches" | wc -l 2>/dev/null || echo 0)
    printf "\nTotal critical error lines: %s\n" "$critical_count" >>"$errfile"
    # Return number of critical lines as exit status (capped)
    if [ "$critical_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# Send notification stub: operator may integrate with mail/monitor
notify_stub() {
    subject="$1"
    body="$2"
    # Stub: log the intended notification; integration point for mailx/sendmail/sns
    echo "NOTIFY: To=${NOTIFY_RECIPIENT:-<not-configured>} Subject=${subject}" >>"$MAIN_LOG"
    # Example (commented):
    # echo "$body" | mailx -s "$subject" "$NOTIFY_RECIPIENT"
}

# ---- validations ----

# Validate INSTANCE exists in oratab
if ! instance_in_oratab "$INSTANCE" "$ORATAB"; then
    err "Instance $INSTANCE not found in ORATAB ($ORATAB)"
    _exit 1 "Instance not found in oratab"
fi

# Check instance running
if ! check_instance_running "$INSTANCE"; then
    err "Instance $INSTANCE does not appear to be running."
    _exit 2 "Instance not running"
fi
log "Instance $INSTANCE is running."

# Check DB role PRIMARY (unless Arch-only case you may still want to ensure PRIMARY)
if ! check_db_primary; then
    err "Database role is not PRIMARY for $INSTANCE; aborting."
    _exit 3 "Not primary"
fi
log "Database role is PRIMARY."

# Build channel allocations for RMAN
CHANNEL_ALLOCS=$(build_channel_allocs "$CHANNELS" "$CHANNEL_MAXSIZE")

# Determine DB_NAME (use INSTANCE by default; user may map differently)
DB_NAME=$(get_dbname_from_oratab "$INSTANCE" "$ORATAB")
if [ -z "$DB_NAME" ]; then
    DB_NAME="$INSTANCE"
fi

# Generate sequence number for file names (basic increment based on timestamp)
BACKUP_SEQ=1

# Build backup filename using configured format and placeholders
timestamp_for_name=$(date +%Y%m%d_%H%M%S)
format_to_use=""
case "$BACKUP_TYPE" in
    L0) format_to_use=$BACKUP_FORMAT_L0 ;;
    L1) format_to_use=$BACKUP_FORMAT_L1 ;;
    Arch) format_to_use=$BACKUP_FORMAT_ARCH ;;
esac

# Replace placeholders: %d %t %s %i
build_filename() {
    fmt="$1"
    seq="$2"
    name="$fmt"
    name=$(printf "%s" "$name" | sed "s/%d/$DB_NAME/g" )
    name=$(printf "%s" "$name" | sed "s/%t/$timestamp_for_name/g" )
    name=$(printf "%s" "$name" | sed "s/%s/$seq/g" )
    name=$(printf "%s" "$name" | sed "s/%i/$INSTANCE/g" )
    printf "%s" "$name"
}

BACKUP_FILENAME=$(build_filename "$format_to_use" "$BACKUP_SEQ")

# Create RMAN script in temp
RMAN_SCRIPT_FILE=$(mktemp "/tmp/rman_${INSTANCE}_${BACKUP_TYPE}_XXXX.sql") || _exit 100 "Cannot create temp RMAN script"

# Compose RMAN commands based on type
# We'll use channel allocations built earlier and output backups to TARGET_DIR with specified format.
# For compression we use "set compression" for RMAN versions that support it and "as compressed backupset"
compress_flag=""
if [ "$(echo "$COMPRESS" | tr '[:lower:]' '[:upper:]')" = "Y" ]; then
    compress_flag="COMPRESSED"
fi

# Construct ARCHIVE target directory (always ensure it exists)
ARCHIVE_TARGET_DIR=${BACKUP_ARCH_DIR%/}/$DATE_DIRNAME
mkdir -p "$ARCHIVE_TARGET_DIR" || _exit 1 "Cannot create archive dir $ARCHIVE_TARGET_DIR"

# Compose RMAN script body
cat > "$RMAN_SCRIPT_FILE" <<-'RMANEOF'
# RMAN script generated by rman_backup.sh - DO NOT EDIT directly
# (This is a temporary file printed for transparency)
run {
RMANEOF

# Append channel allocations
printf "%s\n" "$CHANNEL_ALLOCS" >>"$RMAN_SCRIPT_FILE"

# For each backup type, append appropriate RMAN commands (note: use HERE-doc append)
if [ "$BACKUP_TYPE" = "L0" ] || [ "$BACKUP_TYPE" = "L1" ]; then
    # datafile backup
    if [ "$compress_flag" = "COMPRESSED" ]; then
        echo "backup as compressed backupset format '${TARGET_DIR}/${BACKUP_FILENAME}_%U' tag='${BACKUP_TYPE}_${TIMESTAMP}' database;" >>"$RMAN_SCRIPT_FILE"
    else
        echo "backup as backupset format '${TARGET_DIR}/${BACKUP_FILENAME}_%U' tag='${BACKUP_TYPE}_${TIMESTAMP}' database;" >>"$RMAN_SCRIPT_FILE"
    fi

    # controlfile and possibly SPFILE
    echo "sql 'alter system archive log current';" >>"$RMAN_SCRIPT_FILE"
    echo "backup current controlfile format '${TARGET_DIR}/${DB_NAME}_control_${TIMESTAMP}.ctl';" >>"$RMAN_SCRIPT_FILE"
    if [ "$(echo "$SPFILE_BACKUP" | tr '[:lower:]' '[:upper:]')" = "Y" ]; then
        echo "backup spfile format '${TARGET_DIR}/${DB_NAME}_spfile_${TIMESTAMP}.spb';" >>"$RMAN_SCRIPT_FILE"
    fi

    # Archive logs backup
    echo "backup as backupset archivelog all format '${ARCHIVE_TARGET_DIR}/${BACKUP_FILENAME}_arch_%U' delete input;" >>"$RMAN_SCRIPT_FILE"

elif [ "$BACKUP_TYPE" = "Arch" ]; then
    # Only archive logs
    echo "backup as backupset archivelog all format '${ARCHIVE_TARGET_DIR}/${BACKUP_FILENAME}_arch_%U' delete input;" >>"$RMAN_SCRIPT_FILE"
fi

# Append additional options if any
if [ -n "${ADDITIONAL_RMAN_OPTIONS:-}" ]; then
    echo "${ADDITIONAL_RMAN_OPTIONS}" >>"$RMAN_SCRIPT_FILE"
fi

# Close run block
cat >> "$RMAN_SCRIPT_FILE" <<'RMANEOF'
}
exit
RMANEOF

# Print RMAN script for dry-run or logging
log "Generated RMAN script: $RMAN_SCRIPT_FILE"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "---- DRY RUN: RMAN script preview ----"
    sed -n '1,200p' "$RMAN_SCRIPT_FILE"
    echo "---- END RMAN script preview ----"
    echo "Dry-run mode: skipping execution of RMAN and retention steps."
    _cleanup
fi

# Run RMAN and capture logs
log "Running RMAN backup for ${INSTANCE} type ${BACKUP_TYPE}..."
# Note: We rely on RMAN to run using OS authentication
"${RMAN_BINARY}" target / @"$RMAN_SCRIPT_FILE" >"$MAIN_LOG" 2>&1 || rman_rc=$?
rman_rc=${rman_rc:-$?}
if [ "${rman_rc:-0}" -ne 0 ]; then
    err "RMAN exited with code ${rman_rc}"
fi

# Scan RMAN log for errors and create error log
scan_rman_log_for_errors "$MAIN_LOG" "$ERROR_LOG"
scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
    err "Errors detected in RMAN log. Refer to $ERROR_LOG"
    notify_stub "RMAN backup error for $INSTANCE $BACKUP_TYPE" "See $ERROR_LOG and $MAIN_LOG"
    _exit 10 "RMAN errors detected"
fi

log "RMAN completed without critical errors."

# ---- Retention and cleanup ----
# Only run retention if there were no critical errors in backup
log "Starting retention reporting and deletion (RETENTION_DAYS=${RETENTION_DAYS})"

# Create retention RMAN script file
RETENTION_SCRIPT=$(mktemp "/tmp/rman_retention_${INSTANCE}_XXXX.sql") || _exit 100 "Cannot create retention script file"
cat > "$RETENTION_SCRIPT" <<-'RETO'
# RMAN retention script - generated by rman_backup.sh
report obsolete;
RETO

# Run report obsolete and capture output
"${RMAN_BINARY}" target / @"$RETENTION_SCRIPT" >"$RETENTION_LOG" 2>&1 || ret_report_rc=$?
ret_report_rc=${ret_report_rc:-$?}
if [ "${ret_report_rc:-0}" -ne 0 ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: report obsolete failed (rc=${ret_report_rc})" >>"$RETENTION_ERR_LOG"
    err "Retention: report obsolete failed; see $RETENTION_ERR_LOG and $RETENTION_LOG"
    _exit 20 "Retention report failed"
fi
log "report obsolete completed; now deleting obsolete backups (delete noprompt obsolete)."

# Now delete noprompt obsolete
RET_DELETE_SCRIPT=$(mktemp "/tmp/rman_retention_delete_${INSTANCE}_XXXX.sql") || _exit 100 "Cannot create retention delete script"
cat > "$RET_DELETE_SCRIPT" <<-'RETD'
# RMAN retention delete script
delete noprompt obsolete;
RETD

"${RMAN_BINARY}" target / @"$RET_DELETE_SCRIPT" >>"$RETENTION_LOG" 2>>"$RETENTION_ERR_LOG" || ret_delete_rc=$?
ret_delete_rc=${ret_delete_rc:-$?}
if [ "${ret_delete_rc:-0}" -ne 0 ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: delete noprompt obsolete failed (rc=${ret_delete_rc})" >>"$RETENTION_ERR_LOG"
    err "Retention delete failed; see $RETENTION_ERR_LOG and $RETENTION_LOG"
    notify_stub "Retention error for $INSTANCE" "See $RETENTION_ERR_LOG"
    _exit 20 "Retention delete failed"
fi

log "Retention completed successfully."

# Final successful log
echo "$(date +'%Y-%m-%d %H:%M:%S') SUCCESS: Backup ${BACKUP_TYPE} for ${INSTANCE} completed successfully." >>"$MASTER_ACTIVITY_LOG"
notify_stub "RMAN backup successful for $INSTANCE $BACKUP_TYPE" "Backup logs: $MAIN_LOG; errors (if any): $ERROR_LOG"

# Clean up temp RMAN scripts
rm -f "$RMAN_SCRIPT_FILE" "$RETENTION_SCRIPT" "$RET_DELETE_SCRIPT" 2>/dev/null || true

# Exit cleanly
_cleanup
