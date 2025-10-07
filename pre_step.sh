#!/bin/sh
#
# pre_step.sh
# POSIX-compatible script for Linux & Solaris to:
#  - Validate Oracle environment setup (OS detection, oratab, SID, instance status)
#  - Query database role and pluggable databases (PDBs)
#  - Prompt user to select a PDB if applicable
#  - Backup SPFILE to PFILE for refresh purposes
#  - Export Oracle metadata: database links, user accounts, and grants using Data Pump
#  - Cleanup temporary files created during execution
#
# Usage:
#   ./pre_step.sh -t <TICKET_ID> <ORACLE_SID>
#
# Exit Codes:
#   0 - Success
#   1 - Usage or argument missing
#   2 - Unsupported operating system detected
#   3 - oratab file missing or specified SID not found / directory creation failure
#   4 - Oracle instance is not running
#   5 - Unable to query database (sqlplus error)
#   6 - User aborted PDB selection prompt
#   7 - SPFILE backup to PFILE failed
#   8 - Database Link metadata export failed
#   9 - User or grant metadata export failed
#
# Author: Your Name or Team
# Date: 2025-10-07
# Version: 1.1
#

# Configuration
BASE_DIR="/PCstaging/Bkp"
LOG_DIR="${BASE_DIR}/logs"
EXP_BASE_DIR="${BASE_DIR}/exports"
SPFILE_DIR="${BASE_DIR}/Rman_refresh_info"
APEX_DP_DIR="APEX_DP_DIR"

ORATAB_LINUX="/etc/oratab"
ORATAB_SOLARIS="/var/opt/oracle/oratab"

DATE_CMD="date '+%Y-%m-%d %H:%M:%S'"
SECONDS_CMD="date +%s"

# Logging utilities
log() {
    printf "%s\n" "$1"
    [ -n "$LOG_FILE" ] && printf "%s\n" "$1" >> "$LOG_FILE"
}

errlog() {
    [ -n "$ERR_FILE" ] && printf "[ERROR] %s\n" "$1" >> "$ERR_FILE"
    printf "❌ ERROR: %s\n" "$1" >&2
}

log_step() {
    local step="$1"
    local __startvar="$2"
    local now=$($SECONDS_CMD)
    eval start_val=\$$__startvar

    if [ -z "$start_val" ]; then
        log "▶ $step ..."
        eval "$__startvar=$now"
    else
        local elapsed=$(( now - start_val ))
        log "✔ $step done (${elapsed}s)"
        unset "$__startvar"
    fi
}

run_expdp_os_auth() {
    "$ORACLE_HOME/bin/expdp" "\"/ as sysdba\"" "$@"
    return $?
}

ensure_dirs() {
    mkdir -p "$BASE_DIR" "$SPFILE_DIR" "$EXP_BASE_DIR" "$LOG_DIR" 2>/dev/null || {
        die "Failed to create required base directories under $BASE_DIR" 3
    }
}

detect_os_and_oratab() {
    OS_TYPE=$(uname -s 2>/dev/null || echo "Unknown")
    case "$OS_TYPE" in
        Linux) ORATAB="$ORATAB_LINUX" ;;
        SunOS) ORATAB="$ORATAB_SOLARIS" ;;
        *) die "Unsupported OS: $OS_TYPE" 2 ;;
    esac
    [ ! -f "$ORATAB" ] && die "oratab not found: $ORATAB" 3
    log "Selected oratab: $ORATAB (OS: $OS_TYPE)"
}

