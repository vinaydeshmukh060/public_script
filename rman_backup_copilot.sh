#!/bin/sh
#
# rman_backup.sh - POSIX-compliant RMAN backup orchestration script
#
# Description:
#   Orchestrates Oracle RMAN backups (L0, L1, Arch) with validation, parallel channels,
#   log/error parsing, retention cleanup, and safety controls (PID locks, idempotence).
#   It is site-agnostic: all site-specific values belong in the configuration file.
#
# Usage:
#   rman_backup.sh -i <INSTANCE_NAME> -t <BACKUP_TYPE> [-c <CONFIG_FILE>] [--dry-run] [-h]
#
#   BACKUP_TYPE must be one of: L0, L1, Arch
#
# Examples:
#   rman_backup.sh -i ORCL -t L0 -c /etc/rman_backup/rman_backup.conf
#   rman_backup.sh -i PROD1 -t Arch --dry-run
#
# Configuration Notes:
#   Place all site-specific settings in rman_backup.conf (shell KEY=VALUE).
#   See accompanying rman_backup.conf.example for all keys and documentation.
#
# Sample crontab entry:
#   # Nightly Level 1 backup at 01:30
#   30 1 * * * /opt/dba/bin/rman_backup.sh -i PROD1 -t L1 -c /etc/rman_backup/rman_backup.conf >> /var/log/rman_backup/activity.log 2>&1
#
# Exit codes:
#   0   success
#   1   usage/config error
#   2   instance not running
#   3   database role not PRIMARY
#   10  RMAN errors detected
#   20  retention errors
#   100 unexpected error
#
# README:
#   - This script uses OS authentication to connect target "/ as sysdba".
#     If your environment requires a wallet or username/password, set
#     ADDITIONAL_RMAN_OPTIONS in the config (e.g., "target sys/<pass>@<tns>").
#   - Dry-run mode performs all validations and prints the RMAN command blocks,
#     but does not invoke RMAN and does not delete anything.
#   - Ensure LOG_DIR is readable/writable by the user running this script.
#
# Example RMAN command block generated (L0, compressed, 3 channels):
#   run {
#     allocate channel c1 device type disk maxpiecesize 100G;
#     allocate channel c2 device type disk maxpiecesize 100G;
#     allocate channel c3 device type disk maxpiecesize 100G;
#     backup as compressed backupset incremental level 0
#       format '/backup/rman/L0/30-Sep-2025/%d_%t_L0_%s'
#       database;
#     backup current controlfile format '/backup/rman/L0/30-Sep-2025/%d_%t_CTL_%s';
#     backup spfile format '/backup/rman/L0/30-Sep-2025/%d_%t_SPFILE_%s';
#   }
#   run {
#     allocate channel c1 device type disk maxpiecesize 100G;
#     allocate channel c2 device type disk maxpiecesize 100G;
#     allocate channel c3 device type disk maxpiecesize 100G;
#     backup as compressed backupset
#       format '/backup/rman/Arch/30-Sep-2025/%d_%t_ARCH_%s'
#       archivelog all;
#   }
#
# Portability / Safety:
#   - POSIX /bin/sh compatible; avoids bash-only features.
#   - No hard-coded credentials; uses OS auth by default.
#   - Creates date-based directories with restrictive permissions.
#   - PID lock avoids concurrent runs per instance/type.
#

# Shell strictness: avoid set -e to keep custom error handling and proper exit codes.
# Use nounset and safe IFS.
set -u
IFS='
     '

# Globals for exit codes
EXIT_OK=0
EXIT_USAGE=1
EXIT_NOT_RUNNING=2
EXIT_NOT_PRIMARY=3
EXIT_RMAN_ERR=10
EXIT_RETENTION_ERR=20
EXIT_UNEXPECTED=100

# Defaults (overridden by config)
CONFIG_FILE_DEFAULT_ETC="/etc/rman_backup/rman_backup.conf"
CONFIG_FILE_DEFAULT_LOCAL="./rman_backup.conf"

# State
INSTANCE_NAME=""
BACKUP_TYPE=""
CONFIG_FILE=""
DRY_RUN="N"

# Timestamps
NOW_EPOCH="$(date +%s)"
NOW_STR="$(date +%Y%m%d_%H%M%S)"
TODAY_DIR="$(date +%d-%b-%Y)"

