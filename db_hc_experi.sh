#!/bin/bash
###############################################################################
# Script Name : db_hc_experi.sh
# Version     : 3.2.2 FINAL
#
# Author      : Vinay V Deshmukh
# Date        : 2026-01-29
#
# Description :
#   Comprehensive Oracle Database Health Check Script.
#   - PMON-driven detection of running databases
#   - ORACLE_HOME resolved from /etc/oratab (lookup only)
#   - RAC / Single Instance aware
#   - CDB / PDB aware
#   - HugePages validated using Oracle MOS Doc ID 401749.1
#   - RAC instance status, services, load, LMS checks
#   - Tablespace, blocking session, parameter consistency checks
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
# PMON-BASED DISCOVERY (SOURCE OF TRUTH)
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
# RAC SERVICES (USER ONLY)
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
# HUGEPAGES CHECK (SUMMARY + USAGE + MOS)
#######################################
if [[ -f /proc/meminfo ]]; then

  HP_SIZE_KB=$(awk '/Hugepagesize/ {print $2}' /proc/meminfo)
  HP_TOTAL=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
  HP_FREE=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)

  report "INFO" "HugePages Summary: Total=${HP_TOTAL} Free=${HP_FREE} PageSize=${HP_SIZE_KB}KB"

  ULP=$(sql_exec "
    select nvl(value,'UNSET')
    from v\$parameter
    where name='use_large_pages';
  ")

  if [[ "$HP_TOTAL" -gt 0 ]]; then
    if [[ "$HP_TOTAL" -ne "$HP_FREE" ]]; then
      report "OK" "HugePages are being used"
    else
      if [[ "$ULP" =~ TRUE|ONLY ]]; then
        report "CRITICAL" "HugePages configured but NOT used – check with Unix team"
        report "CRITICAL" "USE_LARGE_PAGES=$ULP, DB restart / AMM / startup order issue"
      else
        report "CRITICAL" "HugePages configured at OS level but database level is set to FALSE"
        report "CRITICAL" "Set use_large_pages=TRUE|ONLY and restart database"
      fi
    fi
  else
    report "WARNING" "HugePages not configured at OS level"
  fi

  if command -v ipcs >/dev/null 2>&1; then
    NUM_PG=0
    for SEG in $(ipcs -m | awk '{print $5}' | grep -E '^[0-9]+$'); do
      PAGES=$(echo "$SEG / ($HP_SIZE_KB * 1024)" | bc)
      [[ "$PAGES" -gt 0 ]] && NUM_PG=$(echo "$NUM_PG + $PAGES + 1" | bc)
    done

    if [[ "$NUM_PG" -gt 0 ]]; then
      report "INFO" "HugePages Sizing: configured=$HP_TOTAL required=$NUM_PG"
      report "INFO" "Recommended: vm.nr_hugepages=$NUM_PG"

      [[ "$HP_TOTAL" -eq "$NUM_PG" ]] && report "OK" "HugePages correctly sized"
      [[ "$HP_TOTAL" -gt "$NUM_PG" ]] && report "WARNING" "HugePages over-allocated by $((HP_TOTAL-NUM_PG))"
      [[ "$HP_TOTAL" -lt "$NUM_PG" ]] && report "CRITICAL" "HugePages under-allocated by $((NUM_PG-HP_TOTAL))"
    fi
  fi
fi

#######################################
# USE_LARGE_PAGES PARAMETER (UNCHANGED)
#######################################
[[ "$ULP" =~ ONLY|TRUE ]] \
  && report "OK" "USE_LARGE_PAGES=$ULP" \
  || report "CRITICAL" "USE_LARGE_PAGES=$ULP"

#######################################
# RAC PARAMETER CONSISTENCY
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  for P in use_large_pages sga_target sga_max_size memory_target cluster_database; do
    CNT=$(sql_exec "select count(distinct value) from gv\$parameter where name='$P';")
    [[ "$CNT" -gt 1 ]] && report "CRITICAL" "RAC param $P inconsistent" \
                      || report "OK" "RAC param $P consistent"
  done
fi

#######################################
# TABLESPACE, BLOCKING, LOAD, LMS
# (UNCHANGED – EXACTLY AS WORKING)
#######################################
# ... continues exactly as in your pasted script ...
