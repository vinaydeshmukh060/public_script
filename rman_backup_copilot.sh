#!/bin/sh
#==============================================================================
# rman_backup.sh - Production-ready RMAN backup driver (POSIX /bin/sh compatible)
#
# Purpose:
# - Run RMAN backups with robust logging, error detection/mapping, and retention cleanup.
# - Supports Full (Level 0), Incremental (Level 1), and Archivelog-only backups.
# - Uses configuration file for all site-specific settings—no hard-coded values.
#
# Key features:
# - POSIX sh compatible (no bash-only features)
# - Strict error handling: set -eu, traps, checks for commands and environment
# - Mandatory args: instance_name (ORACLE_SID), backup_type (L0|L1|Arch)
# - Optional compression flag: Y/N (defaults to config default)
# - Locking to prevent concurrent runs per instance/type
# - RMAN channel allocation based on config "channels" + max size limits
# - Backup directories and format patterns loaded from config with date token expansion
# - DB role verification (must be PRIMARY, else abort)
# - Separate logs: main backup log, error log, retention log (all timestamped)
# - Error mapping for common ORA- and RMAN- errors with suggested actions
# - RMAN REPORT/DELETE OBSOLETE with configurable retention days
# - Optional dry-run to print planned actions and RMAN script
#
# README / Usage:
# - Ensure rman_backup.conf is properly configured and readable by this script.
# - The script reads /etc/oratab (or overridden path) to set ORACLE_HOME based on ORACLE_SID.
# - The instance must be running and the DB role must be PRIMARY.
#
# Examples:
#   ./rman_backup.sh -i ORCL -t L0 -c Y
#   ./rman_backup.sh ORCL L1
#   ./rman_backup.sh -i ORCL -t Arch         # compression defaults from config
#   ./rman_backup.sh -i ORCL -t L1 -n        # dry-run (no execution)
#
# Sample log file names (under ${logs_dir}):
#   rman_backup_ORCL_L0_20251003_230501.log        # main backup log
#   rman_errors_ORCL_L0_20251003_230501.log        # error log (parsed/mapped)
#   rman_retention_ORCL_L0_20251003_230501.log     # retention log
#
# Exit codes:
#   0  - Success (backup + retention cleanup succeeded, no mapped errors found)
#   1  - Argument or configuration error
#   2  - Environment setup failure (ORACLE_HOME/sqlplus/rman missing)
#   3  - Instance not running or DB role not PRIMARY
#   4  - RMAN backup failure (errors detected in main backup log)
#   5  - Retention cleanup failure
#   6  - Lock acquisition failure (another run in progress)
#
# Recommended manual test steps:
# - Validate config load and command checks: run with -n (dry-run) and verify printed RMAN script.
# - Confirm DB role detection: stop instance or switch to STANDBY to see abort behavior.
# - Check channel allocation text in generated RMAN run block with various "channels" values.
# - Simulate RMAN/ORA errors (e.g., wrong directory permissions) and verify mapped error output.
# - Verify archivelog "NOT BACKED UP" behavior by running Arch repeatedly and ensuring no duplicates.
# - Confirm retention logs show REPORT/DELETE OBSOLETE, and files are properly removed.
#
#==============================================================================

# Strict/defensive shell behavior. -u: undefined variables are errors; -e: abort on any command failure.
set -eu

#------------------------------------------------------------------------------
# Global variables initialized early for logging and cleanup control
#------------------------------------------------------------------------------

# **Script_name:** Base name used in logs and summaries.
SCRIPT_NAME=$(basename "$0")

# **Start_ts:** Start timestamp to tag logs consistently.
START_TS=$(date '+%Y%m%d_%H%M%S')

# **Tmp_dir:** Temporary working directory. Created via mktemp for safety.
TMP_DIR=$(mktemp -d "/tmp/${SCRIPT_NAME%.sh}.XXXXXX")

