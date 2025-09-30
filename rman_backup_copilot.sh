#!/bin/sh
#===============================================================================
# rman_backup.sh - Production-ready RMAN backup orchestrator (POSIX sh-compatible)
#===============================================================================
# Author: Experienced Oracle DBA & Shell Script Developer
# License: MIT (or site standard)
#
# SUMMARY / README
# - Purpose: Safely run RMAN backups (Level 0, Level 1, and Archivelogs) with
#   dynamic channel allocation, compression option, strict logging, error scanning
#   with human-friendly error mapping, and post-backup retention cleanup.
#
# - Deliverables in this generated package:
#   1) rman_backup.sh (this file): Executable main script with no site-specific values.
#   2) rman_backup.conf: Configuration file with all site-specific variables and
#      customizable behavior (paths, channels, retention, compression defaults, etc.).
#
# - Installation:
#   1) Save rman_backup.sh and rman_backup.conf together, e.g. in /opt/dbabackup.
#   2) chmod 755 rman_backup.sh
#   3) Edit rman_backup.conf to match your environment, especially BASE_DIR,
#      LOG_DIR, ORATAB_PATH, CHANNELS, CHANNEL_MAXSIZE, and any retention settings.
#   4) Ensure OS authentication works for RMAN/SQL*Plus (preferred), or configure
#      Oracle Wallet. Do NOT hard-code passwords anywhere.
#
# - Scheduling (crontab example):
#   # Level 0 every Sunday 01:00
#   0 1 * * 0 /opt/dbabackup/rman_backup.sh -i ORCL -t L0 -c Y >> /opt/dbabackup/cron.log 2>&1
#   # Level 1 Monday–Saturday 01:00
#   0 1 * * 1-6 /opt/dbabackup/rman_backup.sh -i ORCL -t L1 >> /opt/dbabackup/cron.log 2>&1
#   # Archivelogs hourly
#   0 * * * * /opt/dbabackup/rman_backup.sh -i ORCL -t Arch >> /opt/dbabackup/cron.log 2>&1
#
# - Testing / Smoke tests:
#   1) Dry-run: set DRY_RUN=Y in rman_backup.conf and run:
#      ./rman_backup.sh -i ORCL -t L0 -c N
#      Confirm the generated RMAN command file and log paths without executing RMAN.
#   2) Simulate errors: create a fake log containing "ORA-19511" or "RMAN-03009"
#      in $LOG_DIR and run scan_log_for_errors function by invoking a Level 1 run.
#      Confirm the error mapping and remediation suggestions are written to .err file,
#      and script exits non-zero.
#
# - Assumptions:
#   * OS authentication enabled for SYSDBA (rman target /, sqlplus / as sysdba)
#   * oratab contains entries in format: SID:ORACLE_HOME:...
#   * Instance is started with PMON named "ora_pmon_<SID>"
#   * Backup device is DISK; channels use MAXPIECESIZE per CHANNEL_MAXSIZE
#   * Compression is backupset-based when enabled ("AS COMPRESSED BACKUPSET")
#
# - Exit codes:
#   0 = success
#   1 = bad args / usage error
#   2 = instance not found or not running
#   3 = database role not PRIMARY
#   4 = backup error detected in log
#   5 = retention cleanup error
#
# - Error mapping:
#   The script looks for RMAN/ORA error codes in the backup log, then maps codes
#   to human-readable messages using an error_map file defined in rman_backup.conf.
#   Example mapping lines (pipe-delimited):
#     RMAN-03009|failure to allocate channel|Check disk space/permissions and RMAN channel allocation
#     ORA-19511|error occurred during archiving|Check archiver process and destination
#   Add more mappings by appending to the error map file. If a code is not found,
#   the script logs a generic advisory: "see Oracle RMAN/DBA docs".
#   See section "Extending error_map" near the end of this file for more guidance.
#
# - Security note:
#   Do not store passwords in files or variables. Use OS authentication or Oracle Wallet.
#
# Usage:
#   ./rman_backup.sh -i INSTANCE_NAME -t {L0|L1|Arch} [-c {Y|N}] [--help]
#   Example: ./rman_backup.sh -i ORCL -t L0 -c Y
#   Expected logs:
#     $LOG_DIR/ORCL_L0_<timestamp>.log        (main backup log)
#     $ERROR_LOG_DIR/ORCL_L0_<timestamp>.err  (error scan results)
#     $LOG_DIR/ORCL_retention_<timestamp>.log (retention actions)
#     $ERROR_LOG_DIR/ORCL_retention_<timestamp>.err (retention errors)
#===============================================================================

