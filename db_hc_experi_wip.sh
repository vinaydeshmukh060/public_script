#!/bin/bash
###############################################################################
# Script Name : db_hc_experi.sh
# Version     : 2.8.1 FINAL
# Purpose     : Oracle DB Health Check (RAC / CDB / PDB aware)
###############################################################################

set -euo pipefail
trap 'echo "[FATAL] Line=$LINENO Cmd=$BASH_COMMAND"; exit 2' ERR

#######################################
# CONFIGURATION
#######################################
TBS_WARN=80
TBS_CRIT=90
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
set pages 0 feed off head off verify off echo off trimspool on lines 32767
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
# RAC INSTANCE STATUS
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Instance Status"

  sql_exec "
  select inst_id, instance_name, host_name, status,
         to_char(startup_time,'YYYY-MM-DD HH24:MI')
  from gv\$instance
  order by inst_id;
  " | while read -r inst name host status stime; do
      report "INFO" "INST=$inst NAME=$name HOST=$host STATUS=$status STARTED=$stime"
  done
fi

#######################################
# RAC SERVICES STATUS (FILTERED)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Services Status (User Services Only)"

  sql_exec "
  select name, inst_id
  from gv\$active_services
  where name not like 'SYS$%'
    and name not like 'SYS%'
  order by name, inst_id;
  " | while read -r svc inst; do
      report "INFO" "SERVICE=$svc RUNNING_ON_INST=$inst"
  done
fi

#######################################
# HUGEPAGES CHECK
#######################################
if [[ -f /proc/meminfo ]]; then
  HP_TOTAL=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
  HP_FREE=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)
  HP_RSVD=$(awk '/HugePages_Rsvd/ {print $2}' /proc/meminfo)

  if [[ "$HP_TOTAL" -eq 0 ]]; then
    report "CRITICAL" "HugePages NOT configured"
  elif [[ "$HP_FREE" -eq 0 ]]; then
    report "OK" "HugePages fully allocated (total=$HP_TOTAL)"
  else
    report "WARNING" "HugePages free=$HP_FREE reserved=$HP_RSVD total=$HP_TOTAL"
  fi
fi

#######################################
# USE_LARGE_PAGES PARAMETER
#######################################
ULP_VAL=$(sql_exec "
select nvl(value,'UNSET')
from v\$parameter
where name='use_large_pages';
")

case "$ULP_VAL" in
  ONLY|TRUE) report "OK" "USE_LARGE_PAGES=$ULP_VAL" ;;
  *) report "CRITICAL" "USE_LARGE_PAGES=$ULP_VAL (Expected ONLY/TRUE)" ;;
esac

#######################################
# RAC PARAMETER CONSISTENCY
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  for P in use_large_pages memory_target sga_target sga_max_size cluster_database; do
    CNT=$(sql_exec "
    select count(distinct value)
    from gv\$parameter where name='$P';
    ")

    if [[ "$CNT" -gt 1 ]]; then
      report "CRITICAL" "RAC parameter $P inconsistent"
      sql_exec "
      select inst_id, value
      from gv\$parameter where name='$P'
      order by inst_id;
      " | while read -r line; do report "INFO" "$P -> $line"; done
    else
      VAL=$(sql_exec "
      select distinct value
      from gv\$parameter where name='$P';
      ")
      report "OK" "RAC parameter $P consistent ($VAL)"
    fi
  done
fi

#######################################
# TABLESPACE CHECK
#######################################
check_tablespaces() {
  local C="$1"
  sql_exec "
  select tablespace_name, round(used_percent,2)
  from dba_tablespace_usage_metrics
  where used_percent >= $TBS_WARN;
  " | while read -r tbs used; do
    [[ -z "$tbs" ]] && continue
    if (( $(echo "$used >= $TBS_CRIT" | bc -l) )); then
      report "CRITICAL" "[$C] TBS=$tbs USED=${used}%"
    else
      report "WARNING"  "[$C] TBS=$tbs USED=${used}%"
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
# BLOCKING SESSIONS (RAC SAFE)
#######################################
LOCK_CNT=$(sql_exec "
select count(*) from gv\$session where blocking_session is not null;
")

if [[ "$LOCK_CNT" -eq 0 ]]; then
  report "OK" "No blocking sessions"
else
  report "WARNING" "Blocking sessions detected"
  sql_exec "
  select
   'BLOCKER '||b.inst_id||':'||b.sid||','||b.serial#||
   ' -> BLOCKED '||w.inst_id||':'||w.sid||','||w.serial#
  from gv\$session w
  join gv\$session b
    on b.sid = w.blocking_session
   and b.inst_id = w.blocking_instance;
  " | while read -r line; do report "INFO" "$line"; done
fi

#######################################
# RAC LOAD SUMMARY
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Load Summary (DB Time)"

  sql_exec "
  select inst_id, round(value/100,2)
  from gv\$sysstat
  where name='DB time';
  " | while read -r inst val; do
      report "INFO" "INST=$inst DB_TIME=$val"
  done
fi

#######################################
# LMS CHECK
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  LMS_RAW=$(ps -eLo user,pid,cls,priority,cmd | grep ora_lms | grep -v ASM | grep -v grep || true)

  if [[ -z "$LMS_RAW" ]]; then
    report "CRITICAL" "No LMS processes found"
  else
    echo "$LMS_RAW" | awk '{print $NF}' | sort -u | while read -r LMS; do
      RR_CNT=$(echo "$LMS_RAW" | grep "$LMS" | awk '$3=="RR"' | wc -l)
      [[ "$RR_CNT" -ge 1 ]] \
        && report "OK" "LMS $LMS has RR thread" \
        || report "WARNING" "LMS $LMS has NO RR thread"
    done
  fi
fi

#######################################
# END
#######################################
report "INFO" "Health check completed"
report "INFO" "Log file: $LOG_FILE"
exit 0
