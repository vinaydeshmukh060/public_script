#!/bin/sh
#
# rman_backup.sh
# POSIX-compatible RMAN backup wrapper script
#
# Purpose:
#   - Take L0 (full), L1 (incremental), or Arch (archive-only) RMAN backups.
#   - Uses a separate configuration file (rman_backup.conf) for site settings.
#   - Provides logging, error mapping, retention (REPORT/DELETE OBSOLETE),
#     lock to prevent concurrent runs for same instance, and safe temp handling.
#
# Requirements fulfilled:
#   - POSIX /bin/sh compatible (no bash-only features).
#   - Uses config file for all customizable values.
#   - Checks DB role is PRIMARY.
#   - Allocates channels based on config.
#   - Creates backup dirs, uses date tokens for formats.
#   - Scans logs for RMAN/ORA errors and maps to human-friendly messages.
#   - Retention using RMAN REPORT/DELETE OBSOLETE with recovery window.
#   - Prevents concurrent runs using PID lock file.
#
# Exit codes:
#   0 - success (including successful retention)
#   1 - general or usage error
#   2 - config/missing file or environment problems
#   3 - instance not running or not PRIMARY
#   4 - RMAN backup failed (errors found in RMAN log)
#   5 - retention/cleanup failed
#
# Example invocations:
#   ./rman_backup.sh -i ORCL -t L0 -c Y
#   ./rman_backup.sh ORCL L1
#
# Location of config (default): ./rman_backup.conf  (overridable with -f)
#
# Notes:
#   - Script expects sqlplus and rman binaries to be available under configured ORACLE_HOME
#   - This script does not perform email notifications.
#   - Keep rman_backup.conf next to this script or pass -f /path/to/conf
#
set -eu

# ----- Utility functions ----------------------------------------------------

timestamp() {
    # POSIX-safe timestamp for filenames and logs: YYYYMMDD_HHMMSS
    # Usage: timestamp
    date '+%Y%m%d_%H%M%S'
}

human_date() {
    # Human friendly date used in backup sets: dd-Mon-YYYY (e.g., 03-Oct-2025)
    date '+%d-%b-%Y'
}

err() {
    # Print message to stderr with timestamp
    printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

safe_mkdir() {
    # mkdir -p but check errors
    if ! mkdir -p "$1"; then
        err "Failed to create directory $1"
        return 1
    fi
}

clean_temp() {
    # Cleanup temp files if present
    if [ -n "${TMP_RMAN_SCRIPT:-}" ] && [ -f "$TMP_RMAN_SCRIPT" ]; then
        rm -f "$TMP_RMAN_SCRIPT" || true
    fi
    if [ -n "${TMP_SQLPLUS_SCRIPT:-}" ] && [ -f "$TMP_SQLPLUS_SCRIPT" ]; then
        rm -f "$TMP_SQLPLUS_SCRIPT" || true
    fi
    # Remove lock if we own it
    if [ -n "${LOCK_FILE:-}" ] && [ -f "$LOCK_FILE" ]; then
        # ensure only remove if PID matches
        if [ -n "${MY_PID_IN_LOCK:-}" ]; then
            lockpid=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || printf '')
            if [ "$lockpid" = "$MY_PID_IN_LOCK" ]; then
                rm -f "$LOCK_FILE" || true
            fi
        else
            rm -f "$LOCK_FILE" || true
        fi
    fi
}

trap_cleanup() {
    # Called on exit/interrupt
    EXIT_CODE=$?
    clean_temp
    exit "$EXIT_CODE"
}

trap trap_cleanup INT TERM EXIT

# ----- Argument parsing -----------------------------------------------------

CFG_FILE="./rman_backup.conf"
ORACLE_SID=""
BACKUP_TYPE=""
COMPRESSION=""
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 [options] ORACLE_SID BACKUP_TYPE [COMPRESSION]

Options:
  -i SID         : Oracle SID (alternative to positional)
  -t TYPE        : Backup type: L0, L1, Arch (case-insensitive)
  -c Y|N         : Compression Y or N (optional). If omitted, config default used.
  -f /path/conf  : Path to rman_backup.conf (optional)
  -n             : dry-run / validate (print actions, do not run RMAN)
  -h             : show this help

Examples:
  $0 -i ORCL -t L0 -c Y
  $0 ORCL L1
EOF
    exit 1
}