# Ensure POSIX sh behavior; avoid bashisms

# Global variables (runtime only; all site-specific values come from rman_backup.conf)
SCRIPT_NAME="$(basename "$0")"
TS="$(date +%Y%m%d_%H%M%S)"
INSTANCE_NAME=""
BACKUP_TYPE=""
COMPRESSION="N"

# Runtime paths (set after loading config)
MAIN_LOG=""
ERROR_LOG=""
RET_LOG=""
RET_ERR_LOG=""
RMAN_CMD_FILE=""
SQL_CMD_FILE=""
RMAN_SCRIPT_FILE=""
RMAN_BIN=""
ORACLE_HOME=""
ORACLE_SID=""
PATH_BAKUP=""

# Exit codes as constants
EXIT_SUCCESS=0
EXIT_BAD_ARGS=1
EXIT_INSTANCE_NOT_RUNNING=2
EXIT_ROLE_NOT_PRIMARY=3
EXIT_BACKUP_ERROR=4
EXIT_RETENTION_ERROR=5

#-------------------------------------------------------------------------------
# fail: centralized failure handler with logging and exit
#-------------------------------------------------------------------------------
fail() {
  code="$1"; msg="$2"
  # Prefer writing to error log if initialized; else stderr
  if [ -n "$ERROR_LOG" ]; then
    echo "[$(date +%F' '%T)] ERROR ($code): $msg" >> "$ERROR_LOG"
  else
    echo "[$(date +%F' '%T)] ERROR ($code): $msg" >&2
  fi
  exit "$code"
}

#-------------------------------------------------------------------------------
# usage: print help/README summary
#-------------------------------------------------------------------------------
usage() {
  cat <<USAGE
$SCRIPT_NAME - RMAN backup orchestrator (POSIX sh)
Usage:
  $SCRIPT_NAME -i INSTANCE_NAME -t {L0|L1|Arch} [-c {Y|N}] [--help]

Mandatory:
  -i INSTANCE_NAME     Database instance/SID to backup
  -t BACKUP_TYPE       L0 (Level 0 full), L1 (incremental), Arch (archivelogs only)

Optional:
  -c COMPRESSION       Y to enable compressed backupset; N disables (default N)

Config:
  Edit rman_backup.conf for environment-specific values (paths, channels, retention, etc.)

Examples:
  $SCRIPT_NAME -i ORCL -t L0 -c Y
  $SCRIPT_NAME -i ORCL -t L1
  $SCRIPT_NAME -i ORCL -t Arch

Exit codes:
  0=success, 1=bad args, 2=instance not running, 3=role not primary,
  4=backup error, 5=retention error

Crontab examples:
  0 1 * * 0 /path/$SCRIPT_NAME -i ORCL -t L0 -c Y
  0 1 * * 1-6 /path/$SCRIPT_NAME -i ORCL -t L1
  0 * * * *   /path/$SCRIPT_NAME -i ORCL -t Arch

USAGE
}