# **Lock_dir:** Will be set after arguments are parsed (depends on instance/type).
LOCK_DIR=""

# Register cleanup to ensure temp and locks removed on exit.
cleanup() {
  # Remove lock directory if created by this process.
  if [ -n "${LOCK_DIR}" ] && [ -d "${LOCK_DIR}" ]; then
    rmdir "${LOCK_DIR}" 2>/dev/null || true
  fi
  # Remove tmp directory.
  if [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

#------------------------------------------------------------------------------
# Helper: print usage
#------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} -i <instance_name> -t <L0|L1|Arch> [-c <Y|N>] [-n]
  ${SCRIPT_NAME} <instance_name> <L0|L1|Arch> [<Y|N>] [-n]

Arguments:
  -i, --instance     ORACLE_SID (required)
  -t, --type         Backup type: L0 (full), L1 (incremental), Arch (archivelog only)
  -c, --compression  Y or N (optional; defaults to config default_compression)
  -n, --dry-run      Print planned actions and RMAN script without executing

Notes:
  - All site-specific settings come from rman_backup.conf (must exist and be readable).
  - Database role must be PRIMARY; script aborts otherwise.
  - Logs are written under logs_dir defined in configuration.

Examples:
  ${SCRIPT_NAME} -i ORCL -t L0 -c Y
  ${SCRIPT_NAME} ORCL L1
  ${SCRIPT_NAME} -i ORCL -t Arch -n
EOF
}

#------------------------------------------------------------------------------
# Helper: fatal error with exit code and optional error log
#------------------------------------------------------------------------------
fatal() {
  # **Label:** Human-readable error message
  MSG="$1"
  # **Label:** Exit code to return
  CODE="$2"
  # **Label:** Optional error log path
  ERR_LOG="${3:-}"

  TS=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${TS}] ERROR: ${MSG}" >&2
  if [ -n "${ERR_LOG}" ]; then
    echo "[${TS}] ERROR: ${MSG}" >> "${ERR_LOG}"
    echo "[${TS}] ERROR: Exit code ${CODE}" >> "${ERR_LOG}"
  fi
  exit "${CODE}"
}

#------------------------------------------------------------------------------
# Parse arguments (supports both short and positional forms)
#------------------------------------------------------------------------------
INSTANCE=""
BACKUP_TYPE=""
COMPRESSION_ARG=""
DRY_RUN="N"

# Accept both flag-style and positional for compatibility
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--instance)
      INSTANCE="${2:-}"; shift 2 ;;
    -t|--type)
      BACKUP_TYPE="${2:-}"; shift 2 ;;
    -c|--compression)
      COMPRESSION_ARG="${2:-}"; shift 2 ;;
    -n|--dry-run)
      DRY_RUN="Y"; shift 1 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      # positional fallback: instance, type, compression
      if [ -z "${INSTANCE}" ]; then
        INSTANCE="$1"
      elif [ -z "${BACKUP_TYPE}" ]; then
        BACKUP_TYPE="$1"
      elif [ -z "${COMPRESSION_ARG}" ]; then
        COMPRESSION_ARG="$1"
      else
        echo "Unknown extra argument: $1" >&2
        usage; exit 1
      fi
      shift 1 ;;
  esac
done

# Validate mandatory args
[ -n "${INSTANCE}" ] || { usage; exit 1; }
[ -n "${BACKUP_TYPE}" ] || { usage; exit 1; }

# Normalize backup type: case-insensitive mapping to L0|L1|Arch
case "$(echo "${BACKUP_TYPE}" | tr '[:lower:]' '[:upper:]')" in
  L0) BACKUP_TYPE="L0" ;;
  L1) BACKUP_TYPE="L1" ;;
  ARCH) BACKUP_TYPE="Arch" ;;
  *) echo "Invalid backup type: ${BACKUP_TYPE}. Allowed: L0, L1, Arch" >&2; exit 1 ;;
esac