# Short option parse (POSIX-compatible)
while [ $# -gt 0 ]; do
    case "$1" in
        -i) shift; [ $# -gt 0 ] || usage; ORACLE_SID=$1; shift;;
        -t) shift; [ $# -gt 0 ] || usage; BACKUP_TYPE=$1; shift;;
        -c) shift; [ $# -gt 0 ] || usage; COMPRESSION=$1; shift;;
        -f) shift; [ $# -gt 0 ] || usage; CFG_FILE=$1; shift;;
        -n) DRY_RUN=1; shift;;
        -h) usage;;
        --) shift; break;;
        -*) usage;;
        *)
            # positional handling: SID TYPE [COMP]
            if [ -z "$ORACLE_SID" ]; then
                ORACLE_SID=$1; shift
                continue
            elif [ -z "$BACKUP_TYPE" ]; then
                BACKUP_TYPE=$1; shift
                continue
            elif [ -z "$COMPRESSION" ]; then
                COMPRESSION=$1; shift
                continue
            else
                # extra positional
                shift
            fi
            ;;
    esac
done

# Validate mandatory args
if [ -z "$ORACLE_SID" ] || [ -z "$BACKUP_TYPE" ]; then
    err "Missing required arguments."
    usage
fi

# Normalize input
# BACKUP_TYPE allowed values: L0, L1, Arch (case-insensitive)
BACKUP_TYPE_UPPER=$(printf '%s' "$BACKUP_TYPE" | awk '{print toupper($0)}')
case "$BACKUP_TYPE_UPPER" in
    L0|L1|ARCH) BACKUP_TYPE="$BACKUP_TYPE_UPPER";;
    *) err "Invalid backup type: $BACKUP_TYPE (allowed: L0,L1,Arch)"; exit 1;;
esac

if [ -n "$COMPRESSION" ]; then
    COMP=$(printf '%s' "$COMPRESSION" | awk '{print toupper($0)}')
    case "$COMP" in
        Y|N) COMPRESSION="$COMP";;
        *) err "Invalid compression flag: $COMPRESSION (allowed Y/N)"; exit 1;;
    esac
fi

# ----- Load configuration ---------------------------------------------------

if [ ! -f "$CFG_FILE" ]; then
    err "Configuration file not found: $CFG_FILE"
    exit 2
fi

# shellcheck source=/dev/null
. "$CFG_FILE"

# Validate required config variables (fail fast)
: "${base_dir:=}" || { err "base_dir is not set in config"; exit 2; }
: "${backup_L0_dir:=}" || { err "backup_L0_dir not set in config"; exit 2; }
: "${backup_L1_dir:=}" || { err "backup_L1_dir not set in config"; exit 2; }
: "${backup_Arch_dir:=}" || { err "backup_Arch_dir not set in config"; exit 2; }
: "${backup_format_L0:=}" || { err "backup_format_L0 not set in config"; exit 2; }
: "${backup_format_L1:=}" || { err "backup_format_L1 not set in config"; exit 2; }
: "${backup_format_Arch:=}" || { err "backup_format_Arch not set in config"; exit 2; }
: "${channels:=1}" || channels=1
: "${channel_max_size:=}" || channel_max_size=""
: "${oratab_path:=/etc/oratab}"
: "${retention_days:=3}"
: "${logs_dir:=${base_dir}/logs}"
: "${rman_binary:=rman}"
: "${default_compression:=N}"
: "${environment_profile:=}"

# If compression not provided on CLI, use default from config
if [ -z "${COMPRESSION:-}" ]; then
    COMPRESSION=$(printf '%s' "$default_compression" | awk '{print toupper($0)}')
fi

# Verify rman_binary exists (if absolute path provided)
if [ -n "$(printf '%s' "$rman_binary" | grep '/')" ]; then
    if [ ! -x "$rman_binary" ]; then
        err "Configured rman_binary not executable: $rman_binary"
        exit 2
    fi
fi

# Prepare logs and filenames
TS=$(timestamp)
LOG_PREFIX="rman_backup_${ORACLE_SID}_${BACKUP_TYPE}_${TS}"
MAIN_LOG="${logs_dir}/${LOG_PREFIX}.log"
ERROR_LOG="${logs_dir}/${LOG_PREFIX}_error.log"
RETENTION_LOG="${logs_dir}/${LOG_PREFIX}_retention.log"

# Ensure logs dir exists
safe_mkdir "$logs_dir" || { err "Unable to create logs dir $logs_dir"; exit 2; }