#-------------------------------------------------------------------------------
# parse_args: parse CLI arguments
#-------------------------------------------------------------------------------
parse_args() {
  if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
    exit "$EXIT_SUCCESS"
  fi

  # POSIX getopts handling of -i -t -c
  while getopts "i:t:c:" opt; do
    case "$opt" in
      i) INSTANCE_NAME="$OPTARG" ;;
      t) BACKUP_TYPE="$OPTARG" ;;
      c) COMPRESSION="$OPTARG" ;;
      *) usage; exit "$EXIT_BAD_ARGS" ;;
    esac
  done

  # Validate required arguments
  if [ -z "$INSTANCE_NAME" ] || [ -z "$BACKUP_TYPE" ]; then
    usage
    exit "$EXIT_BAD_ARGS"
  fi

  # Normalize BACKUP_TYPE case-insensitively to canonical form
  case "$(echo "$BACKUP_TYPE" | tr '[:lower:]' '[:upper:]')" in
    L0) BACKUP_TYPE="L0" ;;
    L1) BACKUP_TYPE="L1" ;;
    ARCH) BACKUP_TYPE="Arch" ;;
    *) echo "Invalid BACKUP_TYPE: $BACKUP_TYPE"; usage; exit "$EXIT_BAD_ARGS" ;;
  esac

  # Normalize COMPRESSION to Y or N
  case "$(echo "${COMPRESSION:-N}" | tr '[:lower:]' '[:upper:]')" in
    Y) COMPRESSION="Y" ;;
    N) COMPRESSION="N" ;;
    *) echo "Invalid COMPRESSION: $COMPRESSION (use Y or N)"; usage; exit "$EXIT_BAD_ARGS" ;;
  esac
}

#-------------------------------------------------------------------------------
# load_config: source rman_backup.conf and validate key variables
#-------------------------------------------------------------------------------
load_config() {
  CONF_DIR="$(dirname "$0")"
  CONF_FILE="$CONF_DIR/rman_backup.conf"

  if [ ! -r "$CONF_FILE" ]; then
    echo "Configuration file not readable: $CONF_FILE"
    exit "$EXIT_BAD_ARGS"
  fi

  # shellcheck disable=SC1090
  . "$CONF_FILE"

  # Validate critical config
  [ -z "$BASE_DIR" ] && fail "$EXIT_BAD_ARGS" "BASE_DIR not set in config"
  [ -z "$LOG_DIR" ] && fail "$EXIT_BAD_ARGS" "LOG_DIR not set in config"
  [ -z "$ERROR_LOG_DIR" ] && fail "$EXIT_BAD_ARGS" "ERROR_LOG_DIR not set in config"
  [ -z "$TMP_DIR" ] && fail "$EXIT_BAD_ARGS" "TMP_DIR not set in config"
  [ -z "$ORATAB_PATH" ] && fail "$EXIT_BAD_ARGS" "ORATAB_PATH not set in config"
  [ -z "$CHANNELS" ] && fail "$EXIT_BAD_ARGS" "CHANNELS not set in config"
  [ -z "$CHANNEL_MAXSIZE" ] && fail "$EXIT_BAD_ARGS" "CHANNEL_MAXSIZE not set in config"
  [ -z "$RETENTION_DAYS" ] && fail "$EXIT_BAD_ARGS" "RETENTION_DAYS not set in config"

  # Validate CHANNELS integer >=1
  case "$CHANNELS" in
    ''|*[!0-9]*)
      fail "$EXIT_BAD_ARGS" "CHANNELS must be integer >=1"
      ;;
    *)
      if [ "$CHANNELS" -lt 1 ]; then
        fail "$EXIT_BAD_ARGS" "CHANNELS must be >=1"
      fi
      ;;
  esac

  # Set RMAN_BIN to override or default to ORACLE_HOME later
  RMAN_BIN="${RMAN_BINARY:-}"

  # Ensure directories exist
  for d in "$BASE_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_L0_DIR" "$BACKUP_L1_DIR" "$BACKUP_ARCH_DIR"; do
    if [ ! -d "$d" ]; then
      mkdir -p "$d" || fail "$EXIT_BAD_ARGS" "Failed to create directory: $d"
      chmod 750 "$d" 2>/dev/null || true
    fi
  done

  # Prepare error_map file if embedded data provided and file missing
  if [ -n "$ERROR_MAP_FILE" ]; then
    if [ ! -e "$ERROR_MAP_FILE" ] && [ -n "$ERROR_MAP_DATA" ]; then
      echo "$ERROR_MAP_DATA" > "$ERROR_MAP_FILE" || fail "$EXIT_BAD_ARGS" "Cannot write ERROR_MAP_FILE: $ERROR_MAP_FILE"
    fi
  fi

  # Prepare default log file names
  MAIN_LOG="$LOG_DIR/${INSTANCE_NAME}_${BACKUP_TYPE}_${TS}.log"
  ERROR_LOG="$ERROR_LOG_DIR/${INSTANCE_NAME}_${BACKUP_TYPE}_${TS}.err"
  RET_LOG="$LOG_DIR/${INSTANCE_NAME}_retention_${TS}.log"
  RET_ERR_LOG="$ERROR_LOG_DIR/${INSTANCE_NAME}_retention_${TS}.err"
  RMAN_CMD_FILE="$TMP_DIR/${INSTANCE_NAME}_${BACKUP_TYPE}_${TS}.rman.cmd"
  RMAN_SCRIPT_FILE="$TMP_DIR/${INSTANCE_NAME}_${BACKUP_TYPE}_${TS}.rman"
  SQL_CMD_FILE="$TMP_DIR/${INSTANCE_NAME}_${TS}.sql"
}

