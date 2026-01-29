#!/bin/bash
###############################################################################
# Script Name : db_hc_experi.sh
# Version     : 3.3.1 FINAL
#
# Author      : Vinay V Deshmukh
# Date        : 2026-01-29
#
# Description :
#   Comprehensive Oracle Database Health Check Script.
#   - PMON-driven discovery of running databases
#   - ORACLE_HOME resolved from /etc/oratab (lookup only)
#   - RAC / Single Instance aware
#   - CDB / PDB aware
#   - HugePages sizing + simple usage validation
#   - RAC instance, services, LMS, load, blocking sessions
#   - Tablespace and parameter consistency checks
#
# Usage :
#   ./db_hc_experi.sh -d <ORACLE_SID>
#   ./db_hc_experi.sh --all
#
###############################################################################

set -euo pipefail
trap 'echo "[FATAL] Line=$LINENO Cmd=$BASH_COMMAND"; exit 2' ERR

#######################################
# GLOBAL CONFIG
#######################################
ORATAB=/etc/oratab
LOG_DIR=/stagingPC/Monitoring/logs
TBS_WARN=80
TBS_CRIT=90
SCRIPT_NAME=$(basename "$0")

#######################################
# COMMON FUNCTIONS
#######################################
usage() {
  echo "Usage:"
  echo "  $SCRIPT_NAME -d <ORACLE_SID>"
  echo "  $SCRIPT_NAME --all"
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
# PMON-BASED DISCOVERY
#######################################
get_running_sids() {
  ps -ef | awk '
    /ora_pmon_/ && !/ASM/ {
      sub(".*ora_pmon_", "", $NF)
      print $NF
    }
  ' | sort -u
}

get_oracle_home() {
  local sid="$1"
  awk -F: -v s="$sid" '
    $1 == s && $2 !~ /^#/ && $2 != "" {print $2}
  ' "$ORATAB"
}

#######################################
# CORE HEALTH CHECK
#######################################
run_health_check() {

ORACLE_SID="$1"
DATE=$(date '+%Y%m%d_%H%M%S')

ORACLE_HOME=$(get_oracle_home "$ORACLE_SID")
if [[ -z "$ORACLE_HOME" || ! -d "$ORACLE_HOME" ]]; then
  echo "[CRITICAL] ORACLE_HOME not found for running SID=$ORACLE_SID"
  return
fi

export ORACLE_SID ORACLE_HOME
export PATH=$ORACLE_HOME/bin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=$ORACLE_HOME/lib
export TNS_ADMIN=$ORACLE_HOME/network/admin

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
# RAC SERVICES
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
# HUGEPAGES (EXISTING LOGIC + SIMPLE USAGE CHECK)
#######################################
if [[ -f /proc/meminfo ]]; then
  HP_TOTAL=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
  HP_FREE=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)

  if [[ "$HP_TOTAL" -gt 0 ]]; then
    if [[ "$HP_TOTAL" -ne "$HP_FREE" ]]; then
      report "OK" "HugePages are being used (Total=$HP_TOTAL Free=$HP_FREE)"
    else
      report "CRITICAL" "HugePages configured but NOT used (Total=$HP_TOTAL Free=$HP_FREE)"
      report "CRITICAL" "Restart DB or verify MEMORY_TARGET / AMM"
    fi
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
[[ "$ULP_VAL" =~ TRUE|ONLY ]] \
  && report "OK" "USE_LARGE_PAGES=$ULP_VAL" \
  || report "CRITICAL" "USE_LARGE_PAGES=$ULP_VAL (Expected TRUE/ONLY)"

#######################################
# RAC PARAMETER CONSISTENCY
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  for P in use_large_pages sga_target sga_max_size memory_target cluster_database; do
    CNT=$(sql_exec "select count(distinct value) from gv\$parameter where name='$P';")
    [[ "$CNT" -gt 1 ]] \
      && report "CRITICAL" "RAC parameter $P inconsistent" \
      || report "OK" "RAC parameter $P consistent"
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
  " | while read -r t u; do
    (( $(echo "$u >= $TBS_CRIT" | bc) )) \
      && report "CRITICAL" "[$C] $t ${u}%" \
      || report "WARNING"  "[$C] $t ${u}%"
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
# BLOCKING SESSIONS
#######################################
LOCKS=$(sql_exec "select count(*) from gv\$session where blocking_session is not null;")
[[ "$LOCKS" -eq 0 ]] && report "OK" "No blocking sessions" || {
  report "WARNING" "Blocking sessions detected"
}

#######################################
# RAC LOAD SUMMARY
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Load Summary (DB Time)"
  sql_exec "
    select inst_id, round(value/100,2)
    from gv\$sysstat where name='DB time';
  " | while read -r i v; do
      report "INFO" "INST=$i DB_TIME=$v"
  done
fi

#######################################
# LMS CHECK
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "LMS RR Thread Validation"
  LMS=$(ps -eLo cls,cmd | grep ora_lms | grep -v ASM | grep -v grep || true)
  [[ -z "$LMS" ]] && report "CRITICAL" "No LMS processes found" || report "OK" "LMS processes present"
fi

report "INFO" "Health check completed"
report "INFO" "Log file: $LOG_FILE"
}

#######################################
# MAIN
#######################################
[[ "$#" -eq 0 ]] && usage

if [[ "$1" == "--all" ]]; then
  for SID in $(get_running_sids); do
    run_health_check "$SID"
  done
elif [[ "$1" == "-d" && -n "${2:-}" ]]; then
  ps -ef | grep "[o]ra_pmon_${2}$" >/dev/null || { echo "[ERROR] SID $2 not running"; exit 1; }
  run_health_check "$2"
else
  usage
fi