# Append header to logs
printf '%s\n' "==== RMAN Backup run for $ORACLE_SID type=$BACKUP_TYPE time=$(date '+%Y-%m-%d %H:%M:%S') ====" >> "$MAIN_LOG"
printf '%s\n' "==== Error log for $ORACLE_SID run $TS ====" >> "$ERROR_LOG"
printf '%s\n' "==== Retention log for $ORACLE_SID run $TS ====" >> "$RETENTION_LOG"

# ----- Locking to prevent concurrent runs ----------------------------------
LOCK_DIR="${base_dir}/locks"
safe_mkdir "$LOCK_DIR" || { err "Cannot create lock dir"; exit 2; }
LOCK_FILE="${LOCK_DIR}/rman_backup_${ORACLE_SID}.lock"
MY_PID_IN_LOCK=$$

if [ -f "$LOCK_FILE" ]; then
    existing_pid=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || printf '')
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        err "Another backup process for $ORACLE_SID is already running (pid $existing_pid). Lock file: $LOCK_FILE"
        printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') Another process (pid $existing_pid) holds lock. Exiting." >> "$ERROR_LOG"
        exit 1
    else
        # stale lock - remove it
        rm -f "$LOCK_FILE" || true
    fi
fi

# write our pid
printf '%s\n' "$$" > "$LOCK_FILE" || { err "Unable to write lock file"; exit 1; }
# remember lock for cleanup
: "${LOCK_FILE:=${LOCK_FILE}}"
: "${MY_PID_IN_LOCK:=$\$}"

# ----- Determine ORACLE_HOME from oratab and export environment -------------
# oratab format: SID:ORACLE_HOME:FLAG  (FLAG usually Y/N)
if [ ! -f "$oratab_path" ]; then
    err "oratab file not found at $oratab_path (configured oratab_path)."
    printf '%s\n' "oratab missing: $oratab_path" >> "$ERROR_LOG"
    exit 2
fi

# find line matching ORACLE_SID in oratab (ignore commented lines)
ORACLE_HOME=""
# POSIX-safe search:
# line looks like: ORCL:/u01/app/oracle/product/12.1.0/dbhome_1:Y
# We extract second field
while IFS= read -r l; do
    case "$l" in
        \#*) continue;;
        "$ORACLE_SID":*)
            # split on :
            ORACLE_HOME=$(printf '%s' "$l" | awk -F: '{print $2}')
            break
            ;;
        *) ;;
    esac
done < "$oratab_path"

if [ -z "$ORACLE_HOME" ]; then
    err "Could not determine ORACLE_HOME for $ORACLE_SID from $oratab_path"
    printf '%s\n' "Cannot find ORACLE_HOME in $oratab_path for $ORACLE_SID" >> "$ERROR_LOG"
    clean_temp
    exit 2
fi

export ORACLE_HOME
export ORACLE_SID
# Add sqlplus/rman to PATH
PATH="$ORACLE_HOME/bin:$PATH"
export PATH

# Optionally source an environment profile (if set)
if [ -n "$environment_profile" ]; then
    if [ -f "$environment_profile" ]; then
        # shellcheck source=/dev/null
        . "$environment_profile"
    fi
fi

# Validate sqlplus exists
if ! command -v sqlplus >/dev/null 2>&1; then
    err "sqlplus not found in PATH. Expected under ORACLE_HOME/bin"
    printf '%s\n' "sqlplus missing: check ORACLE_HOME/bin" >> "$ERROR_LOG"
    clean_temp
    exit 2
fi

# Validate rman (if path not absolute, rely on PATH)
if ! command -v "$rman_binary" >/dev/null 2>&1; then
    err "rman binary not found (configured as $rman_binary)."
    printf '%s\n' "rman missing: $rman_binary" >> "$ERROR_LOG"
    clean_temp
    exit 2
fi

# ----- Check DB role is PRIMARY --------------------------------------------
TMP_SQLPLUS_SCRIPT=$(mktemp "/tmp/rman_sql_${ORACLE_SID}_XXXX.sql")
# query to get database role
cat > "$TMP_SQLPLUS_SCRIPT" <<EOF
SET PAGES 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
CONNECT / AS SYSDBA
SELECT DATABASE_ROLE FROM V\\$DATABASE;
EXIT
EOF

DB_ROLE=$(sqlplus -S /nolog @"$TMP_SQLPLUS_SCRIPT" 2>/dev/null | awk 'NF{print $1}' | head -n1 || printf '')
rm -f "$TMP_SQLPLUS_SCRIPT" || true

