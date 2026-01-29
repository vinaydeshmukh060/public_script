#!/bin/bash
###############################################################################
# Script Name : db_hc_experi.sh
# Version     : 2.3 FINAL
# Purpose     : Oracle DB Health Check (RAC / CDB / PDB aware)
###############################################################################

set -euo pipefail
trap 'echo "[FATAL] Line=$LINENO Cmd=$BASH_COMMAND"; exit 1' ERR

#######################################
# CONFIGURATION
#######################################
TBS_WARN=80
TBS_CRIT=90
DG_WARN_MIN=10
DG_CRIT_MIN=30
ALERT_LOOKBACK_HOURS=24
LOG_DIR=/stagingPC/Monitoring/logs

#######################################
# GLOBALS
#######################################
ORACLE_SID=""
ORACLE_HOME=""
DB_NAME=""
DB_ROLE=""
IS_CDB=""
IS_RAC=""
LOG_FILE=""
DATE=$(date '+%Y%m%d_%H%M%S')

#######################################
# FUNCTIONS
#######################################
usage() {
  echo "Usage: $0 -d <ORACLE_SID>"
  exit 1
}

report() {
  printf "[%-8s] %s\n" "$1" "$2"
  echo "$(date '+%F %T') | $1 | $2" >> "$LOG_FILE"
}

sql_exec() {
sqlplus -s / as sysdba <<EOF
set pages 0 feed off head off verify off echo off trimspool on
whenever sqlerror exit failure
$1
EOF
}

#######################################
# ARGUMENTS
#######################################
while getopts "d:" o; do
  case "$o" in
    d) ORACLE_SID="$OPTARG" ;;
    *) usage ;;
  esac
done
[[ -z "$ORACLE_SID" ]] && usage

#######################################
# ENVIRONMENT
#######################################
ORACLE_HOME=$(awk -F: -v s="$ORACLE_SID" '$1==s {print $2}' /etc/oratab)
[[ -z "$ORACLE_HOME" ]] && { echo "SID not found in oratab"; exit 1; }

export ORACLE_SID ORACLE_HOME PATH=$ORACLE_HOME/bin:$PATH
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/db_health_${ORACLE_SID}_${DATE}.log"

#######################################
# HEADER
#######################################
echo "===================================================="
echo " Oracle DB Health Check Started"
echo " SID : $ORACLE_SID"
echo " Time: $(date)"
echo "===================================================="

#######################################
# DATABASE INFO
#######################################
DB_NAME=$(sql_exec "select name from v\$database;")
DB_ROLE=$(sql_exec "select database_role from v\$database;")
IS_CDB=$(sql_exec "select cdb from v\$database;")
IS_RAC=$(sql_exec "select case when count(*)>1 then 'YES' else 'NO' end from gv\$instance;")

report "INFO" "DB=$DB_NAME ROLE=$DB_ROLE CDB=$IS_CDB RAC=$IS_RAC"

#######################################
# TABLESPACE CHECK (>80% ONLY)
#######################################
check_tablespaces() {
  local container="$1"

  sql_exec "
select tablespace_name, round(used_percent,2)
from dba_tablespace_usage_metrics
where used_percent >= ${TBS_WARN}
order by used_percent desc;
" | while read -r tbs used; do
    [[ -z "$tbs" ]] && continue
    if (( $(echo "$used >= $TBS_CRIT" | bc -l) )); then
      report "CRITICAL" "[$container] TBS=$tbs USED=${used}%"
    else
      report "WARNING" "[$container] TBS=$tbs USED=${used}%"
    fi
  done
}

if [[ "$IS_CDB" == "YES" ]]; then
  sql_exec "alter session set container=CDB\$ROOT;"
  check_tablespaces "CDB\$ROOT"

  sql_exec "select name from v\$pdbs where open_mode='READ WRITE';" |
  while read -r pdb; do
    sql_exec "alter session set container=$pdb;"
    check_tablespaces "$pdb"
  done
else
  check_tablespaces "NON-CDB"
fi

#######################################
# FRA CHECK
#######################################
sql_exec "
select
 round(space_limit/1024/1024/1024,2),
 round(space_used/1024/1024/1024,2),
 round(space_reclaimable/1024/1024/1024,2),
 round((space_limit-space_used+space_reclaimable)*100/space_limit,2)
from v\$recovery_file_dest;
" | while read -r size used reclaim free; do
  report "INFO" "FRA Size=${size}GB Used=${used}GB Reclaimable=${reclaim}GB Free=${free}%"
done

#######################################
# FRA ARCHIVE & FLASHBACK USAGE
#######################################
sql_exec "
select
 sum(case when file_type='ARCHIVED LOG' then percent_space_used else 0 end),
 sum(case when file_type='FLASHBACK LOG' then percent_space_used else 0 end)
from v\$flash_recovery_area_usage;
" | while read -r arch fb; do
  report "INFO" "FRA Usage ARCHIVE=${arch}% FLASHBACK=${fb}%"
done

#######################################
# LOCKING SESSION CHECK (RAC AWARE)
#######################################
LOCK_CNT=$(sql_exec "select count(*) from gv\$lock where block=1;")

if [[ "$LOCK_CNT" -eq 0 ]]; then
  report "OK" "No blocking sessions"
else
  report "WARNING" "Blocking sessions detected"
  sql_exec "
select
 s.inst_id,
 s.sid||','||s.serial#,
 s.username,
 s.event,
 s.seconds_in_wait
from gv\$session s
where s.blocking_session is not null;
" | while read -r line; do
    report "INFO" "LOCK -> $line"
  done
fi

#######################################
# LMS CHECK (STRICT RR VALIDATION)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  LMS_OUT=$(ps -eLo user,pid,cls,priority,cmd | grep ora_lms | grep -v ASM | grep -v grep)

  if [[ -z "$LMS_OUT" ]]; then
    report "CRITICAL" "No LMS processes found"
  else
    LMS_CNT=$(echo "$LMS_OUT" | wc -l)
    RR_CNT=$(echo "$LMS_OUT" | awk '$3=="RR"' | wc -l)

    echo "$LMS_OUT" | while read -r user pid cls prio cmd; do
      lms=$(echo "$cmd" | awk '{print $1}')
      if [[ "$cls" == "RR" ]]; then
        report "OK" "LMS $lms CLS=RR PRI=$prio"
      else
        report "CRITICAL" "LMS $lms CLS=$cls (Expected RR)"
      fi
    done

    if [[ "$LMS_CNT" -ne "$RR_CNT" ]]; then
      report "CRITICAL" "LMS RR mismatch LMS=$LMS_CNT RR=$RR_CNT"
    fi
  fi
else
  report "INFO" "Non-RAC DB – LMS check skipped"
fi

#######################################
# END
#######################################
report "INFO" "Health check completed"
report "INFO" "Log file: $LOG_FILE"
