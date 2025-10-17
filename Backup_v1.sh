#!/bin/sh

# RMAN Backup Script - Enhanced with Clean Output, Fixed Progress, Integrated Error Mapping
# Version: 4.5 - Complete updated script with .rman cleanup

set -e

################################################################################
# Progress tracking functions - FIXED VERSION
################################################################################

run_with_progress() {
    local cmd="$1"
    local operation_name="$2"
    local log_file="$3"

    echo ""
    echo "Executing $operation_name..."
    eval "$cmd" >/dev/null 2>&1 &
    local cmd_pid=$!
    local seconds=0
    while kill -0 $cmd_pid 2>/dev/null; do
        seconds=$((seconds + 5))
        printf "\rExecuting... %ds" $seconds
        sleep 5
    done
    wait $cmd_pid
    local exit_code=$?
    printf "\r\033[KExecution completed for %s (Duration: %ds)\n" "$operation_name" "$seconds"
    echo ""
    return $exit_code
}

################################################################################
# Load configuration and error mapping
################################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/rman_backup.conf"

set +u
. "${CONFIG_FILE}"
set -u

if type define_error_mappings >/dev/null 2>&1; then
    error_mappings="$(define_error_mappings)"
else
    error_mappings=""
fi

dry_run=0
INSTANCE_NAME=""
BACKUP_TYPE=""
COMPRESSION=""

LOG_TS="$(date '+%Y%m%d_%H%M%S')"
LOG_DATE="$(date '+%Y-%m-%d')"

TEMP_RMAN_SCRIPT=""
TEMP_RETENTION_SCRIPT=""
BACKUP_LOG=""
RETENTION_LOG=""
ERROR_LOG=""
LOCK_FILE=""

OVERALL_SUCCESS=1
EXIT_STATUS=0

################################################################################
# Enhanced error analysis
################################################################################

scan_and_map_errors() {
    local log_file="$1"
    local phase_name="$2"
    local actual_error_count=0

    if [ ! -f "${log_file}" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${phase_name}] WARNING: Log file ${log_file} not found" >> "${ERROR_LOG}"
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [${phase_name}] === ERROR ANALYSIS STARTED ===" >> "${ERROR_LOG}"

    local error_codes=$(grep -Eo '(ORA-[0-9]{5}|RMAN-[0-9]{5})' "${log_file}" 2>/dev/null | sort -u || true)

    if [ -z "${error_codes}" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${phase_name}] No ORA/RMAN errors found" >> "${ERROR_LOG}"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${phase_name}] === ERROR ANALYSIS COMPLETED ===" >> "${ERROR_LOG}"
        return 0
    fi

    actual_error_count=$(echo "${error_codes}" | wc -l || echo "0")
    actual_error_count=$(echo "${actual_error_count}" | tr -d ' \n\r')
    case "${actual_error_count}" in ''|*[!0-9]*) actual_error_count=0 ;; esac

    if [ ${actual_error_count} -gt 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [${phase_name}] Found error codes: $(echo ${error_codes} | tr '\n' ' ')" >> "${ERROR_LOG}"
        echo "" >> "${ERROR_LOG}"

        echo "$(date '+%Y-%m-%d %H:%M:%S') [${phase_name}] === RELEVANT LOG EXCERPTS AND DESCRIPTIONS ===" >> "${ERROR_LOG}"
        echo "${error_codes}" | while read -r error_code; do
            if [ -n "${error_code}" ]; then
                echo "--- Context for ${error_code} ---" >> "${ERROR_LOG}"
                grep -A 2 -B 2 "${error_code}" "${log_file}" >> "${ERROR_LOG}" 2>/dev/null || true
                error_desc=$(echo "${error_mappings}" | grep "^${error_code}|" | cut -d'|' -f2-)
                if [ -n "${error_desc}" ]; then
                    echo "Description and Recommended Action: ${error_desc}" >> "${ERROR_LOG}"
                else
                    echo "Description and Recommended Action: Not available" >> "${ERROR_LOG}"
                fi
                echo "" >> "${ERROR_LOG}"
            fi
        done

        cat >> "${ERROR_LOG}" << EOF

$(date '+%Y-%m-%d %H:%M:%S') [${phase_name}] === ERROR SUMMARY ===

Total error occurrences: ${actual_error_count}

Log file analyzed: ${log_file}

EOF
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [${phase_name}] === ERROR ANALYSIS COMPLETED ===" >> "${ERROR_LOG}"
    return ${actual_error_count}
}

