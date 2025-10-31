#!/bin/bash

# Oracle GRP Creation with Broker-Aware Standby Coordination and Standalone Primary Support
# Usage: create_grp.sh INS GRP_NAME [SYS_PWD] [-dryrun]

INSTANACE=$1
GRP_NAME=$2
SYS_PWD=$3
DRYRUN=${4:-false}
LOG_FILE="create_grp_${INSTANACE}_${GRP_NAME}.log"
LOCK_FILE="/tmp/create_grp_${INSTANACE}_${GRP_NAME}.lock"

LOCKFD=200

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

GRP_NAME_PRIMARY="${GRP_NAME}_primary"
GRP_NAME_STANDBY="${GRP_NAME}_standby"

# Lock acquisition using flock
exec {LOCKFD}>"$LOCK_FILE"
if ! flock -n $LOCKFD ; then
    echo "Another instance or process is running. Exiting."
    exit 1
fi

if [ -z "$INSTANACE" ] || [ -z "$GRP_NAME" ]; then
    cat << 'EOF'

================================================================================
  Oracle Guaranteed Restore Point (GRP) Creation Script
================================================================================

USAGE:
  ./create_grp.sh INS GRP_NAME [SYS_PWD] [-dryrun]

DESCRIPTION:
  Creates a guaranteed restore point on Oracle primary database with optional
  Data Guard standby coordination. For Data Guard environments, creates GRP on
  standby first, then on primary. For standalone primary databases, uses OS
  authentication.

PARAMETERS:
  INS           - Oracle instance/database name (e.g., orcl, prod01)
  GRP_NAME      - Base name for guaranteed restore points
  [SYS_PWD]     - SYS user password for Data Guard connectivity (optional)
                  If omitted, script assumes standalone primary with OS auth
  [-dryrun]     - Optional flag to simulate script without making changes

Examples:

  1. Data Guard:
     ./create_grp.sh orcl baseName mySysPwd
     Creates 'baseName_standby' on standby and 'baseName_primary' on primary.

  2. Standalone primary:
     ./create_grp.sh orcl baseName
     Creates 'baseName_primary' locally.

================================================================================

EOF
    exit 2
fi

sql_cmd() {
    local tns_alias=$1
    local sql="$2"
    local output

    if [ -n "$SYS_PWD" ] && [ -n "$tns_alias" ]; then
        output=$(echo "$sql" | sqlplus -s "sys/${SYS_PWD}@${tns_alias} AS SYSDBA" 2>/dev/null)
    else
        output=$(echo "$sql" | sqlplus -s "/ AS SYSDBA" 2>/dev/null)
    fi
    echo "$output"
}

get_standby_alias() {
    dgmgrl_output=$(echo -e "show configuration;" | dgmgrl / as sysdba 2>&1)
    standby_alias=$(echo "$dgmgrl_output" | grep -A5 "Database.*Physical Standby" | grep -Po "\b[A-Za-z0-9_]+\b" | grep -v "Physical" | head -1)
    echo "$standby_alias"
}

test_tns_connectivity() {
    local tns_alias=$1
    tnsping $tns_alias > /dev/null 2>&1
    return $?
}

test_sqlplus_connectivity() {
    local tns_alias=$1
    if [ -n "$SYS_PWD" ]; then
        echo "exit" | sqlplus -s "sys/${SYS_PWD}@${tns_alias} AS SYSDBA" > /dev/null 2>&1
        return $?
    else
        return 1
    fi
}

check_dg_lag() {
    local tns_alias=$1
    sql_cmd "$tns_alias" "set heading off feedback off pagesize 0 verify off echo off trimout on trimspool on;
select value from v\$dataguard_stats where name = 'apply lag';" | tr -d '[:space:]'
}