validate_and_set_sid() {
    local sid="$1"
    [ -z "$sid" ] && die "No SID provided"

    ORATAB_LINE=$(awk -F: -v sid="$sid" '$1==sid && $1!~"^#"{print $0}' "$ORATAB" | head -n1)
    [ -z "$ORATAB_LINE" ] && die "SID '$sid' not found in oratab" 3

    ORACLE_HOME=$(echo "$ORATAB_LINE" | awk -F: '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$ORACLE_HOME" ] && die "Cannot determine ORACLE_HOME" 3

    export ORACLE_SID="$sid"
    export ORACLE_HOME
    export PATH="$ORACLE_HOME/bin:$PATH"
    log "ORACLE_SID=$ORACLE_SID, ORACLE_HOME=$ORACLE_HOME"
}

check_instance_running() {
    local pmon_pattern="[p]mon_${ORACLE_SID}"
    PMON_MATCH=$(ps -ef 2>/dev/null | grep "$pmon_pattern" || true)
    [ -z "$PMON_MATCH" ] && PMON_MATCH=$(ps -ef 2>/dev/null | grep "[o]ra_pmon_${ORACLE_SID}" || true)
    [ -z "$PMON_MATCH" ] && die "Instance $ORACLE_SID not running" 4
    log "Found pmon process: $(printf "%s" "$PMON_MATCH" | head -n1)"
}

query_sqlplus() {
    local sql="$1"
    SQL_OUT=$(sqlplus -s / as sysdba <<-EOF 2>/dev/null
        WHENEVER SQLERROR EXIT FAILURE
        SET HEADING OFF FEEDBACK OFF ECHO OFF PAGESIZE 0 LINESIZE 1000
        $sql
        EXIT
EOF
    ) || return 1
    printf "%s" "$SQL_OUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

get_db_role_and_pdbs() {
    DB_ROLE=$(query_sqlplus "SELECT DATABASE_ROLE FROM V\$DATABASE;") || die "Failed to query DATABASE_ROLE" 5
    DB_ROLE=$(printf "%s" "$DB_ROLE" | head -n1)
    PDB_COUNT=$(query_sqlplus "SELECT COUNT(*) FROM V\$PDBS;" || echo 0)
    PDB_COUNT=$(printf "%s" "$PDB_COUNT" | sed 's/[^0-9]//g')
    PDB_LIST=""
    if [ "$PDB_COUNT" -gt 0 ]; then
        PDB_LIST=$(query_sqlplus "SELECT NAME FROM V\$PDBS WHERE NAME NOT IN ('PDB\$SEED') ORDER BY NAME;")
    fi
    export DB_ROLE PDB_COUNT PDB_LIST
}

prompt_for_pdb() {
    if [ -z "$PDB_LIST" ] || [ "$PDB_COUNT" -eq 0 ]; then
        log "No PDBs available; continuing as non-CDB"
        PDB_NAME=""
        export PDB_NAME
        IS_CDB="NO"
        return
    fi

    IS_CDB="YES"
    log "Available PDBs:"
    idx=1
    printf "%s\n" "$PDB_LIST" | while IFS= read -r line; do
        log " $idx. $line"
        idx=$((idx + 1))
    done

    while true; do
        printf "Enter PDB number or name (or 'q' to quit): "
        read -r choice
        [ -z "$choice" ] && continue
        case "$choice" in
            q|Q) errlog "User exited"; die "User aborted PDB selection" 6 ;;
            *[!0-9]*)
                if printf "%s\n" "$PDB_LIST" | grep -Fxq "$choice"; then
                    PDB_NAME="$choice"
                    break
                else
                    echo "Invalid name"
                fi
                ;;
            *)
                PDB_NAME=$(printf "%s\n" "$PDB_LIST" | sed -n "${choice}p")
                [ -n "$PDB_NAME" ] && break
                echo "Invalid number"
                ;;
        esac
    done
    export PDB_NAME
    log "User selected PDB: $PDB_NAME"
}

check_pdb_open() {
    PDB_OPEN=$(sqlplus -s / as sysdba <<-SQL
        SET HEADING OFF FEEDBACK OFF ECHO OFF
        SELECT open_mode FROM v\$pdbs WHERE name = upper('$PDB_NAME');
        EXIT;
SQL
    )
    PDB_OPEN=$(printf "%s" "$PDB_OPEN" | tr -d '[:space:]')

    case "$PDB_OPEN" in
        READWRITE|READONLY|"READ ONLY")
            log "PDB $PDB_NAME open_mode=$PDB_OPEN"
            ;;
        *)
            errlog "PDB $PDB_NAME is not open (open_mode=$PDB_OPEN); aborting"
            die "PDB not open" 5
            ;;
    esac
}