################################################################################
# Usage function and argument parsing
################################################################################

usage() {
    echo "Usage: $(basename "$0") -i INSTANCE_NAME -t BACKUP_TYPE [-c Y|N] [-d]"
    echo ""
    echo " -i Oracle instance name (required)"
    echo " -t Backup type: L0 (Level 0), L1 (Level 1), ARCH (Archive logs only) (required)"
    echo " -c Compression (Y=Yes, N=No) [optional]"
    echo " -d Dry run mode - show commands without executing"
    echo " -h Show this help"
    echo ""
    echo "Prerequisites:"
    echo " - Oracle instance must be running"
    echo " - Database role must be PRIMARY"
    echo ""
    echo "Log Files Generated:"
    echo " - rman_backup_INSTANCE_TYPE_TIMESTAMP.log (backup execution)"
    echo " - rman_retention_INSTANCE_TYPE_TIMESTAMP.log (retention execution)"
    echo " - rman_errors_INSTANCE_TYPE_TIMESTAMP.log (error analysis)"
    echo ""
    exit 1
}

while getopts "i:t:c:dh" opt; do
    case ${opt} in
        i) INSTANCE_NAME="${OPTARG}" ;;
        t) BACKUP_TYPE="$(echo "${OPTARG}" | tr '[:lower:]' '[:upper:]')" ;;
        c)
            COMPRESSION="$(echo "${OPTARG}" | tr '[:lower:]' '[:upper:]')"
            case "${COMPRESSION}" in
                Y|N) ;;
                *) echo "ERROR: -c parameter must be Y or N, got: ${OPTARG}" >&2; usage ;;
            esac
            ;;
        d) dry_run=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

[ -z "${INSTANCE_NAME}" ] && echo "ERROR: Instance name (-i) is required" && usage
[ -z "${BACKUP_TYPE}" ] && echo "ERROR: Backup type (-t) is required" && usage

case "${BACKUP_TYPE}" in
    L0|L1|ARCH) ;;
    *) echo "ERROR: Invalid backup type '${BACKUP_TYPE}'. Must be L0, L1, or ARCH" >&2; usage ;;
esac

if [ -z "${COMPRESSION}" ]; then
    COMPRESSION="${default_compression:-N}"
fi

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: Configuration file ${CONFIG_FILE} not found" >&2
    exit 1
fi

################################################################################
# Oracle checks
################################################################################

echo ""
echo "===== RMAN BACKUP PROCESS START ====="
echo ""
echo "Checking if Oracle instance ${INSTANCE_NAME} is running..."

PMON_PROCESS="ora_pmon_${INSTANCE_NAME}"
if ! pgrep -f "${PMON_PROCESS}" >/dev/null 2>&1; then
    echo ""
    echo "ERROR: Oracle instance ${INSTANCE_NAME} is not running"
    echo " No ${PMON_PROCESS} process found"
    echo " Please start the instance before running backups"
    echo ""
    exit 3
fi
echo "Oracle instance ${INSTANCE_NAME} is running (${PMON_PROCESS} process found)"
echo ""

echo "Setting up Oracle environment"
if [ ! -f "${oratab_path}" ]; then
    echo "ERROR: oratab not found at ${oratab_path}" >&2
    exit 2
fi

oratab_entry=$(grep "^${INSTANCE_NAME}:" "${oratab_path}" || true)
if [ -z "${oratab_entry}" ]; then
    echo "ERROR: Instance ${INSTANCE_NAME} not found in ${oratab_path}" >&2
    exit 2
fi

ORACLE_HOME=$(echo "${oratab_entry}" | cut -d: -f2)
if [ -z "${ORACLE_HOME}" ] || [ ! -d "${ORACLE_HOME}" ]; then
    echo "ERROR: Invalid ORACLE_HOME for instance ${INSTANCE_NAME}" >&2
    exit 2
fi

export ORACLE_HOME ORACLE_SID="${INSTANCE_NAME}"
export PATH="${ORACLE_HOME}/bin:${PATH}"