# Logging files (initialized after config load)
LOG_DIR=""
MAIN_LOG=""
ERR_LOG=""
RETENTION_LOG=""
RETENTION_ERR_LOG=""
ACTIVITY_LOG=""   # Master activity log; configurable in config via LOG_DIR
PID_FILE=""

# Print usage
usage() {
  cat <<EOF
Usage: $(basename "$0") -i <INSTANCE_NAME> -t <BACKUP_TYPE> [-c <CONFIG_FILE>] [--dry-run] [-h]
  -i   Oracle instance name (ORACLE_SID)
  -t   Backup type: L0 | L1 | Arch
  -c   Configuration file path (optional). Defaults to:
       - ${CONFIG_FILE_DEFAULT_ETC} if present; else
       - ${CONFIG_FILE_DEFAULT_LOCAL} if present
  --dry-run  Perform validation and print RMAN commands without running them
  -h   Show this help

Examples:
  $(basename "$0") -i ORCL -t L0 -c /etc/rman_backup/rman_backup.conf
  $(basename "$0") -i PROD1 -t Arch --dry-run
EOF
}

# Logging helpers
ts() { date "+%Y-%m-%d %H:%M:%S"; }

log_activity() {
  # Message with optional exit code (second arg)
  # Always append to activity.log
  _msg="$1"
  _code="${2:-}"
  if [ -n "${ACTIVITY_LOG}" ]; then
    if [ -n "${_code}" ]; then
      printf "%s | %s | code=%s\n" "$(ts)" "${_msg}" "${_code}" >> "${ACTIVITY_LOG}"
    else
      printf "%s | %s\n" "$(ts)" "${_msg}" >> "${ACTIVITY_LOG}"
    fi
  fi
}

info() {
  _msg="$1"
  printf "%s INFO: %s\n" "$(ts)" "${_msg}"
  if [ -n "${MAIN_LOG}" ]; then
    printf "%s INFO: %s\n" "$(ts)" "${_msg}" >> "${MAIN_LOG}"
  fi
  log_activity "${_msg}"
}

warn() {
  _msg="$1"
  printf "%s WARN: %s\n" "$(ts)" "${_msg}"
  if [ -n "${MAIN_LOG}" ]; then
    printf "%s WARN: %s\n" "$(ts)" "${_msg}" >> "${MAIN_LOG}"
  fi
  log_activity "WARN: ${_msg}"
}

err() {
  _msg="$1"
  printf "%s ERROR: %s\n" "$(ts)" "${_msg}" >&2
  if [ -n "${ERR_LOG}" ]; then
    printf "%s ERROR: %s\n" "$(ts)" "${_msg}" >> "${ERR_LOG}"
  fi
  log_activity "ERROR: ${_msg}"
}

# Clean up PID file on exit
cleanup() {
  if [ -n "${PID_FILE}" ] && [ -f "${PID_FILE}" ]; then
    rm -f "${PID_FILE}"
  fi
}
trap cleanup EXIT

# Error mapping for common RMAN/ORA codes
map_error_code() {
  _code="$1"
  case "${_code}" in
    RMAN-00571) echo "RMAN fatal error stack encountered";;
    RMAN-03009) echo "Failure of RMAN command";;
    RMAN-03002) echo "Failure of backup/command";;
    RMAN-06059) echo "Log not found / object not found";;
    RMAN-06025) echo "Alias not found / catalog issue";;
    RMAN-06004) echo "Error with block change tracking / channel";;
    ORA-19511)  echo "Media management layer reported an error";;
    ORA-19566)  echo "Exceeded backup/restore parameter or size";;
    ORA-19502)  echo "Write error on file during backup";;
    ORA-19504)  echo "Failed to create file (permissions/space)";;
    ORA-27037)  echo "Unable to obtain file status (OS I/O error)";;
    ORA-19809)  echo "Limit exceeded for recovery files";;
    ORA-19815)  echo "Warning: db_recovery_file_dest_size is too small";;
    ORA-19804)  echo "Cannot reclaim space enough from FRA";;
    ORA-01110)  echo "Data file error";;
    ORA-01157)  echo "Cannot identify/lock data file";;
    ORA-00600)  echo "Internal error";;
    ORA-07445)  echo "Exception raised (OS signal)";;
    *)          echo "Unmapped error code";;
  esac
}