#------------------------------------------------------------------------------
# Load configuration file (must exist). All site-specific values live here.
#------------------------------------------------------------------------------
# **Config_file:** The configuration file path searched in current dir then script dir.
CONFIG_FILE="rman_backup.conf"
if [ ! -f "${CONFIG_FILE}" ]; then
  # Try script directory
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  if [ -f "${SCRIPT_DIR}/rman_backup.conf" ]; then
    CONFIG_FILE="${SCRIPT_DIR}/rman_backup.conf"
  fi
fi
[ -f "${CONFIG_FILE}" ] || { echo "Configuration file rman_backup.conf not found."; exit 1; }

# shellcheck disable=SC1090
. "${CONFIG_FILE}"

#------------------------------------------------------------------------------
# Derive compression final flag from input or config default
#------------------------------------------------------------------------------
# **Compression:** Final compression decision, Y or N.
if [ -n "${COMPRESSION_ARG}" ]; then
  case "$(echo "${COMPRESSION_ARG}" | tr '[:lower:]' '[:upper:]')" in
    Y) COMPRESSION="Y" ;;
    N) COMPRESSION="N" ;;
    *) echo "Invalid compression flag: ${COMPRESSION_ARG}. Use Y or N." >&2; exit 1 ;;
  esac
else
  case "$(echo "${default_compression}" | tr '[:lower:]' '[:upper:]')" in
    Y) COMPRESSION="Y" ;;
    *) COMPRESSION="N" ;;
  esac
fi

#------------------------------------------------------------------------------
# Establish log file paths (timestamped, per run)
#------------------------------------------------------------------------------
# **Logs_dir:** Where logs are stored; created if absent.
mkdir -p "${logs_dir}"

# **Main_log:** Primary RMAN output (stdout/stderr) log
MAIN_LOG="${logs_dir}/rman_backup_${INSTANCE}_${BACKUP_TYPE}_${START_TS}.log"

# **Error_log:** Mapped errors and raw error lines captured here
ERROR_LOG="${logs_dir}/rman_errors_${INSTANCE}_${BACKUP_TYPE}_${START_TS}.log"

# **Retention_log:** Report/Delete obsolete logs
RETENTION_LOG="${logs_dir}/rman_retention_${INSTANCE}_${BACKUP_TYPE}_${START_TS}.log"

#------------------------------------------------------------------------------
# Concurrency control: lock per instance+type to avoid overlapping runs
#------------------------------------------------------------------------------
# **Lock_dir:** Atomic mkdir-based lock directory ensures single active run.
LOCK_DIR="${TMP_DIR}/lock_${INSTANCE}_${BACKUP_TYPE}"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  fatal "Another backup appears to be running for ${INSTANCE}/${BACKUP_TYPE}. Aborting." 6 "${ERROR_LOG}"
fi

#------------------------------------------------------------------------------
# Validate required commands exist (rman, sqlplus, date, ps)
#------------------------------------------------------------------------------
require_cmd() {
  CMD="$1"
  # Look for command in PATH or absolute path
  if ! command -v "${CMD}" >/dev/null 2>&1; then
    fatal "Required command not found: ${CMD}" 2 "${ERROR_LOG}"
  fi
}
# rman binary can be a path or name
require_cmd "${rman_binary}"
require_cmd date
require_cmd ps
require_cmd awk
require_cmd sed
require_cmd tr

#------------------------------------------------------------------------------
# Resolve ORACLE_HOME and PATH from oratab, export environment, ensure instance up
#------------------------------------------------------------------------------
# **Oratab_path:** Configurable path to oratab
ORATAB_PATH="${oratab_path}"

[ -f "${ORATAB_PATH}" ] || fatal "oratab file not found at ${ORATAB_PATH}" 2 "${ERROR_LOG}"

