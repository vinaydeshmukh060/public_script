#!/bin/sh
#
# oracle_export_manager.sh
# Version: 3.0
# Author: Oracle DBA Team
# Last Modified: 2025-10-06
#
# Purpose:
#   Oracle export automation: SPFILE backup, metadata/grants export, db links, logs and progress
#   Supports Linux/Solaris, CDB/PDB and non-CDB
#
# Usage:
#   ./oracle_export_manager.sh <INSTANCE_NAME> -t <TICKET> [--dry-run]
#
###############################################################################

###
### CONFIGURATION
###
ORATAB_LINUX="/etc/oratab"
ORATAB_SOLARIS="/var/opt/oracle/oratab"
BASE_DIR="/PCstaging/Bkp"
SPFILE_DIR="${BASE_DIR}/Rman_refresh_info"
EXP_BASE_DIR="${BASE_DIR}/exports"
LOG_DIR="${BASE_DIR}/logs"
APEX_DP_DIR="APEX_DP_DIR"  # Used exclusively for Data Pump directory

DATE=$(date +%Y%m%d_%H%M%S)
SCRIPT_START_TIME=$(date +%s)
TICKET=""
DRY_RUN=0
ORACLE_HOME=""
ORATAB_PATH=""
SQLPLUS=""
EXPDP=""
CHOSEN_PDB=""
ORIGINAL_INSTANCE=""
IS_CDB=0

###
### UTILITY
###

get_elapsed_time() {
    current_time=$(date +%s)
    elapsed=$((current_time - SCRIPT_START_TIME))
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))
    printf "%02d:%02d" $minutes $seconds
}

show_progress() {
    STEP_DESC="$1"
    STATUS="$2"
    ELAPSED=$(get_elapsed_time)
    case "$STATUS" in
        "running") SYMBOL=">" ;;
        "success") SYMBOL="✓" ;;
        "failure") SYMBOL="✗" ;;
        *) SYMBOL="?" ;;
    esac
    printf "[%s] [%s] %-60s %s\n" "$ELAPSED" "$SYMBOL" "$STEP_DESC" "$STATUS"
    [ -f "$LOGFILE" ] && printf "[%s] [%s] %-60s %s\n" "$ELAPSED" "$SYMBOL" "$STEP_DESC" "$STATUS" >> "$LOGFILE"
}

handle_error() {
    ERROR_MSG="$1"
    show_progress "$ERROR_MSG" failure
    echo "ERROR: $ERROR_MSG" | tee -a "$ERRORLOG" >&2
    exit 1
}