#-------------------------------------------------------------------------------
# set_environment: derive ORACLE_HOME/ORACLE_SID from oratab and export PATH
#-------------------------------------------------------------------------------
set_environment() {
  ORACLE_SID="$INSTANCE_NAME"

  # Find oratab line for instance: SID:ORACLE_HOME:...
  # Exclude commented lines starting with '#'
  ORATAB_LINE="$(grep -E "^[[:space:]]*$ORACLE_SID:" "$ORATAB_PATH" | grep -v '^[[:space:]]*#')"
  if [ -z "$ORATAB_LINE" ]; then
    fail "$EXIT_INSTANCE_NOT_RUNNING" "Instance $ORACLE_SID not found in $ORATAB_PATH"
  fi

  ORACLE_HOME="$(echo "$ORATAB_LINE" | awk -F: '{print $2}')"
  if [ -z "$ORACLE_HOME" ] || [ ! -d "$ORACLE_HOME" ]; then
    fail "$EXIT_BAD_ARGS" "ORACLE_HOME invalid for $ORACLE_SID (check $ORATAB_PATH)"
  fi

  export ORACLE_HOME ORACLE_SID
  export PATH="$ORACLE_HOME/bin:$PATH"

  # Set RMAN_BIN default if not overridden
  if [ -z "$RMAN_BIN" ]; then
    RMAN_BIN="$ORACLE_HOME/bin/rman"
  fi
  [ -x "$RMAN_BIN" ] || fail "$EXIT_BAD_ARGS" "RMAN binary not executable: $RMAN_BIN"
}

#-------------------------------------------------------------------------------
# check_instance: verify instance running and role PRIMARY
#-------------------------------------------------------------------------------
check_instance() {
  # Check PMON process to confirm running
  PMON_NAME="ora_pmon_${ORACLE_SID}"
  if ! ps -e -o comm | grep -q "^$PMON_NAME$"; then
    fail "$EXIT_INSTANCE_NOT_RUNNING" "Instance $ORACLE_SID not running (PMON $PMON_NAME not found)"
  fi

  # Check database role via SQL*Plus
  cat > "$SQL_CMD_FILE" <<EOS
set heading off feedback off verify off pages 0 echo off
select database_role from v\\$database;
exit
EOS

  ROLE="$(sqlplus -s / as sysdba @"$SQL_CMD_FILE" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$ROLE" ]; then
    fail "$EXIT_BAD_ARGS" "Unable to determine database role via SQL*Plus"
  fi
  if [ "$ROLE" != "PRIMARY" ]; then
    fail "$EXIT_ROLE_NOT_PRIMARY" "Database role is $ROLE, not PRIMARY; backups disabled"
  fi
}