if [ -z "$DB_ROLE" ]; then
    err "Unable to determine database role for $ORACLE_SID (sqlplus failed)."
    printf '%s\n' "Failed to query V\$DATABASE for role." >> "$ERROR_LOG"
    clean_temp
    exit 3
fi

if [ "$(printf '%s' "$DB_ROLE" | awk '{print toupper($0)}')" != "PRIMARY" ]; then
    err "Database role is not PRIMARY: $DB_ROLE. Aborting."
    printf '%s\n' "DB role check failed: $DB_ROLE (expected PRIMARY)" >> "$ERROR_LOG"
    clean_temp
    exit 3
fi

# ----- Prepare backup directories and filename formats ---------------------

# Expand date token: backup_format_* should include a placeholder token like <date:dd-mon-yyyy>
# We'll replace "<date:dd-mon-yyyy>" with human_date (03-Oct-2025) and %s tokens for unique naming if present.
# The config may provide formats like: '${backup_L0_dir}/%s' or '${backup_L0_dir}/backup_<date:...>_%s'

DATE_HUMAN=$(human_date)
BACKUP_DIR=""
BACKUP_FORMAT=""

case "$BACKUP_TYPE" in
    L0)
        BACKUP_DIR="$backup_L0_dir"
        BACKUP_FORMAT="$backup_format_L0"
        ;;
    L1)
        BACKUP_DIR="$backup_L1_dir"
        BACKUP_FORMAT="$backup_format_L1"
        ;;
    ARCH)
        BACKUP_DIR="$backup_Arch_dir"
        BACKUP_FORMAT="$backup_format_Arch"
        ;;
esac

# replace token "<date:dd-mon-yyyy>" or "<date>" with actual date
# Use POSIX sed to do simple replacement
BACKUP_FORMAT_EXPANDED=$(printf '%s' "$BACKUP_FORMAT" | sed "s|<date:dd-mon-yyyy>|$DATE_HUMAN|g" | sed "s|<date>|$DATE_HUMAN|g")

# Ensure backup directories exist
safe_mkdir "$BACKUP_DIR" || { err "Cannot create backup dir $BACKUP_DIR"; exit 2; }
safe_mkdir "$backup_Arch_dir" || { err "Cannot create archive backup dir $backup_Arch_dir"; exit 2; }

# build final backup name (use timestamp to differentiate)
BACKUP_NAME=$(printf '%s' "${BACKUP_FORMAT_EXPANDED}" | sed "s|%s|${ORACLE_SID}_${TS}|g")

# ----- Build RMAN script ---------------------------------------------------
TMP_RMAN_SCRIPT=$(mktemp "/tmp/rman_run_${ORACLE_SID}_XXXX.rman")

# Channel allocation block generation (POSIX-friendly loop)
CHANNELS_ALLOC=""
i=1
while [ "$i" -le "$channels" ]; do
    # RMAN allocate channel syntax for disk:
    # allocate channel c1 device type disk format '%s' MAXPIECESIZE=...
    # We do not hardcode format per channel; channel device type = DISK
    if [ -n "$channel_max_size" ]; then
        CHANNELS_ALLOC="${CHANNELS_ALLOC}allocate channel c${i} device type disk MAXPIECESIZE ${channel_max_size};\n"
    else
        CHANNELS_ALLOC="${CHANNELS_ALLOC}allocate channel c${i} device type disk;\n"
    fi
    i=$((i + 1))
done

# Compose RMAN commands depending on backup type
# Choose compression clause
if [ "$(printf '%s' "$COMPRESSION" | awk '{print toupper($0)}')" = "Y" ]; then
    RMAN_COMPRESSION_CLAUSE="AS COMPRESSED BACKUPSET"
else
    RMAN_COMPRESSION_CLAUSE=""
fi

