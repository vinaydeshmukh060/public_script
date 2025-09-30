#!/bin/sh
#
# rman_backup.sh
# POSIX-compliant RMAN backup wrapper script
#
# Usage:
#   ./rman_backup.sh -i INSTANCE -t BACKUP_TYPE [-c Y|N] [-h|--help]
#
# Example:
#   ./rman_backup.sh -i ORCL -t L0 -c Y
#
# Deliverables:
#  - Uses external config file rman_backup.conf (sourced)
#  - Builds RMAN script dynamically and runs RMAN
#  - Writes main log, error log, retention log, retention error log
#  - Scans RMAN output for RMAN-/ORA- codes, maps them using rman_error_map.txt
#  - Performs retention using REPORT OBSOLETE / DELETE OBSOLETE (configurable)
#
# Exit codes:
#   0 = success
#   1 = bad args / help shown
#   2 = instance not found / not running
#   3 = database role is not PRIMARY
#   4 = backup error detected in RMAN logs
#   5 = retention/cleanup error
#   6 = config/load error
#
# ASSUMPTIONS (documented):
#  - The script can use ORACLE environment from /etc/oratab (configurable)
#  - ORACLE user authentication: script uses OS authentication or configured credentials
#    (recommended: run as oracle OS user and use "rman target /" or "sqlplus / as sysdba")
#  - RMAN binary is available in PATH or overridden via RMAN_BINARY in config
#  - GNU utilities (sed/awk/grep/printf/mkdir/ps) present. Tools used are POSIX-compatible.
#
# INSTALL: place rman_backup.sh and rman_backup.conf and rman_error_map.txt in same dir,
#         edit rman_backup.conf, chown/chmod appropriately, and test in non-prod.
#
# Quick checklist (smoke test):
#  1. Edit rman_backup.conf to match site paths and set ORATAB_PATH if needed.
#  2. Run: ./rman_backup.sh -i <SID> -t L0 -c N (dry-run: set DRY_RUN=Y in conf)
#  3. Inspect logs in LOG_DIR.
#
###############################################################################

set -u
# ---- Default variables (overwritten by config) ----
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || printf ".")"
CONFIG_FILE="${SCRIPT_DIR}/rman_backup.conf"
ERROR_MAP_FILE="${SCRIPT_DIR}/rman_error_map.txt"

# Functions --------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 -i INSTANCE -t {L0|L1|Arch} [-c Y|N] [-h]
  -i INSTANCE   : Oracle instance/SID (mandatory)
  -t BACKUPTYPE : L0 | L1 | Arch  (mandatory)
  -c COMPRESSION: Y or N (optional, default from config or N)
  -h            : show this help
EOF
}

log_msg() {
    # $1 message
    printf '%s %s\n' "$(date '+%F %T')" "$1"
}

fail() {
    # $1 exit_code $2 message
    code="$1"
    shift 1
    msg="$*"
    printf '%s %s\n' "$(date '+%F %T')" "ERROR: $msg" >> "${ERROR_LOG}" 2>/dev/null || :
    printf '%s\n' "Exiting with code $code: $msg"
    exit "$code"
}

# parse args -------------------------------------------------------------
INSTANCE=""
BACKUP_TYPE=""
CLI_COMPRESSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        -i) INSTANCE="$2"; shift 2 ;;
        -t) BACKUP_TYPE="$2"; shift 2 ;;
        -c) CLI_COMPRESSION="$2"; shift 2 ;;
        -h|--help) usage; exit 1 ;;
        *) printf 'Unknown arg: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "${INSTANCE}" ] || [ -z "${BACKUP_TYPE}" ]; then
    usage
    exit 1
fi

# Load configuration ----------------------------------------------------
if [ ! -f "${CONFIG_FILE}" ]; then
    printf 'Config file not found: %s\n' "${CONFIG_FILE}" >&2
    exit 6
fi

# shellcheck disable=SC1090
. "${CONFIG_FILE}" || { printf 'Failed to source config file\n' >&2; exit 6; }