echo "Oracle environment set: ORACLE_HOME=${ORACLE_HOME}, ORACLE_SID=${ORACLE_SID}"
echo ""

echo "Checking database role (must be PRIMARY for backups)..."
DB_ROLE_CHECK=$(sqlplus -s / as sysdba <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT database_role FROM v\$database;
EXIT;
EOF
)

DB_ROLE=$(echo "${DB_ROLE_CHECK}" | tr -d ' \n\r' | grep -i primary || true)
if [ -z "${DB_ROLE}" ]; then
    echo ""
    echo "ERROR: Database role is not PRIMARY. Backups are only allowed on PRIMARY databases." >&2
    echo "Current role: ${DB_ROLE_CHECK}" >&2
    echo ""
    exit 3
fi

echo "Database role detected: PRIMARY"
echo "✓ Database role is PRIMARY - proceeding with backup"
echo ""


echo "Checking database Name"
DB_NAME_VAR1=$(sqlplus -s / as sysdba <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT NAME FROM v\$database;
EXIT;
EOF
)
echo ""
echo "Database Name: ${DB_NAME_VAR1}" >&2
echo ""

################################################################################
# Prepare final log dir structure
################################################################################

# Correct concatenation with DB name under base_dir
base_dir="${base_dir}/${DB_NAME_VAR1}"

# Now construct backup subdirectories properly
backup_L0_dir="${base_dir}/${backup_L0_dir}"
backup_L1_dir="${base_dir}/${backup_L1_dir}"
backup_Arch_dir="${base_dir}/${backup_Arch_dir}"
logs_dir="${base_dir}/${logs_dir}"


################################################################################
# Setup logs and temp files
################################################################################

echo "Preparing logs directory: ${logs_dir}"
[ ${dry_run} -eq 1 ] && echo "DRY RUN: mkdir -p ${logs_dir}" || mkdir -p "${logs_dir}"

BACKUP_LOG="${logs_dir}/rman_backup_${INSTANCE_NAME}_${BACKUP_TYPE}_${LOG_TS}.log"
RETENTION_LOG="${logs_dir}/rman_retention_${INSTANCE_NAME}_${BACKUP_TYPE}_${LOG_TS}.log"
ERROR_LOG="${logs_dir}/rman_errors_${INSTANCE_NAME}_${BACKUP_TYPE}_${LOG_TS}.log"
LOCK_FILE="${logs_dir}/.rman_${INSTANCE_NAME}.lock"
TEMP_RMAN_SCRIPT="${logs_dir}/rman_${INSTANCE_NAME}_${BACKUP_TYPE}_${LOG_TS}.rman"
TEMP_RETENTION_SCRIPT="${logs_dir}/retain_${INSTANCE_NAME}_${LOG_TS}.rman"

echo "Logs will be created:"
echo " Backup: ${BACKUP_LOG}"
echo " Retention: ${RETENTION_LOG}"
echo " Errors: ${ERROR_LOG}"
echo ""

################################################################################
# Prepare backup directories and locking
################################################################################

echo "Preparing backup directories for date ${backup_date}"
for dir in "${backup_L0_dir}/${backup_date}" "${backup_L1_dir}/${backup_date}" "${backup_Arch_dir}/${backup_date}"; do
    if [ ${dry_run} -eq 1 ]; then
        echo "DRY RUN: mkdir -p ${dir}"
    else
        mkdir -p "${dir}"
    fi
done

if [ -f "${LOCK_FILE}" ] && kill -0 "$(cat "${LOCK_FILE}")" 2>/dev/null; then
    echo ""
    echo "ERROR: Another backup is in progress for ${INSTANCE_NAME}" >&2
    echo ""
    exit 1
fi

if [ ${dry_run} -eq 0 ]; then
    echo $$ > "${LOCK_FILE}"
fi
echo ""

################################################################################
# Generate RMAN backup script
################################################################################

echo "Generating RMAN script: ${TEMP_RMAN_SCRIPT}"

BACKUP_OPTIMIZATION="${backup_optimization:-Y}"