#-------------------------------------------------------------------------------
# build_rman_script: construct RMAN script dynamically based on type/channels
#-------------------------------------------------------------------------------
build_rman_script() {
  # Compute date-based subdir names (e.g., dd-mon-yyyy)
  DATE_TAG="$(date +%d-%b-%Y)"
  COMPRESS_CLAUSE=""
  if [ "$COMPRESSION" = "Y" ]; then
    COMPRESS_CLAUSE=" as compressed backupset"
  fi

  # Select base backup dir and format string by type
  case "$BACKUP_TYPE" in
    L0)
      BASE_TARGET_DIR="$BACKUP_L0_DIR/$DATE_TAG"
      BACKUP_FORMAT="$BACKUP_FORMAT_L0"
      ;;
    L1)
      BASE_TARGET_DIR="$BACKUP_L1_DIR/$DATE_TAG"
      BACKUP_FORMAT="$BACKUP_FORMAT_L1"
      ;;
    Arch)
      BASE_TARGET_DIR="$BACKUP_ARCH_DIR/$DATE_TAG"
      BACKUP_FORMAT="$BACKUP_FORMAT_ARCH"
      ;;
  esac

  # Create target directories (including subdirs for control/spfile)
  mkdir -p "$BASE_TARGET_DIR" || fail "$EXIT_BAD_ARGS" "Failed to create base target dir: $BASE_TARGET_DIR"
  chmod 750 "$BASE_TARGET_DIR" 2>/dev/null || true
  CONTROL_DIR="$BASE_TARGET_DIR/control"
  SPFILE_DIR="$BASE_TARGET_DIR/spfile"
  ARCH_DIR="$BASE_TARGET_DIR/archivelogs"
  mkdir -p "$CONTROL_DIR" "$SPFILE_DIR" "$ARCH_DIR" 2>/dev/null || true

  # Build channel allocation block
  ALLOCATE_CHANNELS=""
  i=1
  while [ "$i" -le "$CHANNELS" ]; do
    ALLOCATE_CHANNELS="$ALLOCATE_CHANNELS
    allocate channel ch$i device type disk maxpiecesize $CHANNEL_MAXSIZE;"
    i=$((i+1))
  done

  # Build channel release block
  RELEASE_CHANNELS=""
  i=1
  while [ "$i" -le "$CHANNELS" ]; do
    RELEASE_CHANNELS="$RELEASE_CHANNELS
    release channel ch$i;"
    i=$((i+1))
  done

  # Build backup commands based on type
  case "$BACKUP_TYPE" in
    L0)
      # Level 0 full incremental backup + spfile/controlfile + archivelogs not backed up
      cat > "$RMAN_SCRIPT_FILE" <<ERMAN
run {
$ALLOCATE_CHANNELS
    backup$COMPRESS_CLAUSE incremental level 0 database
      format '$BASE_TARGET_DIR/${BACKUP_FORMAT}_db_%U.bkp';
    backup$COMPRESS_CLAUSE spfile
      format '$SPFILE_DIR/${BACKUP_FORMAT}_spfile_%U.bkp';
    backup$COMPRESS_CLAUSE current controlfile
      format '$CONTROL_DIR/${BACKUP_FORMAT}_control_%U.bkp';
    backup$COMPRESS_CLAUSE archivelog all not backed up
      format '$ARCH_DIR/${BACKUP_FORMAT}_arch_%U.bkp';
$RELEASE_CHANNELS
}
ERMAN
      ;;
    L1)
      # Level 1 incremental backup + spfile/controlfile + archivelogs not backed up
      cat > "$RMAN_SCRIPT_FILE" <<ERMAN
run {
$ALLOCATE_CHANNELS
    backup$COMPRESS_CLAUSE incremental level 1 database
      format '$BASE_TARGET_DIR/${BACKUP_FORMAT}_db_%U.bkp';
    backup$COMPRESS_CLAUSE spfile
      format '$SPFILE_DIR/${BACKUP_FORMAT}_spfile_%U.bkp';
    backup$COMPRESS_CLAUSE current controlfile
      format '$CONTROL_DIR/${BACKUP_FORMAT}_control_%U.bkp';
    backup$COMPRESS_CLAUSE archivelog all not backed up
      format '$ARCH_DIR/${BACKUP_FORMAT}_arch_%U.bkp';
$RELEASE_CHANNELS
}
ERMAN
      ;;
    Arch)
      # Archivelogs only; ensure NOT BACKED UP selection
      cat > "$RMAN_SCRIPT_FILE" <<ERMAN
run {
$ALLOCATE_CHANNELS
    backup$COMPRESS_CLAUSE archivelog all not backed up
      format '$BASE_TARGET_DIR/${BACKUP_FORMAT}_arch_%U.bkp';
$RELEASE_CHANNELS
}
ERMAN
      ;;
  esac

  # Build configure retention and cleanup command file (used post-success)
  # Strategy controlled via RETENTION_STRATEGY in config: WINDOW or REPORT_DELETE
  if [ "$RETENTION_STRATEGY" = "WINDOW" ]; then
    cat > "$RMAN_CMD_FILE" <<ERMAN2