backup_spfile_to_pfile() {
    local exp_dir="${EXP_BASE_DIR}/${ORACLE_SID_ARG}"
    mkdir -p "$exp_dir" || die "Cannot create export dir: $exp_dir"

    PFILE_NAME="INIT${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG}.ora"
    PFILE_PATH="${exp_dir}/${PFILE_NAME}"

    sqlplus -s / as sysdba <<-EOF > "${exp_dir}/pfile_create.out" 2>&1
        WHENEVER SQLERROR EXIT FAILURE
        CREATE PFILE='${PFILE_PATH}' FROM SPFILE;
        EXIT
EOF
    [ $? -ne 0 ] && {
        errlog "SPFILE backup failed"
        tail -n40 "${exp_dir}/pfile_create.out" >> "$ERR_FILE"
        die "SPFILE backup failed" 7
    }
    log "SPFILE backed up to: $PFILE_PATH"
}

export_metadata() {
    local type="$1"
    local par_file="$2"
    local dumpfile="$3"
    local par_content="$4"

    echo "$par_content" > "$par_file"
    run_expdp_os_auth PARFILE="$par_file" >> "$LOG_FILE" 2>>"$ERR_FILE"
    [ $? -ne 0 ] && {
        errlog "$type metadata export failed"
        die "$type metadata export failed" 9
    }
    log "$type metadata export successful: $dumpfile"
}

cleanup_temp_files() {
    rm -f "$PFILE_PATH" "$DBLINK_PAR" "$USER_PAR" "$GRANTS_PAR"
    log "Temporary files cleaned."
}

