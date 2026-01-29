#!/bin/bash
###############################################################################
# Script Name : db_hc_experi.sh
# Version     : 3.0 FINAL
# Purpose     : Oracle DB Health Check (RAC / CDB / PDB aware)
# HugePages   : Oracle MOS Doc ID 401749.1 compliant
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
  " | while read -r i n h s t; do
      report "INFO" "INST=$i NAME=$n HOST=$h STATUS=$s STARTED=$t"
  done
fi

#######################################
# RAC SERVICES STATUS (USER SERVICES ONLY)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Services Status"
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
# HUGEPAGES CHECK & RECOMMENDATION
# Oracle MOS Doc ID 401749.1
#######################################
if command -v ipcs >/dev/null 2>&1 && [[ -f /proc/meminfo ]]; then
  HP_SIZE_KB=$(awk '/Hugepagesize/ {print $2}' /proc/meminfo)
  HP_TOTAL=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)

  NUM_PG=0
  for SEG_BYTES in $(ipcs -m | awk '{print $5}' | grep -E '^[0-9]+$'); do
    MIN_PG=$(echo "$SEG_BYTES / ($HP_SIZE_KB * 1024)" | bc)
    if [[ "$MIN_PG" -gt 0 ]]; then
      NUM_PG=$(echo "$NUM_PG + $MIN_PG + 1" | bc)
    fi
  done

  if [[ "$NUM_PG" -gt 0 ]]; then
    report "INFO" "HugePages Summary"
    report "INFO" "HugePage size        : ${HP_SIZE_KB} KB"
    report "INFO" "Configured HugePages : ${HP_TOTAL}"
    report "INFO" "Required HugePages   : ${NUM_PG}"
    report "INFO" "Recommended setting  : vm.nr_hugepages=${NUM_PG}"

    if [[ "$HP_TOTAL" -eq "$NUM_PG" ]]; then
      report "OK" "HugePages correctly sized"
    elif [[ "$HP_TOTAL" -gt "$NUM_PG" ]]; then
      report "WARNING" "HugePages over-allocated by $((HP_TOTAL-NUM_PG)) pages"
    else
      report "CRITICAL" "HugePages under-allocated by $((NUM_PG-HP_TOTAL)) pages"
    fi
  else
    report "WARNING" "HugePages calculation skipped (no SHM segments)"
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
# TABLESPACE CHECK (CDB/PDB)
#######################################
check_tablespaces() {
  local C="$1"
  sql_exec "
  select tablespace_name, round(used_percent,2)
  from dba_tablespace_usage_metrics
  where used_percent >= $TBS_WARN;
  " | while read -r t u; do
    [[ -z "$t" ]] && continue
    if (( $(echo "$u >= $TBS_CRIT" | bc) )); then
      report "CRITICAL" "[$C] TBS=$t USED=${u}%"
    else
      report "WARNING"  "[$C] TBS=$t USED=${u}%"
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
LOCK_CNT=$(sql_exec "select count(*) from gv\$session where blocking_session is not null;")

if [[ "$LOCK_CNT" -eq 0 ]]; then
  report "OK" "No blocking sessions"
else
  report "WARNING" "Blocking sessions detected"
  sql_exec "
  select
   'BLOCKER '||b.inst_id||':'||b.sid||
   ' -> BLOCKED '||w.inst_id||':'||w.sid
  from gv\$session w
  join gv\$session b
    on b.sid = w.blocking_session
   and b.inst_id = w.blocking_instance;
  " | while read -r l; do report "INFO" "$l"; done
fi

#######################################
# RAC LOAD SUMMARY (DB TIME)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Load Summary (DB Time)"
  sql_exec "
  select inst_id, round(value/100,2)
  from gv\$sysstat
  where name='DB time';
  " | while read -r i v; do
      report "INFO" "INST=$i DB_TIME=$v"
  done
fi

#######################################
# LMS CHECK (RR THREAD)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "LMS RR Thread Validation"
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