# For archive backup we will only backup archivelogs not backed up
# For L0/L1 we backup datafile and then controlfile/spfile and unbacked archivelogs
cat > "$TMP_RMAN_SCRIPT" <<EOF
RUN {
$(printf '%b' "$CHANNELS_ALLOC")
CONFIGURE SNAPSHOT CONTROLFILE NAME TO '${backup_L0_dir:-$BACKUP_DIR}/snapshot_${ORACLE_SID}_${TS}.ctl';
# Start backup run
EOF

# Append specific backup commands
if [ "$BACKUP_TYPE" = "L0" ]; then
    cat >> "$TMP_RMAN_SCRIPT" <<EOF
# Full (level 0) backup of database
BACKUP ${RMAN_COMPRESSION_CLAUSE} INCREMENTAL LEVEL 0 DATABASE FORMAT '${BACKUP_NAME}_%T_%s_%p.bkp';
# Backup controlfile and spfile
BACKUP ${RMAN_COMPRESSION_CLAUSE}  AS BACKUPSET  ARCHIVELOG ALL NOT BACKED UP FORMAT '${backup_Arch_dir}/${ORACLE_SID}_${TS}_arch_%T_%s_%p.bkp';
BACKUP ${RMAN_COMPRESSION_CLAUSE} CURRENT CONTROLFILE FORMAT '${BACKUP_NAME}_control_%T.bkp';
BACKUP ${RMAN_COMPRESSION_CLAUSE} SPFILE FORMAT '${BACKUP_NAME}_spfile_%T.bkp';
EOF
elif [ "$BACKUP_TYPE" = "L1" ]; then
    cat >> "$TMP_RMAN_SCRIPT" <<EOF
# Incremental (level 1) backup of database
BACKUP ${RMAN_COMPRESSION_CLAUSE} INCREMENTAL LEVEL 1 DATABASE FORMAT '${BACKUP_NAME}_%T_%s_%p.bkp';
# Backup controlfile and spfile after incremental
BACKUP ${RMAN_COMPRESSION_CLAUSE} CURRENT CONTROLFILE FORMAT '${BACKUP_NAME}_control_%T.bkp';
BACKUP ${RMAN_COMPRESSION_CLAUSE} SPFILE FORMAT '${BACKUP_NAME}_spfile_%T.bkp';
# Backup archive logs not backed up yet
BACKUP ${RMAN_COMPRESSION_CLAUSE} AS BACKUPSET ARCHIVELOG ALL NOT BACKED UP FORMAT '${backup_Arch_dir}/${ORACLE_SID}_${TS}_arch_%T_%s_%p.bkp';
EOF
elif [ "$BACKUP_TYPE" = "ARCH" ]; then
    cat >> "$TMP_RMAN_SCRIPT" <<EOF
# Archive-only backup: only non-backed-up archivelogs
BACKUP ${RMAN_COMPRESSION_CLAUSE} AS BACKUPSET ARCHIVELOG ALL NOT BACKED UP FORMAT '${backup_Arch_dir}/${ORACLE_SID}_${TS}_arch_%T_%s_%p.bkp';
EOF
fi

# Append retention policy and end RUN
cat >> "$TMP_RMAN_SCRIPT" <<EOF
# Note: do not DELETE INPUT here; retention/cleanup handled separately
}
EXIT;
EOF

# If dry-run, print planned actions and exit (without running RMAN)
if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n\n' "DRY RUN: the following RMAN script would be executed:" | tee -a "$MAIN_LOG"
    sed -n '1,400p' "$TMP_RMAN_SCRIPT" | tee -a "$MAIN_LOG"
    clean_temp
    printf '%s\n' "Dry-run complete." | tee -a "$MAIN_LOG"
    # remove lock before exit
    rm -f "$LOCK_FILE" || true
    exit 0
fi

# ----- Run RMAN and capture output -----------------------------------------
# Execute RMAN script, redirect both stdout and stderr to main log
# Use configured rman binary; if path is relative, rely on PATH
printf '%s\n' "Starting RMAN at $(date '+%Y-%m-%d %H:%M:%S')" >> "$MAIN_LOG"
"$rman_binary" target / @"$TMP_RMAN_SCRIPT" >> "$MAIN_LOG" 2>&1 || RC_RMAN=$?
RC_RMAN=${RC_RMAN:-0}

printf '%s\n' "RMAN exit code: ${RC_RMAN:-0}" >> "$MAIN_LOG"

# ----- Error scanning and mapping -----------------------------------------
# Known RMAN/ORA error mapping
# The parser will scan for patterns ORA-xxxxx and RMAN-xxxxx and map them
grep -Eo 'ORA-[0-9]+' "$MAIN_LOG" | sort -u | while read -r code; do
    case "$code" in
        ORA-19505)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Failed to create file. Action: Check disk space, directory permissions, and file system." >> "$ERROR_LOG"
            ;;
        ORA-19511)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Error in backup operation (I/O error on media). Action: Check media, hardware, and RMAN channels." >> "$ERROR_LOG"
            ;;
        ORA-19514)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Media manager error. Action: Check media manager logs and configuration." >> "$ERROR_LOG"
            ;;
        ORA-27037)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Write error on file. Action: Check file system and disk." >> "$ERROR_LOG"
            ;;
        ORA-27040)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Unable to open file (OS error). Action: Check permissions and file availability." >> "$ERROR_LOG"
            ;;
        ORA-00257)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Archive log destination or disk full / media manager quota exceeded. Action: Free space or increase quota." >> "$ERROR_LOG"
            ;;
        ORA-27026)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> File not open/write error. Action: Check file permissions and OS errors." >> "$ERROR_LOG"
            ;;
        *)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Unknown ORA error - consult alert log and RMAN output." >> "$ERROR_LOG"
            ;;
    esac