configure retention policy to recovery window of $RETENTION_DAYS days;
report obsolete;
delete obsolete;
ERMAN2
  else
    cat > "$RMAN_CMD_FILE" <<ERMAN2
report obsolete recovery window of $RETENTION_DAYS days;
delete obsolete recovery window of $RETENTION_DAYS days;
ERMAN2
  fi
}

#-------------------------------------------------------------------------------
# run_rman: execute RMAN with the built script; handle dry-run and logging
#-------------------------------------------------------------------------------
run_rman() {
  echo "[$(date +%F' '%T)] Starting RMAN $BACKUP_TYPE backup for $INSTANCE_NAME (compression=$COMPRESSION)" >> "$MAIN_LOG"
  echo "RMAN script: $RMAN_SCRIPT_FILE" >> "$MAIN_LOG"

  if [ "$DRY_RUN" = "Y" ]; then
    echo "[DRY_RUN] RMAN would execute the following:" >> "$MAIN_LOG"
    sed 's/^/  /' "$RMAN_SCRIPT_FILE" >> "$MAIN_LOG"
    return 0
  fi

  # Run RMAN target / using OS authentication; write stdout/stderr to MAIN_LOG
  "$RMAN_BIN" target / cmdfile "$RMAN_SCRIPT_FILE" log "$MAIN_LOG" 2>&1
  RMAN_EXIT=$?

  echo "[$(date +%F' '%T)] RMAN exit code: $RMAN_EXIT" >> "$MAIN_LOG"

  # RMAN non-zero exit can indicate issues; scanner will confirm
  return "$RMAN_EXIT"
}

#-------------------------------------------------------------------------------
# scan_log_for_errors: parse MAIN_LOG for RMAN-/ORA- errors and map/remediate
#-------------------------------------------------------------------------------
scan_log_for_errors() {
  ERR_FOUND=0

  # Extract lines with common error patterns
  # Patterns: RMAN-XXXX, ORA-XXXXX, "ERROR at line"
  grep -E "RMAN-[0-9]{5}|ORA-[0-9]{5}|ERROR at line" "$MAIN_LOG" > "$TMP_DIR/${INSTANCE_NAME}_${TS}.errors" 2>/dev/null

  if [ -s "$TMP_DIR/${INSTANCE_NAME}_${TS}.errors" ]; then
    ERR_FOUND=1
    {
      echo "Backup errors detected in $MAIN_LOG:"
      echo "Timestamp: $(date +%F' '%T)"
      echo "Instance: $INSTANCE_NAME  Type: $BACKUP_TYPE"
      echo "---- Raw error lines ----"
      cat "$TMP_DIR/${INSTANCE_NAME}_${TS}.errors"
      echo "---- Mapped messages ----"
    } >> "$ERROR_LOG"

    # Map each code to friendly message
    if [ -n "$ERROR_MAP_FILE" ] && [ -r "$ERROR_MAP_FILE" ]; then
      while IFS= read -r line; do
        CODE="$(echo "$line" | grep -Eo '(RMAN|ORA)-[0-9]+' | head -n1)"
        if [ -n "$CODE" ]; then
          MAP_LINE="$(grep -E "^${CODE}\|" "$ERROR_MAP_FILE" | head -n1)"
          if [ -n "$MAP_LINE" ]; then
            SHORT="$(echo "$MAP_LINE" | awk -F'|' '{print $2}')"
            REMEDY="$(echo "$MAP_LINE" | awk -F'|' '{print $3}')"
            echo "$CODE: $SHORT | Remedy: $REMEDY" >> "$ERROR_LOG"
          else
            echo "$CODE: Unmapped error. Please see Oracle RMAN/DBA docs." >> "$ERROR_LOG"
          fi
        else
          echo "Uncoded error line: $line" >> "$ERROR_LOG"
        fi
      done < "$TMP_DIR/${INSTANCE_NAME}_${TS}.errors"
    else
      echo "No ERROR_MAP_FILE available/readable; consider configuring ERROR_MAP_FILE in rman_backup.conf" >> "$ERROR_LOG"
    fi

    echo "---- End of error scan ----" >> "$ERROR_LOG"
  fi

  return "$ERR_FOUND"
}

