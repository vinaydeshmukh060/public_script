#!/bin/sh
###############################################################################
# Script Name   : oracle_metadata_export.sh
# Purpose       : Automated Oracle environment validation and metadata export
# Compatibility : POSIX (/bin/sh, bash) on Linux and Solaris
###############################################################################

set -eu
trap 'log_err "Terminated unexpectedly."; exit 1' INT TERM ERR

###############################################################################
# Defaults & Configuration
###############################################################################
BASE_DIR="${BASE_DIR:-/PCstaging/bkp}"
SPFILE_DIR="$BASE_DIR/spfile_backup"
EXP_BASE_DIR="$BASE_DIR/dumps"
LOG_DIR="$BASE_DIR/logs"
APEX_DP_DIR="${APEX_DP_DIR:-APEX_DP_DIR}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/metadata_export_${TIMESTAMP}.log"

###############################################################################
# Usage & Help
###############################################################################
usage() {
    cat <<EOF
Usage: $0 -s SID -t TICKET [-c] [-p PDB] [-d TIMESTAMP]
  -s SID    Oracle SID
  -t TICKET Ticket ID
  -c        Enable CDB mode
  -p PDB    PDB name (required with -c)
  -d TIMESTAMP Override timestamp
  -h        Help
EOF
    exit 1
}

###############################################################################
# Logging
###############################################################################
log_msg() {
    printf "[%s] INFO: %s\n" "$(date +"%d-%m-%Y %H:%M:%S")" "$*" | tee -a "$LOG_FILE"
}
log_err() {
    printf "[%s] ERROR: %s\n" "$(date +"%d-%m-%Y %H:%M:%S")" "$*" | tee -a "$LOG_FILE" >&2
}

###############################################################################
# Parameter Parsing
###############################################################################
IS_CDB=0
while getopts "s:t:cp:d:h" opt; do
    case "$opt" in
        s) ORACLE_SID="$OPTARG" ;;
        t) TICKET="$OPTARG" ;;
        c) IS_CDB=1 ;;
        p) PDB_NAME="$OPTARG" ;;
        d) TIMESTAMP="$OPTARG"; LOG_FILE="$LOG_DIR/metadata_export_${TIMESTAMP}.log" ;;
        h) usage ;;
        *) usage ;;
    esac
done
[ -n "${ORACLE_SID:-}" ] && [ -n "${TICKET:-}" ] || usage
if [ "$IS_CDB" -eq 1 ] && [ -z "${PDB_NAME:-}" ]; then
    log_err "PDB name required with -c"; exit 1
fi

###############################################################################
# Prepare Directories
###############################################################################
for D in "$BASE_DIR" "$SPFILE_DIR" "$EXP_BASE_DIR" "$LOG_DIR"; do
    [ -d "$D" ] || mkdir -p "$D" || { log_err "Cannot create $D"; exit 10; }
done

###############################################################################
# Detect ORATAB & Set Environment
###############################################################################
case "$(uname)" in
    Linux) ORATAB="/etc/oratab" ;;
    SunOS) ORATAB="/var/opt/oracle/oratab" ;;
    *) log_err "Unsupported OS"; exit 3 ;;
esac
[ -f "$ORATAB" ] || { log_err "Oratab not found"; exit 3; }
ORACLE_HOME="$(grep -v '^#' "$ORATAB" | awk -F: -v sid="$ORACLE_SID" '$1==sid{print $2}')"
[ -n "$ORACLE_HOME" ] || { log_err "ORACLE_HOME not found for $ORACLE_SID"; exit 4; }
export ORACLE_SID ORACLE_HOME PATH="$ORACLE_HOME/bin:$PATH"
log_msg "Environment set for SID=$ORACLE_SID"
if [ "$IS_CDB" -eq 1 ]; then
    export ORACLE_PDB_SID="$PDB_NAME"
    log_msg "PDB context set to $PDB_NAME"
fi