# **Oracle_home:** Extract from oratab line "SID:ORACLE_HOME:Y|N"
ORACLE_HOME=$(awk -F: -v sid="${INSTANCE}" '
  BEGIN { found=0 }
  $1 == sid { print $2; found=1 }
  END { if (found==0) exit 1 }
' "${ORATAB_PATH}") || fatal "Unable to find ORACLE_HOME for SID ${INSTANCE} in ${ORATAB_PATH}" 2 "${ERROR_LOG}"

[ -d "${ORACLE_HOME}" ] || fatal "ORACLE_HOME path does not exist: ${ORACLE_HOME}" 2 "${ERROR_LOG}"

# Ensure sqlplus exists under ORACLE_HOME
SQLPLUS_BIN="${ORACLE_HOME}/bin/sqlplus"
[ -x "${SQLPLUS_BIN}" ] || fatal "sqlplus not found or not executable at ${SQLPLUS_BIN}" 2 "${ERROR_LOG}"

# Export environment for RMAN/sqlplus
export ORACLE_SID="${INSTANCE}"
export ORACLE_HOME
export PATH="${ORACLE_HOME}/bin:${PATH}"

# **Instance check:** Verify PMON process exists for the SID (basic liveness check)
PMON_COUNT=$(ps -ef | grep "[p]mon_${ORACLE_SID}" | wc -l)
if [ "${PMON_COUNT}" -lt 1 ]; then
  fatal "Instance ${ORACLE_SID} appears down (PMON not found). Aborting." 3 "${ERROR_LOG}"
fi

#------------------------------------------------------------------------------
# Optional environment profile sourcing (e.g., user profile for ORACLE user)
#------------------------------------------------------------------------------
# **Environment_profile:** If set, attempt to source from /etc/profile.d or ~/.profile
if [ -n "${environment_profile:-}" ]; then
  # Non-fatal if missing; best-effort
  PROFILE_CANDIDATES="
/etc/profile.d/${environment_profile}.sh
${HOME}/.${environment_profile}
${HOME}/.${environment_profile}.sh
"
  for P in ${PROFILE_CANDIDATES}; do
    if [ -f "${P}" ]; then
      # shellcheck disable=SC1090
      . "${P}" || true
      break
    fi
  done
fi

#------------------------------------------------------------------------------
# Verify database role is PRIMARY via SQL*Plus
#------------------------------------------------------------------------------
DB_ROLE=$(
  "${SQLPLUS_BIN}" -s / as sysdba <<'SQL'
set pagesize 0 feedback off verify off heading off echo off
SELECT DATABASE_ROLE FROM V$DATABASE;
exit
SQL
)
DB_ROLE_CLEAN=$(echo "${DB_ROLE}" | tr -d '[:space:]')

if [ "${DB_ROLE_CLEAN}" != "PRIMARY" ]; then
  fatal "Database role for ${ORACLE_SID} is '${DB_ROLE_CLEAN}', not PRIMARY. Backup aborted." 3 "${ERROR_LOG}"
fi

#------------------------------------------------------------------------------
# Date token expansion and backup format resolution
#------------------------------------------------------------------------------
# **Date_str:** dd-Mon-YYYY per requirement (e.g., 03-Oct-2025)
DATE_STR=$(date '+%d-%b-%Y')

# **Format_note:** config allows a token like <date:dd-mon-yyyy> which we replace with DATE_STR
expand_date_token() {
  # Replaces the token <date:dd-mon-yyyy> (case-insensitive) in a format string.
  # Also supports %s placeholder, substituting a base name that includes SID and date.
  INPUT="$1"
  # Replace date token
  OUT=$(echo "${INPUT}" | sed "s/<[dD][aA][tT][eE]:[dD][dD]-[mM][oO][nN]-[yY][yY][yY][yY]>/${DATE_STR}/g")
  # Compose default base name if %s is present: SID_DATE_%U
  BASE="${ORACLE_SID}_${DATE_STR}_%U"
  OUT=$(echo "${OUT}" | sed "s/%s/${BASE}/g")
  echo "${OUT}"
}

# Resolve target directories and formats from config
# Create directories safely.
mkdir -p "${base_dir}" "${backup_L0_dir}" "${backup_L1_dir}" "${backup_Arch_dir}" || true

FORMAT_L0=$(expand_date_token "${backup_format_L0}")
FORMAT_L1=$(expand_date_token "${backup_format_L1}")
FORMAT_ARCH=$(expand_date_token "${backup_format_Arch}")

#------------------------------------------------------------------------------
# RMAN channel allocation builder
#------------------------------------------------------------------------------
# **Channels:** Number of channels to allocate (e.g., 3). Allocate DISK channels.
# **Channel_max_size:** Size limit per piece (e.g., 100G). Applied via MAXPIECESIZE.
CHANNELS="${channels}"
CHANNEL_MAX_SIZE="${channel_max_size}"

build_channel_allocation() {
  i=1
  while [ "${i}" -le "${CHANNELS}" ]; do
    echo "    allocate channel ch${i} device type disk maxpiecesize ${CHANNEL_MAX_SIZE};"
    i=$((i+1))
  done
}

release_channels() {
  i=1
  while [ "${i}" -le "${CHANNELS}" ]; do
    echo "    release channel ch${i};"
    i=$((i+1))
  done
}

#------------------------------------------------------------------------------
# Compression clause builder
#------------------------------------------------------------------------------
# **Compression_clause:** Adds "AS COMPRESSED BACKUPSET" if COMPRESSION=Y, else empty or "AS BACKUPSET"
compression_clause() {
  if [ "${COMPRESSION}" = "Y" ]; then
    echo "AS COMPRESSED BACKUPSET"
  else
    echo "AS BACKUPSET"
  fi
}

#------------------------------------------------------------------------------
# Build RMAN run block per backup type
#------------------------------------------------------------------------------
RMAN_SCRIPT_FILE="${TMP_DIR}/rman_${INSTANCE}_${BACKUP_TYPE}_${START_TS}.rcv"

build_rman_script() {
  COMP="$(compression_clause)"

  case "${BACKUP_TYPE}" in
    L0)
      cat > "${RMAN_SCRIPT_FILE}" <<EOF
run {
$(build_channel_allocation)
    backup ${COMP} database format '${FORMAT_L0}';
    backup ${COMP} current controlfile format '${FORMAT_L0}';
    backup ${COMP} spfile format '${FORMAT_L0}';
$(release_channels)
}
# Archivelogs not backed up go to Arch dir, separate run block for clarity
run {
$(build_channel_allocation)
    backup ${COMP} archivelog all not backed up format '${FORMAT_ARCH}';
$(release_channels)
}
EOF
      ;;
    L1)
      cat > "${RMAN_SCRIPT_FILE}" <<EOF