case "${BACKUP_TYPE}" in
L0)
    {
    echo "CONNECT TARGET /;"
    [ "${BACKUP_OPTIMIZATION}" = "Y" ] && echo "CONFIGURE BACKUP OPTIMIZATION ON;" || echo "CONFIGURE BACKUP OPTIMIZATION OFF;"
    echo "RUN {"
    for i in $(seq 1 ${channels}); do
        echo " ALLOCATE CHANNEL c${i} DEVICE TYPE DISK MAXPIECESIZE ${channel_max_size};"
    done
    [ "${COMPRESSION}" = "Y" ] && echo " CONFIGURE DEVICE TYPE DISK PARALLELISM ${channels} BACKUP TYPE TO COMPRESSED BACKUPSET;" || echo " CONFIGURE DEVICE TYPE DISK PARALLELISM ${channels};"
    echo " BACKUP AS BACKUPSET INCREMENTAL LEVEL 0"
    echo " FORMAT '${backup_L0_dir}/${backup_date}/${INSTANCE_NAME}_L0_%U' DATABASE;"
    echo " BACKUP AS BACKUPSET FORMAT '${backup_Arch_dir}/${backup_date}/${INSTANCE_NAME}_ARCH_%U' ARCHIVELOG ALL;"
	echo " BACKUP AS BACKUPSET FORMAT '${backup_L0_dir}/${backup_date}/${INSTANCE_NAME}_CTL_%U' CURRENT CONTROLFILE TAG '${INSTANCE_NAME}_CTL_BKP';"
	echo " BACKUP AS BACKUPSET FORMAT '${backup_L0_dir}/${backup_date}/${INSTANCE_NAME}_SPFILE_%U' SPFILE TAG '${INSTANCE_NAME}_SPFILE_BKP';"
    for i in $(seq 1 ${channels}); do
        echo " RELEASE CHANNEL c${i};"
    done
    echo "}"
    echo "EXIT;"
    } > "${TEMP_RMAN_SCRIPT}"
    ;;
L1)
    {
    echo "CONNECT TARGET /;"
    [ "${BACKUP_OPTIMIZATION}" = "Y" ] && echo "CONFIGURE BACKUP OPTIMIZATION ON;" || echo "CONFIGURE BACKUP OPTIMIZATION OFF;"
    echo "RUN {"
    for i in $(seq 1 ${channels}); do
        echo " ALLOCATE CHANNEL c${i} DEVICE TYPE DISK MAXPIECESIZE ${channel_max_size};"
    done
    [ "${COMPRESSION}" = "Y" ] && echo " CONFIGURE DEVICE TYPE DISK PARALLELISM ${channels} BACKUP TYPE TO COMPRESSED BACKUPSET;" || echo " CONFIGURE DEVICE TYPE DISK PARALLELISM ${channels};"
    echo " BACKUP AS BACKUPSET INCREMENTAL LEVEL 1"
    echo " FORMAT '${backup_L1_dir}/${backup_date}/${INSTANCE_NAME}_L1_%U' DATABASE;"
    echo " BACKUP AS BACKUPSET FORMAT '${backup_Arch_dir}/${backup_date}/${INSTANCE_NAME}_ARCH_%U' ARCHIVELOG ALL;"
	echo " BACKUP AS BACKUPSET FORMAT '${backup_L1_dir}/${backup_date}/${INSTANCE_NAME}_CTL_%U' CURRENT CONTROLFILE TAG '${INSTANCE_NAME}_CTL_BKP';"
	echo " BACKUP AS BACKUPSET FORMAT '${backup_L1_dir}/${backup_date}/${INSTANCE_NAME}_SPFILE_%U' SPFILE TAG '${INSTANCE_NAME}_SPFILE_BKP';"
    for i in $(seq 1 ${channels}); do
        echo " RELEASE CHANNEL c${i};"
    done
    echo "}"
    echo "EXIT;"
    } > "${TEMP_RMAN_SCRIPT}"
    ;;