# Validate MAXSIZE unit (e.g., 100G, 500M, 1024K, 1T)
validate_maxsize() {
  _val="$1"
  # Must be digits followed by K/M/G/T (uppercase or lowercase)
  case "${_val}" in
    *[!0-9KkMmGgTt]*|"")
      return 1
      ;;
    [0-9]*[KkMmGgTt])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Parse /etc/oratab to fetch ORACLE_HOME for the given instance
# Format: SID:ORACLE_HOME:Y|N (comments start with #)
get_oracle_home_from_oratab() {
  _sid="$1"
  _oratab="$2"
  if [ ! -r "${_oratab}" ]; then
    err "ORATAB file not readable: ${_oratab}"
    return 1
  fi
  # Use awk to find line with SID
  _home="$(awk -F: -v sid="${_sid}" '
    $0 !~ /^#/ && $1 == sid { print $2; exit }
  ' "${_oratab}")"
  if [ -z "${_home}" ]; then
    err "Instance '${_sid}' not found in ${_oratab}"
    return 1
  fi
  printf "%s" "${_home}"
}

# Check if instance is running via PMON or a minimal SQL*Plus connection
check_instance_running() {
  _sid="$1"
  _home="$2"
  # PMON check
  if ps -ef 2>/dev/null | grep "ora_pmon_${_sid}" | grep -v grep >/dev/null 2>&1; then
    return 0
  fi
  # Fallback: try to connect and query instance name
  if [ -x "${_home}/bin/sqlplus" ]; then
    ORACLE_SID="${_sid}"
    ORACLE_HOME="${_home}"
    export ORACLE_SID ORACLE_HOME
    # Attempt minimal connection
    echo "set pagesize 0 feedback off verify off heading off echo off
select name from v\\$database;
exit" | "${ORACLE_HOME}/bin/sqlplus" -s / as sysdba >/dev/null 2>&1
    if [ "$?" -eq 0 ]; then
      return 0
    fi
  fi
  return 1
}

# Query database role (PRIMARY required)
get_database_role() {
  _sid="$1"
  _home="$2"
  ORACLE_SID="${_sid}"
  ORACLE_HOME="${_home}"
  export ORACLE_SID ORACLE_HOME
  if [ ! -x "${ORACLE_HOME}/bin/sqlplus" ]; then
    err "sqlplus not found at ${ORACLE_HOME}/bin/sqlplus"
    return 1
  fi
  _role="$(
    echo "set pagesize 0 feedback off verify off heading off echo off
select database_role from v\\$database;
exit" | "${ORACLE_HOME}/bin/sqlplus" -s / as sysdba 2>/dev/null
  )"
  # Trim spaces/newlines
  _role_clean="$(printf "%s" "${_role}" | tr -d ' \r' | tr -d '\n')"
  printf "%s" "${_role_clean}"
}

# Build channel allocation block
build_channel_block() {
  _channels="$1"
  _maxsize="$2"
  _blk=""
  _i=1
  while [ "${_i}" -le "${_channels}" ]; do
    _blk="${_blk}allocate channel c${_i} device type disk maxpiecesize ${_maxsize};
"
    _i=$(( _i + 1 ))
  done
  printf "%s" "${_blk}"
}

# Ensure directory exists with safe permissions
ensure_dir() {
  _dir="$1"
  if [ ! -d "${_dir}" ]; then
    umask 027
    if ! mkdir -p "${_dir}"; then
      err "Failed to create directory: ${_dir}"
      return 1
    fi
  fi
  return 0
}

# Determine default config file if -c not provided
resolve_config_file() {
  if [ -n "${CONFIG_FILE}" ]; then
    printf "%s" "${CONFIG_FILE}"
    return 0
  fi
  if [ -r "${CONFIG_FILE_DEFAULT_ETC}" ]; then
    printf "%s" "${CONFIG_FILE_DEFAULT_ETC}"
    return 0
  fi
  if [ -r "${CONFIG_FILE_DEFAULT_LOCAL}" ]; then
    printf "%s" "${CONFIG_FILE_DEFAULT_LOCAL}"
    return 0
  fi
  # Fallback to etc path even if not readable, will error later
  printf "%s" "${CONFIG_FILE_DEFAULT_ETC}"
}

# Parse args (supports --dry-run)
parse_args() {
  # First pass: handle --dry-run specifically
  # Save original args
  ARGS="$*"
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN="Y";;
    esac
  done

  # POSIX getopts for short options
  # shellcheck disable=SC2039
  while getopts "i:t:c:h" opt; do
    case "$opt" in
      i) INSTANCE_NAME="$OPTARG";;
      t) BACKUP_TYPE="$OPTARG";;
      c) CONFIG_FILE="$OPTARG";;
      h) usage; exit "${EXIT_USAGE}";;
      *) usage; exit "${EXIT_USAGE}";;
    esac
  done
}