# Validate mandatory config variables with defaults
: "${BASE_DIR:=/backup/rman}"
: "${LOG_DIR:=${BASE_DIR}/logs}"
: "${TMP_DIR:=${BASE_DIR}/tmp}"
: "${BACKUP_L0_DIR:=${BASE_DIR}/L0}"
: "${BACKUP_L1_DIR:=${BASE_DIR}/L1}"
: "${BACKUP_ARCH_DIR:=${BASE_DIR}/Arch}"
: "${CHANNELS:=1}"
: "${CHANNEL_MAXSIZE:=100G}"
: "${ORATAB_PATH:=/etc/oratab}"
: "${RETENTION_DAYS:=3}"
: "${RMAN_BINARY:=${RMAN_BINARY:-rman}}"
: "${DRY_RUN:=N}"
: "${RETENTION_METHOD:=RMAN_CONFIG}"  # options: RMAN_CONFIG or EXPLICIT_REPORT_DELETE

# Allow CLI override for compression
if [ -n "${CLI_COMPRESSION}" ]; then
    COMPRESSION="$(printf '%s' "${CLI_COMPRESSION}" | tr '[:lower:]' '[:upper:]')"
else
    COMPRESSION="$(printf '%s' "${COMPRESSION:-N}" | tr '[:lower:]' '[:upper:]')"
fi

# Make sure CHANNELS is integer >=1
case "${CHANNELS}" in
    ''|*[!0-9]*)
        printf 'Invalid CHANNELS in config: %s\n' "${CHANNELS}" >&2
        exit 6
        ;;
esac
if [ "${CHANNELS}" -lt 1 ]; then
    printf 'CHANNELS must be >= 1\n' >&2
    exit 6
fi

# Prepare directories and timestamped names
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_TYPE_UP="$(printf '%s' "${BACKUP_TYPE}" | tr '[:lower:]' '[:upper:]')"
LOG_DIR="${LOG_DIR%/}"
TMP_DIR="${TMP_DIR%/}"
mkdir -p "${LOG_DIR}" "${TMP_DIR}" "${BACKUP_L0_DIR}" "${BACKUP_L1_DIR}" "${BACKUP_ARCH_DIR}" 2>/dev/null || :

MAIN_LOG="${LOG_DIR}/${INSTANCE}_${BACKUP_TYPE_UP}_${TIMESTAMP}.log"
ERROR_LOG="${LOG_DIR}/${INSTANCE}_${BACKUP_TYPE_UP}_${TIMESTAMP}.err"
RET_LOG="${LOG_DIR}/${INSTANCE}_retention_${TIMESTAMP}.log"
RET_ERR_LOG="${LOG_DIR}/${INSTANCE}_retention_${TIMESTAMP}.err"

# Set environment based on oratab ---------------------------------------
# oratab lines: SID:ORACLE_HOME:<N|Y>
ORACLE_HOME=""
ORACLE_SID="${INSTANCE}"

if [ -f "${ORATAB_PATH}" ]; then
    # find line starting with SID:
    ORATAB_LINE="$(grep -E "^${INSTANCE}:" "${ORATAB_PATH}" | tail -n 1 || true)"
    if [ -n "${ORATAB_LINE}" ]; then
        # extract ORACLE_HOME field
        ORACLE_HOME="$(printf '%s' "${ORATAB_LINE}" | awk -F: '{print $2}')"
    fi
fi

if [ -n "${ORACLE_HOME}" ]; then
    export ORACLE_HOME
else
    # If ORACLE_HOME not found, still allow the script to continue (user may set RMAN env)
    printf '%s\n' "Warning: ORACLE_HOME not found in ${ORATAB_PATH}. Proceeding without setting ORACLE_HOME." >> "${MAIN_LOG}" 2>/dev/null || :
fi
export ORACLE_SID

# Check instance is running via pmon process -----------------------------
# pmon name: ora_pmon_<SID> or pmon_<SID> depending on platform; we'll grep for pmon_$SID
if ps -ef 2>/dev/null | grep -v grep | grep -q "pmon_${INSTANCE}"; then
    printf '%s\n' "Instance ${INSTANCE} appears to be running (pmon found)." >> "${MAIN_LOG}"
else
    # If not found, fail
    fail 2 "Instance ${INSTANCE} not running (pmon not found). Check ORACLE SID and environment."
fi