ARCH)
    {
    echo "CONNECT TARGET /;"
    [ "${BACKUP_OPTIMIZATION}" = "Y" ] && echo "CONFIGURE BACKUP OPTIMIZATION ON;" || echo "CONFIGURE BACKUP OPTIMIZATION OFF;"
    echo "RUN {"
    for i in $(seq 1 ${channels}); do
        echo " ALLOCATE CHANNEL c${i} DEVICE TYPE DISK MAXPIECESIZE ${channel_max_size};"
    done
    [ "${COMPRESSION}" = "Y" ] && echo " CONFIGURE DEVICE TYPE DISK PARALLELISM ${channels} BACKUP TYPE TO COMPRESSED BACKUPSET;" || echo " CONFIGURE DEVICE TYPE DISK PARALLELISM ${channels};"
    echo " BACKUP AS BACKUPSET FORMAT '${backup_Arch_dir}/${backup_date}/${INSTANCE_NAME}_ARCH_%U'"
	echo " ARCHIVELOG ALL;"
    for i in $(seq 1 ${channels}); do
        echo " RELEASE CHANNEL c${i};"
    done
    echo "}"
    echo "EXIT;"
    } > "${TEMP_RMAN_SCRIPT}"
    ;;
esac

################################################################################
# Execute RMAN backup with progress tracking
################################################################################

echo "Starting RMAN backup process"

if [ ${dry_run} -eq 1 ]; then
    echo ""
    echo "===== DRY RUN MODE ====="
    cat "${TEMP_RMAN_SCRIPT}"
    echo "===== END DRY RUN ====="
    echo ""
else
    echo "Executing: rman cmdfile=${TEMP_RMAN_SCRIPT} msglog=${BACKUP_LOG}"

    if run_with_progress "${rman_binary} cmdfile=\"${TEMP_RMAN_SCRIPT}\" msglog=\"${BACKUP_LOG}\"" "RMAN backup" "${BACKUP_LOG}"; then
        echo "RMAN backup command completed successfully"
        backup_error_count=0
        scan_and_map_errors "${BACKUP_LOG}" "BACKUP" && backup_error_count=$? || backup_error_count=0
        if [ ${backup_error_count} -gt 0 ]; then
            echo "Backup phase had ${backup_error_count} ORA/RMAN errors"
            OVERALL_SUCCESS=0
            EXIT_STATUS=4
        else
            echo "No ORA/RMAN errors found in backup - backup phase successful"
        fi
    else
        echo "RMAN backup command failed with exit code $?"
        OVERALL_SUCCESS=0
        EXIT_STATUS=4
        scan_and_map_errors "${BACKUP_LOG}" "BACKUP" || true
    fi
fi

################################################################################
# Execute RMAN retention with progress tracking
################################################################################

echo "Generating retention cleanup script: ${TEMP_RETENTION_SCRIPT}"

{
    echo "CONNECT TARGET /;"
    if [ "${delete_archived_logs}" = "Y" ]; then
        echo "CONFIGURE ARCHIVELOG DELETION POLICY TO BACKED UP ${archive_backup_method} TO ${backup_method};"
        echo "DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-${archive_log_retention_days}';"
    fi
    echo "CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${retention_days} DAYS;"
    echo "REPORT OBSOLETE;"
    echo "DELETE NOPROMPT OBSOLETE;"
    echo "EXIT;"
} > "${TEMP_RETENTION_SCRIPT}"

echo "Executing retention cleanup"

if [ ${dry_run} -eq 1 ]; then
    echo ""
    echo "===== DRY RUN MODE ====="
    cat "${TEMP_RETENTION_SCRIPT}"
    echo "===== END DRY RUN ====="
    echo ""
else
    echo "Executing: rman cmdfile=${TEMP_RETENTION_SCRIPT} msglog=${RETENTION_LOG}"
    if run_with_progress "${rman_binary} cmdfile=\"${TEMP_RETENTION_SCRIPT}\" msglog=\"${RETENTION_LOG}\"" "RMAN retention cleanup" "${RETENTION_LOG}"; then
        echo "RMAN retention command completed successfully"
        retention_error_count=0
        scan_and_map_errors "${RETENTION_LOG}" "RETENTION" && retention_error_count=$? || retention_error_count=0
        if [ ${retention_error_count} -gt 0 ]; then
            echo "Retention phase had ${retention_error_count} ORA/RMAN errors"
            OVERALL_SUCCESS=0
            [ ${EXIT_STATUS} -eq 0 ] && EXIT_STATUS=5
        else
            echo "No ORA/RMAN errors found in retention - retention phase successful"
        fi
    else
        echo "RMAN retention command failed with exit code $?"
        OVERALL_SUCCESS=0
        [ ${EXIT_STATUS} -eq 0 ] && EXIT_STATUS=5
        scan_and_map_errors "${RETENTION_LOG}" "RETENTION" || true
    fi