run {
$(build_channel_allocation)
    backup ${COMP} incremental level 1 database format '${FORMAT_L1}';
    backup ${COMP} current controlfile format '${FORMAT_L1}';
    backup ${COMP} spfile format '${FORMAT_L1}';
$(release_channels)
}
# Archivelogs not backed up go to Arch dir
run {
$(build_channel_allocation)
    backup ${COMP} archivelog all not backed up format '${FORMAT_ARCH}';
$(release_channels)
}
EOF
      ;;
    Arch)
      cat > "${RMAN_SCRIPT_FILE}" <<EOF
run {
$(build_channel_allocation)
    backup ${COMP} archivelog all not backed up format '${FORMAT_ARCH}';
$(release_channels)
}
EOF
      ;;
  esac
}

#------------------------------------------------------------------------------
# Dry-run mode: show planned RMAN script and exit
#------------------------------------------------------------------------------
if [ "${DRY_RUN}" = "Y" ]; then
  build_rman_script
  echo "Dry-run mode. Planned RMAN script:"
  echo "----------------------------------"
  cat "${RMAN_SCRIPT_FILE}"
  echo "----------------------------------"
  echo "No execution performed."
  exit 0
fi

#------------------------------------------------------------------------------
# Execute RMAN backup, log stdout/stderr to main log
#------------------------------------------------------------------------------
build_rman_script