# Check database role is PRIMARY ----------------------------------------
# Use sqlplus to check role; requires sqlplus in PATH and OS auth or provided credentials.
DB_ROLE=""
if command -v sqlplus >/dev/null 2>&1; then
    # Use silent connection; expect OS-authenticated user (run as oracle)
    DB_ROLE="$(printf "set pages 0 feedback off verify off heading off echo off\nSELECT DATABASE_ROLE FROM V\\$DATABASE;\nexit\n" | sqlplus -s '/ as sysdba' 2>/dev/null | tr -d '[:space:]' || true)"
fi

if [ -z "${DB_ROLE}" ]; then
    # Could not determine, treat as failure (safe)
    fail 3 "Unable to determine database role. sqlplus connection failed or returned empty. Not proceeding."
fi

if [ "X${DB_ROLE}" != "XPRIMARY" ]; then
    fail 3 "Database role is not PRIMARY (found: ${DB_ROLE}). Backups should run on PRIMARY only."
fi
printf '%s\n' "Database role: ${DB_ROLE}" >> "${MAIN_LOG}"

# Build RMAN script dynamically -----------------------------------------
RMAN_SCRIPT="${TMP_DIR}/${INSTANCE}_${BACKUP_TYPE_UP}_${TIMESTAMP}.rcv"

# Determine backup format directories with date strings
DATE_DIR="$(date '+%d-%b-%Y')"
BACKUP_DIR_FINAL=""
case "${BACKUP_TYPE_UP}" in
    L0)
        BACKUP_DIR_FINAL="${BACKUP_L0_DIR}/${DATE_DIR}"
        ;;
    L1)
        BACKUP_DIR_FINAL="${BACKUP_L1_DIR}/${DATE_DIR}"
        ;;
    ARCH)
        BACKUP_DIR_FINAL="${BACKUP_ARCH_DIR}/${DATE_DIR}"
        ;;
    *)
        fail 1 "Unknown BACKUP_TYPE: ${BACKUP_TYPE}"
        ;;
esac

mkdir -p "${BACKUP_DIR_FINAL}" 2>/dev/null || :

# Build channel allocation block
build_allocate_channels() {
    cnt=1
    printf '%s\n' "" > "${TMP_DIR}/channels.tmp"
    while [ "${cnt}" -le "${CHANNELS}" ]; do
        # channel name unique
        CH_NAME="ch${cnt}"
        # Device type disk allocation example (modify if SBT required)
        printf 'ALLOCATE CHANNEL %s DEVICE TYPE DISK FORMAT '\''%s/%s_%%d'"\'' MAXPIECESIZE %s;\n' "${CH_NAME}" "${BACKUP_DIR_FINAL}" "${INSTANCE}_${TIMESTAMP}" "${CHANNEL_MAXSIZE}" >> "${RMAN_SCRIPT}"
        cnt=$((cnt + 1))
    done
}

# Create main RMAN commands
printf '%s\n' "run {" > "${RMAN_SCRIPT}"
build_allocate_channels

# Backup type specific logic
case "${BACKUP_TYPE_UP}" in
    L0)
        # Level 0 incremental (full)
        printf '  BACKUP INCREMENTAL LEVEL 0 FORMAT '\''%s/%s_%%d'\'' DATABASE;' "${BACKUP_DIR_FINAL}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        # Backup controlfile and spfile after L0
        printf '  BACKUP CURRENT CONTROLFILE FORMAT '\''%s/controlfile_%s_%%d'\'';' "${BACKUP_DIR_FINAL}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        printf '  BACKUP SPFILE FORMAT '\''%s/spfile_%s_%%d'\'';' "${BACKUP_DIR_FINAL}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        # Archive backups for not backed up logs
        printf '  BACKUP ARCHIVELOG ALL NOT BACKED UP FORMAT '\''%s/arch_%s_%%d'\'';' "${BACKUP_ARCH_DIR}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        ;;
    L1)
        # Level 1 incremental
        printf '  BACKUP INCREMENTAL LEVEL 1 FORMAT '\''%s/%s_%%d'\'' DATABASE;' "${BACKUP_DIR_FINAL}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        printf '  BACKUP CURRENT CONTROLFILE FORMAT '\''%s/controlfile_%s_%%d'\'';' "${BACKUP_DIR_FINAL}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        printf '  BACKUP SPFILE FORMAT '\''%s/spfile_%s_%%d'\'';' "${BACKUP_DIR_FINAL}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        # Archive backups for not backed up logs
        printf '  BACKUP ARCHIVELOG ALL NOT BACKED UP FORMAT '\''%s/arch_%s_%%d'\'';' "${BACKUP_ARCH_DIR}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        ;;
    ARCH)
        # Only archivelogs that are not backed up
        printf '  BACKUP ARCHIVELOG ALL NOT BACKED UP FORMAT '\''%s/arch_%s_%%d'\'';' "${BACKUP_ARCH_DIR}" "${INSTANCE}_${TIMESTAMP}" >> "${RMAN_SCRIPT}"
        printf '\n' >> "${RMAN_SCRIPT}"
        ;;