# Main
if [ "$1" != "-t" ] || [ $# -lt 3 ]; then
    echo "Usage: $0 -t <TICKET_ID> <ORACLE_SID>"
    exit 1
fi

TICKET="$2"
ORACLE_SID_ARG="$3"

mkdir -p "$BASE_DIR" "$SPFILE_DIR" "$EXP_BASE_DIR" "$LOG_DIR" 2>/dev/null || {
    echo "Error: Could not create required directories under $BASE_DIR"
    exit 1
}

DATE_TAG=$(date '+%Y%m%d')
DATE_TAG_ALT=$(date '+%d%b%Y' | tr '[:upper:]' '[:lower:]')

LOG_FILE="${LOG_DIR}/validate_env_${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG}.log"
ERR_FILE="${LOG_DIR}/validate_env_${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG}.err"

: > "$LOG_FILE" 2>/dev/null || { echo "Cannot write to log file: $LOG_FILE"; exit 1; }
: > "$ERR_FILE" 2>/dev/null || { echo "Cannot write to error file: $ERR_FILE"; exit 1; }

log "Started pre_step.sh | Log: $LOG_FILE | Errors: $ERR_FILE"

log_step "Ensure base directories" START_DIR
ensure_dirs
log_step "Ensure base directories" START_DIR

log_step "Detect OS and oratab" START_OS
detect_os_and_oratab
log_step "Detect OS and oratab" START_OS

log_step "Validate ORACLE_SID" START_SID
validate_and_set_sid "$ORACLE_SID_ARG"
log_step "Validate ORACLE_SID" START_SID

log_step "Check if instance $ORACLE_SID running" START_INSTANCE
check_instance_running
log_step "Check if instance $ORACLE_SID running" START_INSTANCE

log_step "Query DB role and PDB list" START_ROLE
get_db_role_and_pdbs
log_step "Query DB role and PDB list" START_ROLE

prompt_for_pdb

if [ "$IS_CDB" = "YES" ] && [ -n "$PDB_NAME" ]; then
    export ORACLE_PDB_SID="$PDB_NAME"
    log "Set ORACLE_PDB_SID=$ORACLE_PDB_SID"
    check_pdb_open
else
    unset ORACLE_PDB_SID
    log "Non-CDB environment: ORACLE_PDB_SID unset"
fi

log_step "Backup SPFILE -> PFILE" START_BACKUP
backup_spfile_to_pfile
log_step "Backup SPFILE -> PFILE" START_BACKUP

DBLINK_COUNT=$(sqlplus -s / as sysdba <<EOF
    SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF
    SELECT COUNT(*) FROM dba_db_links;
    EXIT;
EOF
)
DBLINK_COUNT=$(echo "$DBLINK_COUNT" | tr -d '[:space:]')

BASE_NAME="${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG_ALT}"
EXP_INST_DIR="${EXP_BASE_DIR}/${ORACLE_SID_ARG}"

DL_DUMP_BASENAME="${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG_ALT}_metadata_dblink.dmp"
DL_LOG_BASENAME="${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG_ALT}_metadata_dblink.log"
DBLINK_PAR="${EXP_INST_DIR}/dblink_export_${BASE_NAME}.par"
DBLINK_FULL_LINE=""
if [ "$IS_CDB" = "YES" ] && [ -n "$PDB_NAME" ]; then
    DBLINK_FULL_LINE="FULL=Y"
    log "CDB with PDB selected: DB Link export will include FULL=Y"
fi

DBLINK_PAR_CONTENT=$(cat <<EOF
DIRECTORY=${APEX_DP_DIR}
DUMPFILE=${DL_DUMP_BASENAME}
LOGFILE=${DL_LOG_BASENAME}
${DBLINK_FULL_LINE}
CONTENT=METADATA_ONLY
INCLUDE=DB_LINK
REUSE_DUMPFILES=Y
EOF
)

if [ "$DBLINK_COUNT" -eq 0 ]; then
    log "No DB Links found. Skipping DB Link export."
else
    log_step "Export DB Link metadata" START_DBLINK
    export_metadata "DB Link" "$DBLINK_PAR" "$DL_DUMP_BASENAME" "$DBLINK_PAR_CONTENT"
    log_step "Export DB Link metadata" START_DBLINK
fi

USER_DUMP_BASENAME="${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG_ALT}_metadata_user.dmp"
USER_LOG_BASENAME="${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG_ALT}_metadata_user.log"
USER_PAR="${EXP_INST_DIR}/user_export_${BASE_NAME}.par"

USER_PAR_CONTENT=$(cat <<EOF
DIRECTORY=${APEX_DP_DIR}
DUMPFILE=${USER_DUMP_BASENAME}
LOGFILE=${USER_LOG_BASENAME}
FULL=Y
CONTENT=METADATA_ONLY
INCLUDE=USER
REUSE_DUMPFILES=Y
EOF
)

log_step "Export user account metadata" START_USER
export_metadata "User" "$USER_PAR" "$USER_DUMP_BASENAME" "$USER_PAR_CONTENT"
log_step "Export user account metadata" START_USER

GRANTS_DUMP_BASENAME="${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG_ALT}_metadata_grant.dmp"
GRANTS_LOG_BASENAME="${ORACLE_SID_ARG}_${TICKET}_${DATE_TAG_ALT}_metadata_grant.log"
GRANTS_PAR="${EXP_INST_DIR}/user_grants_export_${BASE_NAME}.par"

GRANTS_PAR_CONTENT=$(cat <<EOF
DIRECTORY=${APEX_DP_DIR}
DUMPFILE=${GRANTS_DUMP_BASENAME}
LOGFILE=${GRANTS_LOG_BASENAME}
FULL=Y
CONTENT=METADATA_ONLY
INCLUDE=ROLE_GRANT
INCLUDE=SYSTEM_GRANT
INCLUDE=OBJECT_GRANT
REUSE_DUMPFILES=Y
EOF
)

log_step "Export user grant metadata" START_GRANT
export_metadata "User grants" "$GRANTS_PAR" "$GRANTS_DUMP_BASENAME" "$GRANTS_PAR_CONTENT"
log_step "Export user grant metadata" START_GRANT

cleanup_temp_files

log "pre_step.sh completed successfully."
exit 0