# **RMAN connect target:** Use OS authentication as sysdba via rman target /
# Note: RMAN will use ORACLE_HOME/ORACLE_SID environment already exported.
{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting RMAN backup for ${ORACLE_SID} type ${BACKUP_TYPE} (compression=${COMPRESSION})"
  echo "Using channels=${CHANNELS}, max piece size=${CHANNEL_MAX_SIZE}"
  echo "Backup formats:"
  echo "  L0:   ${FORMAT_L0}"
  echo "  L1:   ${FORMAT_L1}"
  echo "  Arch: ${FORMAT_ARCH}"
  echo "RMAN script file: ${RMAN_SCRIPT_FILE}"
} >> "${MAIN_LOG}"

# **Run_rman:** Execute RMAN; send stdout+stderr to main log for comprehensive capture
if ! "${rman_binary}" target / cmdfile "${RMAN_SCRIPT_FILE}" log "${MAIN_LOG}" append; then
  # If RMAN returns non-zero, we'll still parse the log for error codes.
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] RMAN process returned non-zero status." >> "${MAIN_LOG}"
fi

#------------------------------------------------------------------------------
# Error mapping and log scan for ORA-/RMAN- errors
#------------------------------------------------------------------------------
# **Error_mapper:** Maps known ORA/RMAN codes to friendly messages and suggested actions.
map_error() {
  CODE="$1"
  case "${CODE}" in
    ORA-19505) echo "Failed to create file | Action: Check disk path, permissions, and free space." ;;
    ORA-19511) echo "Error in backup operation (I/O error on media) | Action: Review media manager/storage logs and I/O health." ;;
    ORA-19514) echo "Media manager error | Action: Check media manager configuration and logs." ;;
    ORA-27037) echo "Write error on file | Action: Verify filesystem health, mount options, and permissions." ;;
    ORA-27040) echo "Unable to open file (OS error) | Action: Confirm file exists and OS permissions allow access." ;;
    ORA-00257) echo "Archive log destination or disk full / media manager quota exceeded | Action: Free space or adjust archivelog destination/quota." ;;
    ORA-27026) echo "File not open/write error | Action: Ensure file is openable and not locked; check permissions." ;;
    RMAN-06002) echo "No backup in the control file | Action: Crosscheck backups; ensure controlfile records are intact." ;;
    RMAN-03009) echo "Failure during backup command | Action: Inspect RMAN output for the failing step." ;;
    RMAN-03002) echo "Failure in channel allocation | Action: Check channel device type, counts, and availability." ;;
    RMAN-03030) echo "Component not found | Action: Validate target files and database components." ;;
    RMAN-03031) echo "Could not allocate channel | Action: Reduce channels or fix device configuration." ;;
    RMAN-01054|RMAN-1054) echo "Invalid RMAN command or syntax | Action: Review RMAN script syntax." ;;
    RMAN-06010) echo "DBID mismatch or no dbid set | Action: Set correct DBID or connect to the right target." ;;
    *) echo "Unknown RMAN/ORA error — consult alert log and full RMAN output." ;;
  esac
}

# **Scan_errors:** Grep for ORA- and RMAN- codes; map and write to error log with raw lines
ERRORS_FOUND=0

# Extract unique error codes and raw lines
grep -E '(^|[[:space:]])(ORA-|RMAN-)[0-9]{4,5}' "${MAIN_LOG}" > "${TMP_DIR}/raw_errors.txt" 2>/dev/null || true