###############################################################################
# Pre-Execution Validations
###############################################################################
ps -ef|grep -v grep|grep -q "ora_pmon_${ORACLE_SID}" || { log_err "PMON not running"; exit 5; }
DB_ROLE=$(sqlplus -s '/ as sysdba' <<-EOF
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT RTRIM(DATABASE_ROLE) FROM V\$DATABASE;
EXIT;
EOF
)
log_msg "Database role is: $DB_ROLE"
if [ "$IS_CDB" -eq 1 ]; then
    STATUS=$(sqlplus -s '/ as sysdba' <<-EOF
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT RTRIM(OPEN_MODE) FROM V\$PDBS WHERE NAME=UPPER('$PDB_NAME');
EXIT;
EOF
)
    case "$STATUS" in READ\ WRITE|READ\ ONLY) log_msg "PDB '$PDB_NAME' open ($STATUS)";;
        *) log_err "PDB '$PDB_NAME' not open: $STATUS"; exit 8;; esac
fi
DIR_PATH=$(sqlplus -s '/ as sysdba' <<-EOF
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT directory_path FROM dba_directories WHERE directory_name=UPPER('$APEX_DP_DIR');
EXIT;
EOF
)
[ -n "$DIR_PATH" ] || { log_err "Directory object $APEX_DP_DIR not found"; exit 10; }
CURRENT_USER=$(sqlplus -s '/ as sysdba' <<-EOF
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT USER FROM DUAL;
EXIT;
EOF
)
if [ "$CURRENT_USER" != "SYS" ]; then
    PRIV_COUNT=$(sqlplus -s '/ as sysdba' <<-EOF
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF VERIFY OFF HEADING OFF ECHO OFF
SELECT COUNT(*) FROM dba_sys_privs WHERE grantee=USER AND privilege='EXP_FULL_DATABASE';
EXIT;
EOF
)
    [ "$PRIV_COUNT" -gt 0 ] || { log_err "Missing EXP_FULL_DATABASE privilege"; exit 11; }
fi

###############################################################################
# Backup SPFILE (always from root container for CDBs)
###############################################################################
SPFILE_OUT="$SPFILE_DIR/pfile_${ORACLE_SID}_${TICKET}_${TIMESTAMP}.ora"
if [ "$IS_CDB" -eq 1 ]; then
    sqlplus -s '/ as sysdba' <<-EOF >/dev/null
ALTER SESSION SET CONTAINER=CDB\$ROOT;
CREATE PFILE='$SPFILE_OUT' FROM SPFILE;
EXIT;
EOF
else
    sqlplus -s '/ as sysdba' <<-EOF >/dev/null
CREATE PFILE='$SPFILE_OUT' FROM SPFILE;
EXIT;
EOF
fi
if [ -s "$SPFILE_OUT" ]; then
    log_msg "SPFILE backed up at $SPFILE_OUT"
else
    log_err "SPFILE backup failed or empty: $SPFILE_OUT"
    exit 6
fi

###############################################################################
# Data Pump Export Function
###############################################################################
run_expdp() {
    TYPE=$1
    INC=$2
    OUT_LOG="$LOG_DIR/expdp_${TYPE}_${TIMESTAMP}.out"
    DMP_NAME="${TYPE}_${ORACLE_SID}_${TICKET}_${TIMESTAMP}.dmp"
    JOB_LOG="${TYPE}_${ORACLE_SID}_${TICKET}_${TIMESTAMP}.log"

    log_msg "Starting expdp for $TYPE (include=$INC)"
    expdp '"/ as sysdba"' \
        directory="$APEX_DP_DIR" \
        dumpfile="$DMP_NAME" \
        logfile="$JOB_LOG" \
        full=y include="$INC" \
        >"$OUT_LOG" 2>&1
    RC=$?
    if [ $RC -ne 0 ]; then
        log_err "Export $TYPE FAILED (rc=$RC). See $OUT_LOG"
        exit $RC
    fi
    DUMP_PATH=$(grep -A1 "Dump file set for" "$OUT_LOG" | tail -1 | sed 's/^[[:space:]]*//')
    log_msg "Export $TYPE COMPLETED; dump file: $DUMP_PATH"
}

###############################################################################
# Perform Exports
###############################################################################
run_expdp metadata_user USER
run_expdp metadata_dblink DB_LINK
run_expdp metadata_grants ROLE_GRANT,SYSTEM_GRANT,OBJECT_GRANT

###############################################################################
# Finalize
###############################################################################
log_msg "All operations completed successfully."
exit 0