check_db_status() {
    local tns_alias=$1
    local status=$(sql_cmd "$tns_alias" "set heading off feedback off pagesize 0 verify off echo off trimout on trimspool on;
select open_mode from v\$database;")
    status=$(echo "$status" | tr -d '[:space:]')
    if [[ "$status" == "READWRITE" ]] || [[ "$status" == *"READ WRITE"* ]]; then
        return 0
    else
        return 1
    fi
}

check_db_role() {
    local tns_alias=$1
    sql_cmd "$tns_alias" "set heading off feedback off pagesize 0 verify off echo off trimout on trimspool on;
select database_role from v\$database;" | tr -d '[:space:]'
}

check_fra_usage() {
    local tns_alias=$1
    local usage=$(sql_cmd "$tns_alias" "set heading off feedback off pagesize 0 verify off echo off trimout on trimspool on;
select nvl(round(space_used/space_limit*100,2),0) from v\$recovery_area_usage where space_limit > 0;")
    
    usage=$(echo "$usage" | grep -oE '^[0-9]+\.[0-9]+$|^[0-9]+$' | head -1)
    
    if [ -z "$usage" ]; then
        usage=0
    fi
    
    echo "$usage"
}

grp_exists() {
    local tns_alias=$1
    local grp_name=$2
    local count=$(sql_cmd "$tns_alias" "set heading off feedback off pagesize 0 verify off echo off trimout on trimspool on;
select count(*) from v\$restore_point where name=upper('$grp_name');")
    count=$(echo "$count" | grep -oE '^[0-9]+$' | head -1)
    if [ -z "$count" ]; then
        count=0
    fi
    if [ "$count" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

create_grp() {
    local tns_alias=$1
    local grp_name=$2
    if [ "$DRYRUN" = true ]; then
        log "Dry run: would create GRP '$grp_name' on ${tns_alias:-local instance}"
        return 0
    fi
    echo "WHENEVER SQLERROR EXIT FAILURE;
CREATE RESTORE POINT $grp_name GUARANTEE FLASHBACK DATABASE;
EXIT;" | if [ -n "$tns_alias" ] && [ -n "$SYS_PWD" ]; then
        sqlplus -s "sys/${SYS_PWD}@${tns_alias} AS SYSDBA" 2>/dev/null
    else
        sqlplus -s "/ AS SYSDBA" 2>/dev/null
    fi
}

show_grp_info() {
    local tns_alias=$1
    local grp_name=$2
    echo ""
    echo "GRP Creation Summary:"
    echo "=================================================================================="
    sql_cmd "$tns_alias" "
set linesize 200 pagesize 100 feedback off heading on
col name format a20
col scn format 999999999999
col timestamp format a20
col role format a12

SELECT r.name,
       r.scn,
       TO_CHAR(r.time, 'YYYY-MM-DD HH24:MI:SS') AS timestamp,
       d.database_role
  FROM v\$restore_point r
  JOIN v\$database d ON 1=1
 WHERE r.name = UPPER('$grp_name');
"
    echo "=================================================================================="
    echo ""
}

log "Starting guaranteed restore point creation script."

standby_alias=$(get_standby_alias)

if [ -n "$standby_alias" ]; then
    log "Detected standby: $standby_alias"

    if test_tns_connectivity "$standby_alias" && test_sqlplus_connectivity "$standby_alias"; then
        log "Standby connectivity validated."

        if check_db_status "$standby_alias"; then
            log "Standby database is open and READ WRITE."
        else
            log "Standby database is not open or not in READ WRITE mode. Exiting."
            exit 3
        fi

        lag=$(check_dg_lag "$standby_alias")
        if [ "$lag" != "0" ] && [ "$lag" != "0seconds" ]; then
            log "Data Guard lag on standby is not zero ($lag). Exiting."
            exit 4
        else
            log "Data Guard lag on standby is zero."
        fi

        fra_usage_standby=$(check_fra_usage "$standby_alias")
        fra_usage_primary=$(check_fra_usage "$INSTANACE")

        if (( $(echo "$fra_usage_standby < 80" | bc -l) )) && (( $(echo "$fra_usage_primary < 80" | bc -l) )); then
            log "FRA usage is below threshold on standby ($fra_usage_standby%) and primary ($fra_usage_primary%)."
        else
            log "FRA usage exceeds threshold on standby or primary (standby: $fra_usage_standby%, primary: $fra_usage_primary%)."
            exit 5
        fi

        if ! grp_exists "$standby_alias" "$GRP_NAME_STANDBY"; then
            create_grp "$standby_alias" "$GRP_NAME_STANDBY"
            log "Created GRP '${GRP_NAME_STANDBY}' on standby."
        else
            log "GRP '${GRP_NAME_STANDBY}' already exists on standby, skipping creation."
        fi

        if ! grp_exists "$INSTANACE" "$GRP_NAME_PRIMARY"; then
            create_grp "$INSTANACE" "$GRP_NAME_PRIMARY"
            log "Created GRP '${GRP_NAME_PRIMARY}' on primary."
        else
            log "GRP '${GRP_NAME_PRIMARY}' already exists on primary, skipping creation."
        fi

    else
        log "Failed standby connectivity validation. Exiting."
        exit 7
    fi
else
    log "No standby detected; assuming standalone primary database."

    role=$(check_db_role "")
    if [ "$role" == "PRIMARY" ]; then
        log "Standalone primary database confirmed (role=PRIMARY)."
    else
        log "Database role is not PRIMARY (role=$role). Exiting."
        exit 8
    fi

    if check_db_status ""; then
        log "Standalone primary database is open and READ WRITE."
    else
        log "Standalone primary database is not open or not READ WRITE. Exiting."
        exit 9
    fi

    fra_usage_primary=$(check_fra_usage "")
    if (( $(echo "$fra_usage_primary < 80" | bc -l) )); then
        log "FRA usage on standalone primary is below threshold ($fra_usage_primary%)."
    else
        log "FRA usage on standalone primary exceeds threshold ($fra_usage_primary%). Exiting."
        exit 10
    fi

    if ! grp_exists "" "$GRP_NAME_PRIMARY"; then
        create_grp "" "$GRP_NAME_PRIMARY"
        log "Created GRP '${GRP_NAME_PRIMARY}' on standalone primary."
    else
        log "GRP '${GRP_NAME_PRIMARY}' already exists on standalone primary, skipping creation."
    fi
fi

show_grp_info "$INSTANACE" "$GRP_NAME_PRIMARY"

log "Script execution completed."