fi

################################################################################
# Log retention and RMAN script cleanup
################################################################################

if [ ${dry_run} -eq 0 ]; then
    echo "Performing log retention: gzip logs older than ${gzip_after_days} days"
    find "${logs_dir}" -maxdepth 1 -name "*.log" -type f -mtime +${gzip_after_days} -exec gzip {} \; 2>/dev/null || true
    echo "Removing zipped logs older than ${remove_zipped_after_days} days"
    find "${logs_dir}" -maxdepth 1 -name "*.gz" -type f -mtime +${remove_zipped_after_days} -exec rm -f {} \; 2>/dev/null || true

    echo "Removing .rman scripts older than ${remove_rman_after_days} days from ${logs_dir}"
    find "${logs_dir}" -maxdepth 1 -name "*.rman" -type f -mtime +${remove_rman_after_days} -exec rm -f {} \; 2>/dev/null || true
fi

################################################################################
# Final summary
################################################################################

if [ ${dry_run} -eq 0 ]; then
    echo "=== FINAL STATUS SUMMARY ==="

    TOTAL_BACKUP_ERRORS=0
    TOTAL_RETENTION_ERRORS=0

    if [ -f "${BACKUP_LOG}" ]; then
        TOTAL_BACKUP_ERRORS=$(grep -Eo '(ORA-[0-9]{5}|RMAN-[0-9]{5})' "${BACKUP_LOG}" 2>/dev/null | wc -l || echo "0")
        TOTAL_BACKUP_ERRORS=$(echo "${TOTAL_BACKUP_ERRORS}" | tr -d ' \n\r')
        case "${TOTAL_BACKUP_ERRORS}" in ''|*[!0-9]*) TOTAL_BACKUP_ERRORS=0 ;; esac
    fi

    if [ -f "${RETENTION_LOG}" ]; then
        TOTAL_RETENTION_ERRORS=$(grep -Eo '(ORA-[0-9]{5}|RMAN-[0-9]{5})' "${RETENTION_LOG}" 2>/dev/null | wc -l || echo "0")
        TOTAL_RETENTION_ERRORS=$(echo "${TOTAL_RETENTION_ERRORS}" | tr -d ' \n\r')
        case "${TOTAL_RETENTION_ERRORS}" in ''|*[!0-9]*) TOTAL_RETENTION_ERRORS=0 ;; esac
    fi

    TOTAL_ERRORS=$((TOTAL_BACKUP_ERRORS + TOTAL_RETENTION_ERRORS))

    echo "Backup errors found: ${TOTAL_BACKUP_ERRORS}"
    echo "Retention errors found: ${TOTAL_RETENTION_ERRORS}"
    echo "Total ORA/RMAN errors: ${TOTAL_ERRORS}"

    if [ ${OVERALL_SUCCESS} -eq 1 ] && [ ${TOTAL_ERRORS} -eq 0 ] && [ ${EXIT_STATUS} -eq 0 ]; then
        echo "RESULT: All operations completed successfully"
        EXIT_STATUS=0
    else
        if [ ${TOTAL_ERRORS} -gt 0 ]; then
            echo "⚠️ ERRORS DETECTED - Detailed analysis in: ${ERROR_LOG}"
        fi
        echo "RESULT: Operations failed (exit code ${EXIT_STATUS})"
    fi

    cat >> "${ERROR_LOG}" << EOF

================================================================================
$(date '+%Y-%m-%d %H:%M:%S') SESSION SUMMARY: ${BACKUP_TYPE} (${LOG_TS})
================================================================================
Backup errors: ${TOTAL_BACKUP_ERRORS}
Retention errors: ${TOTAL_RETENTION_ERRORS}
Total errors: ${TOTAL_ERRORS}
Overall success: $([ ${OVERALL_SUCCESS} -eq 1 ] && echo "YES" || echo "NO")
Final status: $([ ${EXIT_STATUS} -eq 0 ] && echo "SUCCESS" || echo "FAILURE (exit code ${EXIT_STATUS})")
EOF
fi

echo ""
echo "RMAN backup process completed with exit status: ${EXIT_STATUS}"
echo ""
echo "===== RMAN BACKUP PROCESS END ====="
echo ""