# Validate backup type
validate_backup_type() {
  case "${BACKUP_TYPE}" in
    L0|L1|Arch) return 0;;
    *) err "Invalid BACKUP_TYPE: ${BACKUP_TYPE}. Must be one of L0, L1, Arch."; return 1;;
  esac
}

# Build RMAN format string, substituting placeholders where applicable
# Supported placeholders:
#   %d = DB_NAME (handled by RMAN)
#   %t = timestamp (RMAN)
#   %s = backup set sequence (RMAN)
#   %i = instance name (we expand to INSTANCE_NAME via RMAN 'tag' or path; here embed literally)
# Note: RMAN understands %d, %t, %s. '%i' is not standard; we inject INSTANCE_NAME into directory path.
#       If you want instance in filename, include it explicitly (e.g., '${INSTANCE_NAME}_%d_%t_L0_%s').
inject_instance_in_format() {
  _fmt="$1"
  # Replace literal %i with INSTANCE_NAME
  printf "%s" "$(printf "%s" "${_fmt}" | sed "s/%i/${INSTANCE_NAME}/g")"
}

# Build backup directories and paths
setup_directories() {
  # Base and typed dirs derived from config
  # Create date subdirectories
  L0_DIR_DAY="${BACKUP_L0_DIR}/${TODAY_DIR}"
  L1_DIR_DAY="${BACKUP_L1_DIR}/${TODAY_DIR}"
  ARCH_DIR_DAY="${BACKUP_ARCH_DIR}/${TODAY_DIR}"
  # Logs dir
  ensure_dir "${LOG_DIR}" || return 1
  ensure_dir "${BACKUP_L0_DIR}" || return 1
  ensure_dir "${BACKUP_L1_DIR}" || return 1
  ensure_dir "${BACKUP_ARCH_DIR}" || return 1
  ensure_dir "${L0_DIR_DAY}" || return 1
  ensure_dir "${L1_DIR_DAY}" || return 1
  ensure_dir "${ARCH_DIR_DAY}" || return 1
  return 0
}