#-------------------------------------------------------------------------------
# retention_cleanup: run RMAN retention per configured strategy
#-------------------------------------------------------------------------------
retention_cleanup() {
  if [ "$DRY_RUN" = "Y" ]; then
    echo "[DRY_RUN] Retention would run with strategy=$RETENTION_STRATEGY, days=$RETENTION_DAYS" >> "$RET_LOG"
    sed 's/^/  /' "$RMAN_CMD_FILE" >> "$RET_LOG"
    return 0
  fi

  "$RMAN_BIN" target / cmdfile "$RMAN_CMD_FILE" log "$RET_LOG" 2>&1
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "Retention RMAN exit code: $RC" >> "$RET_ERR_LOG"
    # Scan retention log for errors as well
    grep -E "RMAN-[0-9]{5}|ORA-[0-9]{5}|ERROR at line" "$RET_LOG" >> "$RET_ERR_LOG" 2>/dev/null
    fail "$EXIT_RETENTION_ERROR" "Retention cleanup failed (see $RET_LOG and $RET_ERR_LOG)"
  fi
  return 0
}

#-------------------------------------------------------------------------------
# rotate_logs: optional log rotation/cleanup based on LOG_RETENTION_DAYS
#-------------------------------------------------------------------------------
rotate_logs() {
  if [ -n "$LOG_RETENTION_DAYS" ]; then
    find "$LOG_DIR" -type f -name "${INSTANCE_NAME}_*.log" -mtime +"$LOG_RETENTION_DAYS" -exec rm -f {} \; 2>/dev/null
    find "$ERROR_LOG_DIR" -type f -name "${INSTANCE_NAME}_*.err" -mtime +"$LOG_RETENTION_DAYS" -exec rm -f {} \; 2>/dev/null
  fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
parse_args "$@"
load_config
set_environment
check_instance
build_rman_script

# Run RMAN backup
run_rman
RMAN_RUN_RC=$?

# Immediately scan for errors
scan_log_for_errors
SCAN_RC=$?

if [ "$SCAN_RC" -ne 0 ] || [ "$RMAN_RUN_RC" -ne 0 ]; then
  # If any error detected, exit non-zero after logging
  fail "$EXIT_BACKUP_ERROR" "Backup errors detected; see $MAIN_LOG and $ERROR_LOG"
fi

# If backup successful, perform retention cleanup
retention_cleanup || exit "$EXIT_RETENTION_ERROR"

# Optionally rotate old logs
rotate_logs

echo "[$(date +%F' '%T)] Backup completed successfully for $INSTANCE_NAME ($BACKUP_TYPE). Logs: $MAIN_LOG" >> "$MAIN_LOG"
exit "$EXIT_SUCCESS"

#===============================================================================
# Extending error_map (DBA guidance)
# - Edit the file configured via ERROR_MAP_FILE in rman_backup.conf.
# - Format: CODE|SHORT_MESSAGE|REMEDY
#   Examples:
#     RMAN-03009|failure to allocate channel|Check disk space/permissions and RMAN channel allocation
#     RMAN-06059|expected archived log not found|Verify archivelog destination and crosscheck/delete expired
#     RMAN-06025|no backup of archived log found|Ensure archivelogs exist; validate log shipping
#     RMAN-20011|target database incarnation not found|Review catalog/resync; check resetlogs/incarnation
#     ORA-19511|error occurred during archiving|Check archiver process (ARCn) and destination free space
#     ORA-19809|limit exceeded for recovery files|Increase FRA size or delete obsolete; check db_recovery_file_dest_size
#     ORA-27102|out of memory|Check OS memory availability and SGA/PGA settings
#     ORA-00257|archiver error. connect internal only|Free up FRA or archive dest; resume archiver
#     ORA-00001|unique constraint violated|Investigate catalog operations if applicable
# - Authoritative docs:
#   * Oracle Database Backup and Recovery User’s Guide (RMAN)
#   * Oracle Database Error Messages and Reference
#   * My Oracle Support (MOS) notes for specific RMAN/ORA codes
#===============================================================================