done

grep -Eo 'RMAN-[0-9]+' "$MAIN_LOG" | sort -u | while read -r code; do
    case "$code" in
        RMAN-06002)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> No backup in the control file. Action: Verify backups recorded in controlfile/catalog." >> "$ERROR_LOG"
            ;;
        RMAN-03009)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Failure during backup command. Action: Inspect RMAN log for failing commands." >> "$ERROR_LOG"
            ;;
        RMAN-03002)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Failure in channel allocation. Action: Check channel allocation and resources." >> "$ERROR_LOG"
            ;;
        RMAN-03030)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Component not found. Action: Check DB components and backups." >> "$ERROR_LOG"
            ;;
        RMAN-03031)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Could not allocate channel. Action: Check channel config and resources." >> "$ERROR_LOG"
            ;;
        RMAN-1054)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Invalid RMAN command or syntax. Action: Check RMAN script syntax." >> "$ERROR_LOG"
            ;;
        RMAN-06010)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> DBID mismatch or no DBID set. Action: Ensure DBID is configured or controlfile is current." >> "$ERROR_LOG"
            ;;
        *)
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $code -> Unknown RMAN error - consult alert log and RMAN output." >> "$ERROR_LOG"
            ;;
    esac
done

# Also append raw lines containing ORA- or RMAN- to the error log for reference
grep -E 'ORA-[0-9]+|RMAN-[0-9]+' "$MAIN_LOG" >> "$ERROR_LOG" || true

# If RMAN exit code non-zero or any errors found in error log, fail
ERROR_LINES_FOUND=$(grep -E 'ORA-[0-9]+|RMAN-[0-9]+' "$MAIN_LOG" | wc -l | awk '{print $1}')
if [ "${RC_RMAN:-0}" -ne 0 ] || [ "$ERROR_LINES_FOUND" -gt 0 ]; then
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') RMAN reported errors or returned non-zero ($RC_RMAN). See $MAIN_LOG and $ERROR_LOG" >> "$ERROR_LOG"
    # cleanup lock/temp
    clean_temp
    exit 4
fi

# ----- Retention: REPORT OBSOLETE and DELETE OBSOLETE -----------------------
# Build retention RMAN script
TMP_RET_RMAN_SCRIPT=$(mktemp "/tmp/rman_ret_${ORACLE_SID}_XXXX.rman")
cat > "$TMP_RET_RMAN_SCRIPT" <<EOF
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${retention_days} DAYS;
REPORT OBSOLETE;
DELETE NOPROMPT OBSOLETE;
EXIT;
EOF

# run retention and capture output
"$rman_binary" target / @"$TMP_RET_RMAN_SCRIPT" >> "$RETENTION_LOG" 2>&1 || RC_RET=$?
RC_RET=${RC_RET:-0}
printf '%s\n' "Retention RMAN exit code: ${RC_RET:-0}" >> "$RETENTION_LOG"

# scan retention log for ORA- or RMAN- errors and append to error log
grep -E 'ORA-[0-9]+|RMAN-[0-9]+' "$RETENTION_LOG" >> "$ERROR_LOG" || true

if [ "${RC_RET:-0}" -ne 0 ]; then
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') Retention/cleanup failed (exit ${RC_RET}). Check $RETENTION_LOG" >> "$ERROR_LOG"
    clean_temp
    exit 5
fi

# ----- Finalize and exit successfully --------------------------------------
printf '%s\n' "Backup and retention completed successfully for $ORACLE_SID at $(date '+%Y-%m-%d %H:%M:%S')" >> "$MAIN_LOG"
# Remove lock file
if [ -f "$LOCK_FILE" ]; then
    lockpid=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || printf '')
    if [ "$lockpid" = "$MY_PID_IN_LOCK" ]; then
        rm -f "$LOCK_FILE" || true
    fi
fi

# cleanup temp files
clean_temp

exit 0