# Build RMAN RUN blocks for different backup types
build_rman_block_database() {
  # L0 or L1
  _level="$1"   # 0 or 1
  _compressed="$2"  # Y or N
  _channels="$3"
  _maxsize="$4"
  _fmt_db="$5"   # format for datafiles
  _fmt_ctl="$6"  # format for controlfile
  _fmt_spf="$7"  # format for spfile
  _blk_ch="$(build_channel_block "${_channels}" "${_maxsize}")"
  _comp_clause=""
  if [ "${_compressed}" = "Y" ]; then
    _comp_clause="as compressed backupset"
  else
    _comp_clause=""
  fi
  cat <<EOF
run {
${_blk_ch}backup ${_comp_clause} incremental level ${_level}
  format '${_fmt_db}'
  database;
backup current controlfile format '${_fmt_ctl}';
EOF
  if [ "${SPFILE_BACKUP:-Y}" = "Y" ]; then
    printf "backup spfile format '%s';\n" "${_fmt_spf}"
  fi
  printf "}\n"
}

build_rman_block_archivelog() {
  _compressed="$1"  # Y or N
  _channels="$2"
  _maxsize="$3"
  _fmt_arch="$4"
  _blk_ch="$(build_channel_block "${_channels}" "${_maxsize}")"
  _comp_clause=""
  if [ "${_compressed}" = "Y" ]; then
    _comp_clause="as compressed backupset"
  else
    _comp_clause=""
  fi
  cat <<EOF
run {
${_blk_ch}backup ${_comp_clause}
  format '${_fmt_arch}'
  archivelog all;
}
EOF
}

# Build RMAN retention block
build_rman_block_retention() {
  _days="$1"
  cat <<EOF
report obsolete recovery window of ${_days} days;
delete noprompt obsolete recovery window of ${_days} days;
EOF
}

# Run RMAN with generated block, capture logs
run_rman() {
  _block_file="$1"
  _log_file="$2"
  _err_file="$3"
  # Additional RMAN options are freeform (e.g., catalog, target, msglog, etc.)
  # We will not echo secrets into logs.
  _opts="${ADDITIONAL_RMAN_OPTIONS:-}"
  # Enforce msglog to our log file
  # Some RMAN versions support 'log' redirection; we will use shell redirection instead.
  "${RMAN_BINARY}" ${_opts} target / <<RMAN_EOF >"${_log_file}" 2>&1
$(cat "${_block_file}")
RMAN_EOF
  _rc="$?"
  if [ "${_rc}" -ne 0 ]; then
    err "RMAN exited with code ${_rc}"
  fi
  return "${_rc}"
}

# Scan RMAN log for errors and produce summarized err log
scan_rman_errors() {
  _log_file="$1"
  _err_file="$2"
  : > "${_err_file}"
  if [ ! -r "${_log_file}" ]; then
    err "RMAN log not found for error scan: ${_log_file}"
    return 1
  fi

  # Extract lines with error tokens
  grep -E "RMAN-|ORA-|FATAL|ERROR|ALERT" "${_log_file}" 2>/dev/null > "${_err_file}.raw" || true

  if [ ! -s "${_err_file}.raw" ]; then
    # No error lines
    rm -f "${_err_file}.raw"
    return 0
  fi

  printf "%s\n" "Summarized error report (counts, first occurrence, mapped descriptions):" >> "${_err_file}"
  # Aggregate by code (first token like RMAN-xxxxx or ORA-xxxxx), count occurrences, and print first line
  # POSIX awk used
  awk '
  BEGIN { }
  {
    # Find code token in the line
    match($0, /(RMAN-[0-9]{5}|ORA-[0-9]{5}|FATAL|ERROR|ALERT)/, m)
    if (m[1] != "") {
      code=m[1]
      count[code]++
      if (!(code in first)) { first[code]=$0 }
    }
  }
  END {
    for (c in count) {
      printf("Code: %s | Count: %d\nFirst: %s\n", c, count[c], first[c])
    }
  }' "${_err_file}.raw" >> "${_err_file}"

  # Append mapped descriptions
  printf "\nMapped descriptions:\n" >> "${_err_file}"
  while IFS= read -r line; do
    case "${line}" in
      Code:\ RMAN-*|Code:\ ORA-*|Code:\ FATAL|Code:\ ERROR|Code:\ ALERT)
        code="$(printf "%s" "${line}" | awk '{print $2}')"
        desc="$(map_error_code "${code}")"
        printf "%s -> %s\n" "${code}" "${desc}" >> "${_err_file}"
        ;;
    esac
  done < "${_err_file}"

  rm -f "${_err_file}.raw"
  return 0
}

# Retention: report and delete obsolete
perform_retention() {
  _days="$1"
  _log="$2"
  _err="$3"
  # Build retention block file
  _blk="$(mktemp "/tmp/rman_retention_${INSTANCE_NAME}_${BACKUP_TYPE}_XXXXXX")" || return 1
  build_rman_block_retention "${_days}" > "${_blk}"

  if [ "${DRY_RUN}" = "Y" ]; then
    info "Dry-run: retention block (report and delete):"
    printf "%s\n" "----- RMAN RETENTION BLOCK BEGIN -----"
    cat "${_blk}"
    printf "%s\n" "----- RMAN RETENTION BLOCK END -----"
    rm -f "${_blk}"
    return 0
  fi

  # Run RMAN report obsolete
  # We will split into two commands: first report, then delete (only if report success)
  # Report
  "${RMAN_BINARY}" ${ADDITIONAL_RMAN_OPTIONS:-} target / <<RMAN_EOF >"${_log}".tmp 2>&1
report obsolete recovery window of ${_days} days;
RMAN_EOF
  _rc_report="$?"
  cat "${_log}".tmp >> "${_log}"
  rm -f "${_log}".tmp

  if [ "${_rc_report}" -ne 0 ]; then
    printf "%s\n" "Retention report failed with code ${_rc_report}" >> "${_err}"
    err "Retention report failed (code ${_rc_report}). Skipping delete."
    return "${EXIT_RETENTION_ERR}"
  fi

  # Delete
  "${RMAN_BINARY}" ${ADDITIONAL_RMAN_OPTIONS:-} target / <<RMAN_EOF >>"${_log}" 2>>"${_err}"
delete noprompt obsolete recovery window of ${_days} days;
RMAN_EOF
  _rc_delete="$?"
  if [ "${_rc_delete}" -ne 0 ]; then
    printf "%s\n" "Retention delete failed with code ${_rc_delete}" >> "${_err}"
    err "Retention delete failed (code ${_rc_delete})."
    return "${EXIT_RETENTION_ERR}"
  fi

  return 0
}