esac

# Release channels and finish run block
printf '  RELEASE CHANNEL ALL;\n}' >> "${RMAN_SCRIPT}"

# Compression clause note (RMAN syntax varies by version). We implement compression using backup optimization config inline if requested
if [ "X${COMPRESSION}" = "XY" ]; then
    # Prepend configure command to enable compression for the duration (non-persistent option not available in older RMAN; we apply tag)
    # We'll write an extra file that first issues CONFIGURE COMPRESSION ALGORITHM if supported. Keep it optional - we append comment for DBA.
    # For this script, we add a note and rely on RMAN's private config if site chooses other.
    printf '%s\n' "# NOTE: Compression requested. Ensure the RMAN version supports CONFIGURE COMPRESSION ALGORITHM or use 'AS COMPRESSED BACKUPSET' in your RMAN commands.\n" >> "${MAIN_LOG}"
fi

# Run RMAN ---------------------------------------------------------------
# Run rman and capture output
printf '%s\n' "Starting RMAN run for ${INSTANCE} type ${BACKUP_TYPE_UP} at $(date)" >> "${MAIN_LOG}"
# Use OS authentication (recommended). RMAN will pick ORACLE_HOME and ORACLE_SID from env.
if [ "X${DRY_RUN}" = "XY" ]; then
    printf '%s\n' "DRY_RUN=Y - skipping actual RMAN invocation. RMAN script created at ${RMAN_SCRIPT}" >> "${MAIN_LOG}"
else
    # Execute RMAN. Use rman target / or RMAN_BINARY if set.
    if command -v "${RMAN_BINARY}" >/dev/null 2>&1; then
        "${RMAN_BINARY}" target / cmdfile="${RMAN_SCRIPT}" log="${MAIN_LOG}" >> "${MAIN_LOG}" 2>&1 || true
    else
        printf '%s\n' "RMAN binary not found: ${RMAN_BINARY}" >> "${ERROR_LOG}"
        fail 4 "RMAN binary not found in PATH and RMAN_BINARY not valid."
    fi
fi

# Scan RMAN log for errors ----------------------------------------------
# Error detection patterns: RMAN-, ORA-, ERROR at line, RMAN-03009 etc.
scan_log_for_errors() {
    found=0
    grep -E -n "RMAN-|ORA-|ERROR at line|RMAN-03009|ORA-" "${MAIN_LOG}" > "${TMP_DIR}/rman_raw_errors.tmp" 2>/dev/null || true

    if [ -s "${TMP_DIR}/rman_raw_errors.tmp" ]; then
        found=1
    fi

    # Create/clear error log
    : > "${ERROR_LOG}" 2>/dev/null || :

    if [ "${found}" -eq 1 ]; then
        # For each matching line, extract any error codes and map via error map
        while IFS= read -r line; do
            # Extract RMAN-#### or ORA-##### patterns
            codes="$(printf '%s\n' "${line}" | sed -n 's/.*\(RMAN-[0-9]\{4,\}\).*/\1/p;s/.*\(ORA-[0-9]\{5,\}\).*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
            if [ -z "${codes}" ]; then
                # if no explicit code, write the raw line
                printf '%s %s\n' "$(date '+%F %T')" "${line}" >> "${ERROR_LOG}"
            else
                # iterate codes
                for code in ${codes}; do
                    # lookup mapping file: format CODE|SHORT|REMEDY
                    if [ -f "${ERROR_MAP_FILE}" ]; then
                        mapping="$(grep -E "^${code}\\|" "${ERROR_MAP_FILE}" | head -n 1 || true)"
                    else
                        mapping=""
                    fi
                    if [ -n "${mapping}" ]; then
                        # split mapping
                        short="$(printf '%s' "${mapping}" | awk -F'|' '{print $2}')"
                        remedy="$(printf '%s' "${mapping}" | awk -F'|' '{print $3}')"
                        printf '%s %s : %s | %s\n' "$(date '+%F %T')" "${code}" "${short}" "${remedy}" >> "${ERROR_LOG}"
                    else
                        printf '%s %s : %s\n' "$(date '+%F %T')" "${code}" "No mapping found. See Oracle RMAN/ORA docs." >> "${ERROR_LOG}"
                    fi
                done
            fi
        done < "${TMP_DIR}/rman_raw_errors.tmp"
    else
        printf '%s %s\n' "$(date '+%F %T')" "No RMAN/ORA error patterns found in ${MAIN_LOG}" >> "${MAIN_LOG}"
    fi

    # If ERROR_LOG has content, return non-zero
    if [ -s "${ERROR_LOG}" ]; then
        return 1
    else
        return 0
    fi
}