purge_old_files() {
    show_progress "Purging old logs (keep last 10)" running
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY-RUN: Would purge old log files in $LOG_DIR"
    else
        ls -1t "$LOG_DIR"/export_*.log 2>/dev/null | tail -n +11 | xargs -r rm --
        ls -1t "$LOG_DIR"/error_*.log 2>/dev/null | tail -n +11 | xargs -r rm --
    fi
    show_progress "Purging old logs" success

    show_progress "Purging old SPFILE backups (keep last 1)" running
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY-RUN: Would purge old SPFILE backups in $SPFILE_DIR/$ORIGINAL_INSTANCE"
    else
        if [ -d "$SPFILE_DIR/$ORIGINAL_INSTANCE" ]; then
            ls -1t "$SPFILE_DIR/$ORIGINAL_INSTANCE"/*.bkp 2>/dev/null | tail -n +2 | xargs -r rm --
        fi
    fi
    show_progress "Purging old SPFILE backups" success
}

detect_os() {
    show_progress "Detecting operating system" running
    case "$(uname)" in
        Linux) ORATAB_PATH="$ORATAB_LINUX"; show_progress "Detected Linux OS" success ;;
        SunOS) ORATAB_PATH="$ORATAB_SOLARIS"; show_progress "Detected Solaris OS" success ;;
        *) handle_error "Unsupported OS: $(uname)" ;;
    esac
}

show_usage() {
    cat << EOF
Usage: $0 <INSTANCE_NAME> -t <TICKET_NUMBER> [--dry-run]

Arguments:
  INSTANCE_NAME     Oracle instance name (mandatory)
  -t TICKET         Ticket number for tracking (mandatory)
  --dry-run         Simulate operations without execution (optional)

Examples:
  $0 PRRM01 -t CTASK000331141
  $0 RRM01 -t CTASK000331141 --dry-run

EOF
    exit 1
}

parse_arguments() {
    show_progress "Parsing command arguments" running
    [ $# -eq 0 ] && show_usage

    INSTANCE="$1"
    ORIGINAL_INSTANCE="$1"
    shift

    while [ $# -gt 0 ]; do
        case "$1" in
            -t)
                [ -z "$2" ] && handle_error "Ticket number required after -t"
                TICKET="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            *)
                handle_error "Unknown argument: $1"
                ;;
        esac
    done

    [ -z "$TICKET" ] && handle_error "-t argument is mandatory"
    show_progress "Arguments parsed successfully" success
}

setup_oracle_environment() {
    show_progress "Setting up Oracle environment" running
    ORACLE_HOME=$(grep -v '^#' "$ORATAB_PATH" 2>/dev/null | grep -E "^${ORIGINAL_INSTANCE}:" | head -1 | cut -d: -f2)
    [ -z "$ORACLE_HOME" ] && handle_error "ORACLE_HOME not found in $ORATAB_PATH for instance $ORIGINAL_INSTANCE"
    [ ! -d "$ORACLE_HOME" ] && handle_error "ORACLE_HOME directory does not exist: $ORACLE_HOME"
    PATH="$ORACLE_HOME/bin:$PATH"
    export PATH ORACLE_HOME
    SQLPLUS=$(command -v sqlplus 2>/dev/null || echo "$ORACLE_HOME/bin/sqlplus")
    EXPDP=$(command -v expdp 2>/dev/null || echo "$ORACLE_HOME/bin/expdp")
    [ ! -x "$SQLPLUS" ] && handle_error "SQL*Plus not found or not executable: $SQLPLUS"
    [ ! -x "$EXPDP" ] && handle_error "Data Pump Export not found or not executable: $EXPDP"
    show_progress "Oracle environment configured" success
}

validate_instance() {
    show_progress "Validating instance in oratab" running
    if ! grep -v '^#' "$ORATAB_PATH" 2>/dev/null | grep -E "^${ORIGINAL_INSTANCE}:" >/dev/null; then
        handle_error "Instance $ORIGINAL_INSTANCE not found in $ORATAB_PATH"
    fi
    show_progress "Instance validated in oratab" success
}

check_pmon_process() {
    show_progress "Checking PMON process" running
    if ! ps -ef 2>/dev/null | grep -v grep | grep "pmon.*${ORIGINAL_INSTANCE}" >/dev/null; then
        handle_error "PMON process not running for instance $ORIGINAL_INSTANCE"
    fi
    show_progress "PMON process confirmed running" success
}

detect_container_database() {
    show_progress "Detecting container database status" running
    export ORACLE_SID="$ORIGINAL_INSTANCE"
    CDB_STATUS=$($SQLPLUS -s /nolog <<EOF 2>>"$ERRORLOG"
CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TRIMOUT ON TRIMSPOOL ON
SELECT CDB FROM V\$DATABASE;
EXIT
EOF
)
    CDB_STATUS=$(echo "$CDB_STATUS" | tr -d '\r\n ' | grep -E '^(YES|NO)$')
    case "$CDB_STATUS" in
        "YES") IS_CDB=1; show_progress "Container database detected" success; return 0 ;;
        "NO") IS_CDB=0; show_progress "Non-container database detected" success; return 1 ;;
        *) handle_error "Unable to determine container status. Output: $CDB_STATUS" ;;
    esac
}

select_pdb() {
    show_progress "Retrieving PDB list" running
    export ORACLE_SID="$ORIGINAL_INSTANCE"
    PDB_LIST=$($SQLPLUS -s /nolog <<EOF 2>>"$ERRORLOG"
CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF TRIMOUT ON TRIMSPOOL ON
SELECT NAME FROM V\$PDBS WHERE NAME != 'PDB\$SEED';
EXIT
EOF
)
    PDB_LIST=$(echo "$PDB_LIST" | grep -v '^$' | tr -d '\r')
    [ -z "$PDB_LIST" ] && handle_error "No PDBs found or unable to retrieve PDB list"
    show_progress "PDB list retrieved" success
    echo "\nAvailable PDBs:"
    echo "==============="
    i=1
    PDB_ARRAY=""
    for pdb in $PDB_LIST; do
        printf "  [%d] %s\n" "$i" "$pdb"
        PDB_ARRAY="$PDB_ARRAY $pdb"
        i=$((i+1))
    done
    echo
    while true; do
        printf "Select PDB (number or name): "
        read -r PDB_CHOICE
        if echo "$PDB_CHOICE" | grep -qE '^[0-9]+$'; then
            PDB_INDEX=$((PDB_CHOICE))
            CHOSEN_PDB=$(echo $PDB_ARRAY | cut -d' ' -f$((PDB_INDEX + 1)))
            if [ -n "$CHOSEN_PDB" ] && [ "$PDB_INDEX" -le "$((i - 1))" ] && [ "$PDB_INDEX" -gt 0 ]; then
                break
            else
                echo "Invalid number. Please select 1-$((i - 1))"
            fi
        else
            for pdb in $PDB_ARRAY; do
                if [ "$pdb" = "$PDB_CHOICE" ]; then
                    CHOSEN_PDB="$PDB_CHOICE"
                    break
                fi
            done
            [ -n "$CHOSEN_PDB" ] && break || echo "Invalid PDB name. Please select from the list above."
        fi
    done
    export ORACLE_PDB_SID="$CHOSEN_PDB"
    show_progress "PDB selected: $CHOSEN_PDB" success
}

initialize_logging() {
    show_progress "Initializing logging system" running
    for dir in "$LOG_DIR" "$SPFILE_DIR" "$EXP_BASE_DIR"; do
        if [ $DRY_RUN -eq 1 ]; then
            echo "DRY-RUN: Would create directory: $dir"
        else
            mkdir -p "$dir" || handle_error "Failed to create directory: $dir"
        fi
    done
    LOGFILE="${LOG_DIR}/export_${ORIGINAL_INSTANCE}_${TICKET}_${DATE}.log"
    ERRORLOG="${LOG_DIR}/error_${ORIGINAL_INSTANCE}_${TICKET}_${DATE}.log"
    [ $DRY_RUN -eq 0 ] && touch "$LOGFILE" "$ERRORLOG" || :
    show_progress "Logging system initialized" success
}

backup_spfile() {
    show_progress "Preparing SPFILE backup" running
    SPFILE_DEST_DIR="${SPFILE_DIR}/${ORIGINAL_INSTANCE}"
    SPFILE_NAME="${ORIGINAL_INSTANCE}_${TICKET}.ora.bkp"
    SPFILE_PATH="${SPFILE_DEST_DIR}/${SPFILE_NAME}"

    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY-RUN: Would create directory: $SPFILE_DEST_DIR"
        echo "DRY-RUN: Would execute SQL: CREATE PFILE='$SPFILE_PATH' FROM SPFILE;"
    else
        mkdir -p "$SPFILE_DEST_DIR" || handle_error "Failed to create SPFILE directory"
        export ORACLE_SID="$ORIGINAL_INSTANCE"
        $SQLPLUS -s /nolog <<EOF >>"$LOGFILE" 2>>"$ERRORLOG"
CONNECT / AS SYSDBA
CREATE PFILE='${SPFILE_PATH}' FROM SPFILE;
EXIT
EOF
        [ -f "$SPFILE_PATH" ] || handle_error "SPFILE backup failed - file not created: $SPFILE_PATH"
    fi

    show_progress "SPFILE backup completed" success
    show_progress "SPFILE backup location: $SPFILE_PATH" success
}

generate_ddl_script() {
    show_progress "Generating DDL script for users and grants" running
    DDL_SCRIPT="${EXP_BASE_DIR}/${ORIGINAL_INSTANCE}/recreate_${ORIGINAL_INSTANCE}_${TICKET}.sql"

    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY-RUN: Would generate DDL script: $DDL_SCRIPT"
    else
        mkdir -p "$(dirname "$DDL_SCRIPT")" || handle_error "Failed to create export directory"
        if [ $IS_CDB -eq 1 ] && [ -n "$CHOSEN_PDB" ]; then
            export ORACLE_SID="$ORIGINAL_INSTANCE"
            CONNECT_STRING="CONNECT / AS SYSDBA\nALTER SESSION SET CONTAINER = ${CHOSEN_PDB};"
        else
            export ORACLE_SID="$ORIGINAL_INSTANCE"
            CONNECT_STRING="CONNECT / AS SYSDBA"
        fi
        $SQLPLUS -s /nolog <<EOF >"$DDL_SCRIPT" 2>>"$ERRORLOG"
$CONNECT_STRING
SET PAGESIZE 0
SET LONG 1000000
SET LINESIZE 4000
SET TRIMSPOOL ON
SET TRIM ON
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF

PROMPT -- Oracle User/Role Recreation Script
PROMPT -- Generated on: $(date)
PROMPT -- Instance: ${ORIGINAL_INSTANCE}
PROMPT -- PDB: ${CHOSEN_PDB:-"N/A (non-CDB)"}
PROMPT -- Ticket: ${TICKET}
PROMPT

SELECT DBMS_METADATA.GET_DDL('USER', username) || '
/
'
FROM dba_users
WHERE oracle_maintained = 'N'
  AND username NOT IN ('SYS', 'SYSTEM', 'ANONYMOUS', 'APEX_PUBLIC_USER')
ORDER BY username;

PROMPT
PROMPT -- Roles
SELECT DBMS_METADATA.GET_DDL('ROLE', role) || '
/
'
FROM dba_roles
WHERE role NOT IN ('CONNECT','RESOURCE','DBA','IMP_FULL_DATABASE','EXP_FULL_DATABASE',
                   'DELETE_CATALOG_ROLE','EXECUTE_CATALOG_ROLE','SELECT_CATALOG_ROLE','RECOVERY_CATALOG_OWNER')
  AND role NOT LIKE 'APEX_%'
  AND role NOT LIKE 'ORACLE_%'
ORDER BY role;

PROMPT
PROMPT -- System Privileges
SELECT 'GRANT ' || privilege || ' TO ' || grantee ||
       CASE WHEN admin_option = 'YES' THEN ' WITH ADMIN OPTION' ELSE '' END || ';'
FROM dba_sys_privs
WHERE grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N'
                 UNION
                 SELECT role FROM dba_roles WHERE role NOT LIKE 'ORACLE_%')
ORDER BY grantee, privilege;

PROMPT
PROMPT -- Role Grants
SELECT 'GRANT ' || granted_role || ' TO ' || grantee ||
       CASE WHEN admin_option = 'YES' THEN ' WITH ADMIN OPTION' ELSE '' END || ';'
FROM dba_role_privs
WHERE grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N'
                 UNION
                 SELECT role FROM dba_roles WHERE role NOT LIKE 'ORACLE_%')
ORDER BY grantee, granted_role;

PROMPT
PROMPT -- Object Privileges
SELECT 'GRANT ' || privilege ||
       ' ON ' || owner || '.' || table_name ||
       ' TO ' || grantee ||
       CASE WHEN grantable = 'YES' THEN ' WITH GRANT OPTION' ELSE '' END || ';'
FROM dba_tab_privs
WHERE grantee IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N'
                 UNION
                 SELECT role FROM dba_roles WHERE role NOT LIKE 'ORACLE_%')
ORDER BY owner, table_name, grantee;

PROMPT
PROMPT -- Tablespace Quotas
SELECT 'ALTER USER ' || username || ' QUOTA ' ||
       CASE WHEN max_bytes = -1 THEN 'UNLIMITED' ELSE TO_CHAR(ROUND(max_bytes/1024/1024)) || 'M' END ||
       ' ON ' || tablespace_name || ';'
FROM dba_ts_quotas
WHERE username IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N')
ORDER BY username, tablespace_name;

PROMPT
PROMPT -- Script completed
EXIT
EOF
        [ -f "$DDL_SCRIPT" ] || handle_error "DDL script generation failed"
    fi
    show_progress "DDL script generation completed" success
}

export_metadata() {
    show_progress "Exporting metadata and grants via Data Pump" running
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY-RUN: Would export metadata and grants for all non-Oracle users in one expdp command"
        [ -n "$CHOSEN_PDB" ] && echo "DRY-RUN: Would set ORACLE_PDB_SID=$CHOSEN_PDB"
    else
        USER_LIST_RAW=$($SQLPLUS -s /nolog <<EOF 2>>"$ERRORLOG"
CONNECT / AS SYSDBA
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF ECHO OFF VERIFY OFF TRIMSPOOL ON TRIMOUT ON
SELECT LISTAGG(username, ',') WITHIN GROUP(ORDER BY username) FROM dba_users WHERE oracle_maintained='N' AND username NOT IN ('SYS','SYSTEM');
EXIT
EOF
)
        USER_LIST=$(echo "$USER_LIST_RAW" | tr -d '\r\n ')
        [ -z "$USER_LIST" ] && handle_error "No users found for metadata export"
        METADATA_DUMP="metadata_${ORIGINAL_INSTANCE}_${TICKET}.dmp"
        METADATA_LOG="metadata_${ORIGINAL_INSTANCE}_${TICKET}.log"
        show_progress "Metadata dumpfile: $METADATA_DUMP" success
        show_progress "Metadata logfile: $METADATA_LOG" success
        $EXPDP "'/ AS SYSDBA'" directory="$APEX_DP_DIR" \
            dumpfile="$METADATA_DUMP" logfile="$METADATA_LOG" schemas="$USER_LIST" content=METADATA_ONLY \
            >>"$LOGFILE" 2>>"$ERRORLOG"
        show_progress "Metadata export completed" success
        GRANT_DUMP="grants_${ORIGINAL_INSTANCE}_${TICKET}.dmp"
        GRANT_LOG="grants_${ORIGINAL_INSTANCE}_${TICKET}.log"
        show_progress "Grants dumpfile: $GRANT_DUMP" success
        show_progress "Grants logfile: $GRANT_LOG" success
        $EXPDP "'/ AS SYSDBA'" directory="$APEX_DP_DIR" \
            dumpfile="$GRANT_DUMP" logfile="$GRANT_LOG" schemas="$USER_LIST" include=GRANT \
            >>"$LOGFILE" 2>>"$ERRORLOG"
        show_progress "Grants export completed" success
    fi
    show_progress "Metadata and grants export via Data Pump completed" success
}

export_database_links() {
    show_progress "Exporting database links" running
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY-RUN: Would export database links"
        [ -n "$CHOSEN_PDB" ] && echo "DRY-RUN: Would set ORACLE_PDB_SID=$CHOSEN_PDB"
    else
        export ORACLE_SID="$ORIGINAL_INSTANCE"
        if [ $IS_CDB -eq 1 ] && [ -n "$CHOSEN_PDB" ]; then
            export ORACLE_PDB_SID="$CHOSEN_PDB"
        fi
        DBLINK_DUMP="metadata_${ORIGINAL_INSTANCE}_dblink_${TICKET}.dmp"
        DBLINK_LOG="metadata_${ORIGINAL_INSTANCE}_dblink_${TICKET}.log"
        show_progress "DB Links dumpfile: $DBLINK_DUMP" success
        show_progress "DB Links logfile: $DBLINK_LOG" success
        $EXPDP "'/ AS SYSDBA'" directory="$APEX_DP_DIR" reuse_dumpfiles=y content=METADATA_ONLY include=DB_LINK dumpfile="$DBLINK_DUMP" logfile="$DBLINK_LOG" \
            >>"$LOGFILE" 2>>"$ERRORLOG"
    fi
    show_progress "Database links export completed" success
}

###
### MAIN
###

main() {
    echo "Oracle Export Manager v3.0"
    echo "=========================="
    echo "Start time: $(date)"
    echo "Script: $0"
    echo "Arguments: $*"
    echo

    parse_arguments "$@"
    detect_os
    setup_oracle_environment
    initialize_logging
    
    validate_instance
    check_pmon_process
    
    export ORACLE_SID="$ORIGINAL_INSTANCE"
    show_progress "Oracle SID set to: $ORIGINAL_INSTANCE" success
    
    purge_old_files
    backup_spfile
    if detect_container_database; then
        select_pdb
    else
        show_progress "Non-container database - no PDB selection needed" success
    fi
    
    
    generate_ddl_script
    export_metadata
    export_database_links
    
    TOTAL_TIME=$(get_elapsed_time)
    echo
    show_progress "All operations completed successfully" success
    echo "Total execution time: $TOTAL_TIME"
    echo "Log files:"
    echo "  Main log: $LOGFILE"
    echo "  Error log: $ERRORLOG"
    echo
    echo "Export completed at: $(date)"
}

main "$@"