# Notification stub (integrate with your monitoring/email system here)
notify_failure_stub() {
  _subject="$1"
  _body="$2"
  # Example (commented):
  # /usr/bin/mail -s "${_subject}" dba-team@example.com <<MAIL
  # ${_body}
  # MAIL
  :
}

# Main
main() {
  parse_args "$@"

  if [ -z "${INSTANCE_NAME}" ] || [ -z "${BACKUP_TYPE}" ]; then
    usage
    exit "${EXIT_USAGE}"
  fi

  if ! validate_backup_type; then
    usage
    exit "${EXIT_USAGE}"
  fi

  CONFIG_FILE="$(resolve_config_file)"
  if [ ! -r "${CONFIG_FILE}" ]; then
    printf "Config file not found or unreadable: %s\n" "${CONFIG_FILE}" >&2
    exit "${EXIT_USAGE}"
  fi

  # shellcheck source=/dev/null
  . "${CONFIG_FILE}"

  # Defaults for optional keys
  COMPRESS="${COMPRESS:-N}"
  SPFILE_BACKUP="${SPFILE_BACKUP:-Y}"
  ADDITIONAL_RMAN_OPTIONS="${ADDITIONAL_RMAN_OPTIONS:-}"

  # Validate mandatory config keys
  REQUIRED_KEYS="BASE_DIR BACKUP_L0_DIR BACKUP_L1_DIR BACKUP_ARCH_DIR BACKUP_FORMAT_L0 BACKUP_FORMAT_L1 BACKUP_FORMAT_ARCH CHANNELS CHANNEL_MAXSIZE RETENTION_DAYS ORATAB LOG_DIR RMAN_BINARY"
  for k in ${REQUIRED_KEYS}; do
    # shellcheck disable=SC3028
    eval "v=\${${k}:-}"
    if [ -z "${v}" ]; then
      printf "Missing required config key: %s\n" "${k}" >&2
      exit "${EXIT_USAGE}"
    fi
  done

  # Validate channel sizes
  if ! validate_maxsize "${CHANNEL_MAXSIZE}"; then
    printf "Invalid CHANNEL_MAXSIZE: %s (expected e.g., 100G, 500M, 1024K, 1T)\n" "${CHANNEL_MAXSIZE}" >&2
    exit "${EXIT_USAGE}"
  fi

  # Cap sensibly (example: prevent > 10T)
  case "${CHANNEL_MAXSIZE}" in
    [0-9]*[Tt])
      # Extract number
      num=$(printf "%s" "${CHANNEL_MAXSIZE}" | sed 's/[Tt]$//')
      # If > 10, cap
      # POSIX sh: numeric compare
      # If non-integer, reject
      case "${num}" in
        *[!0-9]*|"") printf "Invalid CHANNEL_MAXSIZE number\n" >&2; exit "${EXIT_USAGE}";;
      esac
      if [ "${num}" -gt 10 ]; then
        warn "CHANNEL_MAXSIZE ${CHANNEL_MAXSIZE} too large; capping to 10T"
        CHANNEL_MAXSIZE="10T"
      fi
      ;;
  esac

  # Logging paths
  ensure_dir "${LOG_DIR}" || exit "${EXIT_USAGE}"
  MAIN_LOG="${LOG_DIR}/${INSTANCE_NAME}_${BACKUP_TYPE}_${NOW_STR}.log"
  ERR_LOG="${LOG_DIR}/${INSTANCE_NAME}_${BACKUP_TYPE}_${NOW_STR}.err.log"
  RETENTION_LOG="${LOG_DIR}/retention_${NOW_STR}.log"
  RETENTION_ERR_LOG="${LOG_DIR}/retention_${NOW_STR}.err.log"
  ACTIVITY_LOG="${LOG_DIR}/activity.log"
  PID_FILE="${LOG_DIR}/rman_backup_${INSTANCE_NAME}_${BACKUP_TYPE}.pid"

  log_activity "Start: instance=${INSTANCE_NAME}, type=${BACKUP_TYPE}, dryrun=${DRY_RUN}"

  # PID lock
  if [ -f "${PID_FILE}" ]; then
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || echo "")"
    if [ -n "${old_pid}" ] && kill -0 "${old_pid}" 2>/dev/null; then
      err "Another backup process is running (PID ${old_pid})."
      log_activity "Concurrent run detected, exiting." "${EXIT_USAGE}"
      exit "${EXIT_USAGE}"
    else
      warn "Stale PID file found; removing."
      rm -f "${PID_FILE}"
    fi
  fi
  printf "%s\n" "$$" > "${PID_FILE}"

  # Instance / environment validation
  ORACLE_HOME="$(get_oracle_home_from_oratab "${INSTANCE_NAME}" "${ORATAB}")" || {
    log_activity "Instance not in oratab: ${INSTANCE_NAME}" "${EXIT_USAGE}"
    exit "${EXIT_USAGE}"
  }

  if ! check_instance_running "${INSTANCE_NAME}" "${ORACLE_HOME}"; then
    err "Instance ${INSTANCE_NAME} is not running."
    log_activity "Instance not running: ${INSTANCE_NAME}" "${EXIT_NOT_RUNNING}"
    exit "${EXIT_NOT_RUNNING}"
  fi

  ROLE="$(get_database_role "${INSTANCE_NAME}" "${ORACLE_HOME}")"
  if [ -z "${ROLE}" ]; then
    err "Could not determine database role."
    log_activity "Role check failed" "${EXIT_UNEXPECTED}"
    exit "${EXIT_UNEXPECTED}"
  fi
  if [ "${ROLE}" != "PRIMARY" ]; then
    err "Database role is '${ROLE}', not PRIMARY. Aborting backup."
    log_activity "Not PRIMARY: ${ROLE}" "${EXIT_NOT_PRIMARY}"
    exit "${EXIT_NOT_PRIMARY}"
  fi

  # Directories setup
  setup_directories || {
    log_activity "Directory setup failed" "${EXIT_USAGE}"
    exit "${EXIT_USAGE}"
  }

  # Build format strings with instance injection
  FMT_L0="$(inject_instance_in_format "${BACKUP_FORMAT_L0}")"
  FMT_L1="$(inject_instance_in_format "${BACKUP_FORMAT_L1}")"
  FMT_ARCH="$(inject_instance_in_format "${BACKUP_FORMAT_ARCH}")"

  # Resolve full format paths for date-based directories
  FMT_PATH_L0="${L0_DIR_DAY}/${FMT_L0}"
  FMT_PATH_L1="${L1_DIR_DAY}/${FMT_L1}"
  FMT_PATH_CTL="${L0_DIR_DAY}/%d_%t_CTL_%s"
  FMT_PATH_SPF="${L0_DIR_DAY}/%d_%t_SPFILE_%s"
  FMT_PATH_ARCH="${ARCH_DIR_DAY}/${FMT_ARCH}"

  # Build RMAN block according to type
  BLOCK_FILE="$(mktemp "/tmp/rman_${INSTANCE_NAME}_${BACKUP_TYPE}_XXXXXX")" || {
    err "Failed to create temp RMAN block file"
    exit "${EXIT_UNEXPECTED}"
  }

  case "${BACKUP_TYPE}" in
    L0)
      build_rman_block_database "0" "${COMPRESS}" "${CHANNELS}" "${CHANNEL_MAXSIZE}" "${FMT_PATH_L0}" "${FMT_PATH_CTL}" "${FMT_PATH_SPF}" > "${BLOCK_FILE}"
      ;;
    L1)
      # For L1, controlfile/SPFILE also go to L1 dir for consistency with requirement "same day's directory"
      FMT_PATH_CTL="${L1_DIR_DAY}/%d_%t_CTL_%s"
      FMT_PATH_SPF="${L1_DIR_DAY}/%d_%t_SPFILE_%s"
      build_rman_block_database "1" "${COMPRESS}" "${CHANNELS}" "${CHANNEL_MAXSIZE}" "${FMT_PATH_L1}" "${FMT_PATH_CTL}" "${FMT_PATH_SPF}" > "${BLOCK_FILE}"
      ;;
    Arch)
      build_rman_block_archivelog "${COMPRESS}" "${CHANNELS}" "${CHANNEL_MAXSIZE}" "${FMT_PATH_ARCH}" > "${BLOCK_FILE}"
      ;;
  esac

  # For L0/L1, we also need archivelog backup to ARCH dir after database backup
  ARCH_BLOCK_FILE=""
  if [ "${BACKUP_TYPE}" = "L0" ] || [ "${BACKUP_TYPE}" = "L1" ]; then
    ARCH_BLOCK_FILE="$(mktemp "/tmp/rman_arch_${INSTANCE_NAME}_${BACKUP_TYPE}_XXXXXX")" || {
      err "Failed to create temp RMAN arch block file"
      exit "${EXIT_UNEXPECTED}"
    }
    build_rman_block_archivelog "${COMPRESS}" "${CHANNELS}" "${CHANNEL_MAXSIZE}" "${FMT_PATH_ARCH}" > "${ARCH_BLOCK_FILE}"
  fi

  # Dry-run: print blocks and exit success
  if [ "${DRY_RUN}" = "Y" ]; then
    info "Dry-run mode: showing RMAN blocks (no execution)."
    printf "%s\n" "----- RMAN BLOCK BEGIN (${BACKUP_TYPE}) -----"
    cat "${BLOCK_FILE}"
    printf "%s\n" "----- RMAN BLOCK END -----"
    if [ -n "${ARCH_BLOCK_FILE}" ] && [ -f "${ARCH_BLOCK_FILE}" ]; then
      printf "%s\n" "----- RMAN ARCHIVELOG BLOCK BEGIN -----"
      cat "${ARCH_BLOCK_FILE}"
      printf "%s\n" "----- RMAN ARCHIVELOG BLOCK END -----"
    fi
    rm -f "${BLOCK_FILE}" "${ARCH_BLOCK_FILE:-}"
    log_activity "Dry-run completed" "${EXIT_OK}"
    exit "${EXIT_OK}"
  fi

  # Run RMAN main block
  info "Running RMAN for ${BACKUP_TYPE}..."
  run_rman "${BLOCK_FILE}" "${MAIN_LOG}" "${ERR_LOG}"
  RC_MAIN="$?"
  rm -f "${BLOCK_FILE}"

  # Scan for RMAN errors
  scan_rman_errors "${MAIN_LOG}" "${ERR_LOG}"
  if [ -s "${ERR_LOG}" ]; then
    warn "Errors detected in RMAN log; see ${ERR_LOG}"
    log_activity "RMAN errors detected" "${EXIT_RMAN_ERR}"
    # Optional notification stub
    notify_failure_stub "RMAN ${INSTANCE_NAME} ${BACKUP_TYPE} errors" "See ${ERR_LOG}"
    exit "${EXIT_RMAN_ERR}"
  fi

  # If L0/L1, run archivelog backup
  if [ -n "${ARCH_BLOCK_FILE}" ] && [ -f "${ARCH_BLOCK_FILE}" ]; then
    info "Running RMAN archivelog backup..."
    run_rman "${ARCH_BLOCK_FILE}" "${MAIN_LOG}" "${ERR_LOG}"
    RC_ARCH="$?"
    rm -f "${ARCH_BLOCK_FILE}"
    scan_rman_errors "${MAIN_LOG}" "${ERR_LOG}"
    if [ -s "${ERR_LOG}" ]; then
      warn "Errors detected during archivelog backup; see ${ERR_LOG}"
      log_activity "RMAN errors detected (archivelog)" "${EXIT_RMAN_ERR}"
      notify_failure_stub "RMAN ${INSTANCE_NAME} archivelog errors" "See ${ERR_LOG}"
      exit "${EXIT_RMAN_ERR}"
    fi
  fi

  # Retention only after successful backups
  info "Performing retention cleanup (report then delete) with window ${RETENTION_DAYS} days..."
  perform_retention "${RETENTION_DAYS}" "${RETENTION_LOG}" "${RETENTION_ERR_LOG}"
  RC_RET="$?"
  if [ "${RC_RET}" -ne 0 ]; then
    warn "Retention step encountered errors. See ${RETENTION_LOG} and ${RETENTION_ERR_LOG}"
    # Append retention errors to main error log
    if [ -r "${RETENTION_ERR_LOG}" ]; then
      cat "${RETENTION_ERR_LOG}" >> "${ERR_LOG}"
    fi
    log_activity "Retention errors" "${EXIT_RETENTION_ERR}"
    exit "${EXIT_RETENTION_ERR}"
  fi

  info "Backup completed successfully for ${INSTANCE_NAME} (${BACKUP_TYPE}). Logs: ${MAIN_LOG}"
  log_activity "Completed successfully" "${EXIT_OK}"
  exit "${EXIT_OK}"
}

main "$@"