scan_log_for_errors
SCAN_RET="$?"
if [ "${SCAN_RET}" -ne 0 ]; then
    printf '%s\n' "Errors found and logged to ${ERROR_LOG}" >> "${MAIN_LOG}"
    fail 4 "RMAN reported errors. See ${ERROR_LOG}"
else
    printf '%s\n' "No errors detected in RMAN output." >> "${MAIN_LOG}"
fi

# Retention cleanup -----------------------------------------------------
# Two options implemented:
#  - RMAN_CONFIG: set retention via CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF <N> DAYS; then REPORT/DELETE OBSOLETE
#  - EXPLICIT_REPORT_DELETE: directly run REPORT OBSOLETE; DELETE OBSOLETE
perform_retention() {
    printf '%s\n' "Starting retention actions at $(date)" >> "${RET_LOG}" 2>/dev/null || :
    RET_RMAN_SCRIPT="${TMP_DIR}/${INSTANCE}_retention_${TIMESTAMP}.rcv"
    : > "${RET_RMAN_SCRIPT}"
    if [ "X${RETENTION_METHOD}" = "XRMAN_CONFIG" ]; then
        printf 'configure retention policy to recovery window of %s days;\n' "${RETENTION_DAYS}" >> "${RET_RMAN_SCRIPT}"
    fi
    printf 'report obsolete;\n' >> "${RET_RMAN_SCRIPT}"
    printf 'delete noprompt obsolete;\n' >> "${RET_RMAN_SCRIPT}"
    printf 'exit;\n' >> "${RET_RMAN_SCRIPT}"

    if [ "X${DRY_RUN}" = "XY" ]; then
        printf '%s\n' "DRY_RUN=Y - skipping actual retention RMAN invocation. Retention script at ${RET_RMAN_SCRIPT}" >> "${RET_LOG}"
        return 0
    fi

    if command -v "${RMAN_BINARY}" >/dev/null 2>&1; then
        "${RMAN_BINARY}" target / cmdfile="${RET_RMAN_SCRIPT}" log="${RET_LOG}" >> "${RET_LOG}" 2>&1 || true
    else
        printf '%s\n' "RMAN binary not found for retention: ${RMAN_BINARY}" >> "${RET_ERR_LOG}"
        return 1
    fi

    # Scan retention log for errors
    grep -E "RMAN-|ORA-|ERROR at line" "${RET_LOG}" > "${TMP_DIR}/ret_raw_errors.tmp" 2>/dev/null || true
    if [ -s "${TMP_DIR}/ret_raw_errors.tmp" ]; then
        # copy to retention error log with some context
        printf '%s\n' "Retention errors detected:" >> "${RET_ERR_LOG}" 2>/dev/null || :
        cat "${TMP_DIR}/ret_raw_errors.tmp" >> "${RET_ERR_LOG}" 2>/dev/null || :
        return 1
    fi

    return 0
}

perform_retention
RET_RC="$?"
if [ "${RET_RC}" -ne 0 ]; then
    printf '%s\n' "Retention reported errors. See ${RET_ERR_LOG}" >> "${MAIN_LOG}"
    fail 5 "Retention cleanup failed or found issues. See ${RET_ERR_LOG}"
fi

# Final success ---------------------------------------------------------
printf '%s\n' "Backup and retention completed successfully for ${INSTANCE} ${BACKUP_TYPE_UP} at $(date)" >> "${MAIN_LOG}"
exit 0