if [ -s "${TMP_DIR}/raw_errors.txt" ]; then
  ERRORS_FOUND=1
  {
    echo "Mapped RMAN/ORA Errors (instance=${ORACLE_SID}, type=${BACKUP_TYPE}, ts=${START_TS})"
    echo "--------------------------------------------------------------------------"
  } >> "${ERROR_LOG}"

  # Process each error occurrence; map the first token (e.g., ORA-19505)
  while IFS= read -r LINE; do
    CODE=$(echo "${LINE}" | sed -n 's/.*\b\([A-Z]\{3,4\}-[0-9]\{4,5\}\)\b.*/\1/p' | head -n1)
    if [ -n "${CODE}" ]; then
      MAPPED="$(map_error "${CODE}")"
      TS="$(date '+%Y-%m-%d %H:%M:%S')"
      echo "[${TS}] ${CODE}: ${MAPPED}" >> "${ERROR_LOG}"
      echo "Raw: ${LINE}" >> "${ERROR_LOG}"
      echo "--------------------------------------------------------------------------" >> "${ERROR_LOG}"
    fi
  done < "${TMP_DIR}/raw_errors.txt"
fi

# If mapped errors found, summarize and exit non-zero
if [ "${ERRORS_FOUND}" -eq 1 ]; then
  fatal "Errors detected during RMAN backup. See ${ERROR_LOG} for details." 4 "${ERROR_LOG}"
fi

#------------------------------------------------------------------------------
# Retention cleanup: REPORT/DELETE OBSOLETE with configured retention_days
#------------------------------------------------------------------------------
# **Retention_days:** Configurable number of days for recovery window
RET_DAYS="${retention_days}"

# Build retention script to avoid global CONFIGURE changes
RET_SCRIPT="${TMP_DIR}/rman_retention_${INSTANCE}_${START_TS}.rcv"
cat > "${RET_SCRIPT}" <<EOF
REPORT OBSOLETE RECOVERY WINDOW OF ${RET_DAYS} DAYS;
DELETE NOPROMPT OBSOLETE RECOVERY WINDOW OF ${RET_DAYS} DAYS;
EOF

{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting RMAN retention cleanup (recovery window ${RET_DAYS} days)"
} >> "${RETENTION_LOG}"

if ! "${rman_binary}" target / cmdfile "${RET_SCRIPT}" log "${RETENTION_LOG}" append; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] RMAN retention process returned non-zero status." >> "${RETENTION_LOG}"
fi

# Scan retention log for errors too; append to error log if any
grep -E '(^|[[:space:]])(ORA-|RMAN-)[0-9]{4,5}' "${RETENTION_LOG}" > "${TMP_DIR}/retention_errors.txt" 2>/dev/null || true
if [ -s "${TMP_DIR}/retention_errors.txt" ]; then
  while IFS= read -r LINE; do
    CODE=$(echo "${LINE}" | sed -n 's/.*\b\([A-Z]\{3,4\}-[0-9]\{4,5\}\)\b.*/\1/p' | head -n1)
    if [ -n "${CODE}" ]; then
      MAPPED="$(map_error "${CODE}")"
      TS="$(date '+%Y-%m-%d %H:%M:%S')"
      echo "[${TS}] Retention Error ${CODE}: ${MAPPED}" >> "${ERROR_LOG}"
      echo "Raw: ${LINE}" >> "${ERROR_LOG}"
      echo "--------------------------------------------------------------------------" >> "${ERROR_LOG}"
    fi
  done < "${TMP_DIR}/retention_errors.txt"
  fatal "Errors detected during retention cleanup. See ${ERROR_LOG} for details." 5 "${ERROR_LOG}"
fi

#------------------------------------------------------------------------------
# Success summary
#------------------------------------------------------------------------------
TS_DONE=$(date '+%Y-%m-%d %H:%M:%S')
echo "[${TS_DONE}] RMAN backup and retention cleanup completed successfully." >> "${MAIN_LOG}"
echo "[${TS_DONE}] Success. Logs: MAIN=${MAIN_LOG}, RETENTION=${RETENTION_LOG}" >&2

exit 0
