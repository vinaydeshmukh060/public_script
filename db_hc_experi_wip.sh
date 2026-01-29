#!/bin/bash
###############################################################################
# Script Name : db_hc_experi.sh
# Version     : 3.2.3 FINAL
#
# Author      : Vinay V Deshmukh
# Date        : 2026-01-29
#
# Description :
#   Comprehensive Oracle Database Health Check Script.
#   - PMON-driven detection of running databases
#   - ORACLE_HOME resolved from /etc/oratab
#   - RAC / Single Instance aware
#   - CDB / PDB aware
#   - HugePages validated (strict & correct)
#   - RAC instance, services, LMS, load checks
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
# PMON DISCOVERY
#######################################
get_running_sids() {
  ps -ef | awk '/ora_pmon_/ && !/ASM/ {
    sub(".*ora_pmon_", "", $NF); print $NF
  }' | sort -u
}

get_oracle_home() {
  awk -F: -v s="$1" '$1==s && $2!~/^#/ {print $2}' "$ORATAB"
}

#######################################
# CORE HEALTH CHECK
#######################################
run_health_check() {

ORACLE_SID="$1"
DATE=$(date '+%Y%m%d_%H%M%S')

ORACLE_HOME=$(get_oracle_home "$ORACLE_SID")
[[ -z "$ORACLE_HOME" || ! -d "$ORACLE_HOME" ]] && {
  echo "[CRITICAL] ORACLE_HOME not found for SID=$ORACLE_SID"
  return
}

export ORACLE_SID ORACLE_HOME
export PATH=$ORACLE_HOME/bin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=$ORACLE_HOME/lib

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/db_health_${ORACLE_SID}_${DATE}.log"

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
# HUGEPAGES CHECK (STRICT & CORRECT)
#######################################
if [[ -f /proc/meminfo ]]; then

  HP_TOTAL=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
  HP_FREE=$(awk  '/HugePages_Free/  {print $2}' /proc/meminfo)
  HP_RSVD=$(awk  '/HugePages_Rsvd/  {print $2}' /proc/meminfo)
  HP_SIZE_KB=$(awk '/Hugepagesize/   {print $2}' /proc/meminfo)

  ULP=$(sql_exec "
    select value from v\$parameter where name='use_large_pages';
  ")

  report "INFO" "HugePages Summary: Total=$HP_TOTAL Free=$HP_FREE Rsvd=$HP_RSVD PageSize=${HP_SIZE_KB}KB"

  if [[ "$HP_TOTAL" -eq 0 ]]; then
    report "WARNING" "HugePages not configured at OS level"
  else
    if [[ "$HP_FREE" -lt "$HP_TOTAL" || "$HP_RSVD" -gt 0 ]]; then
      report "OK" "HugePages are being used by Oracle"
    else
      if [[ "$ULP" =~ ^(TRUE|ONLY)$ ]]; then
        report "CRITICAL" "HugePages configured but NOT used by Oracle"
        report "CRITICAL" "Likely causes: DB started before HugePages, AMM enabled, restart required"
      else
        report "WARNING" "HugePages configured but use_large_pages=$ULP"
      fi
    fi
  fi

  #######################################
  # USE_LARGE_PAGES PARAMETER
  #######################################
  if [[ "$ULP" =~ ^(TRUE|ONLY)$ ]]; then
    report "OK" "USE_LARGE_PAGES=$ULP"
  else
    report "WARNING" "USE_LARGE_PAGES=$ULP"
  fi

  #######################################
  # HugePages Sizing (SAFE)
  #######################################
  if command -v ipcs >/dev/null 2>&1 && [[ "$HP_TOTAL" -gt 0 ]]; then
    REQUIRED_HP=$(ipcs -m | awk -v sz="$HP_SIZE_KB" '
      NR>3 && $5 ~ /^[0-9]+$/ {
        pages = int(($5 + (sz*1024) - 1) / (sz*1024))
        total += pages
      }
      END {print total}
    ')

    if [[ -n "$REQUIRED_HP" && "$REQUIRED_HP" -gt 0 ]]; then
      report "INFO" "HugePages Sizing: configured=$HP_TOTAL required=$REQUIRED_HP"
      report "INFO" "Recommended: vm.nr_hugepages=$REQUIRED_HP"

      if [[ "$HP_TOTAL" -eq "$REQUIRED_HP" ]]; then
        report "OK" "HugePages correctly sized"
      elif [[ "$HP_TOTAL" -gt "$REQUIRED_HP" ]]; then
        report "WARNING" "HugePages over-allocated by $((HP_TOTAL-REQUIRED_HP))"
      else
        report "CRITICAL" "HugePages under-allocated by $((REQUIRED_HP-HP_TOTAL))"
      fi
    fi
  fi
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
    (( u >= TBS_CRIT )) \
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
[[ "$LOCKS" -eq 0 ]] && report "OK" "No blocking sessions" \
                    || report "WARNING" "Blocking sessions detected"

#######################################
# LMS CHECK (RAC ONLY)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  LMS=$(ps -eLo cmd | grep ora_lms | grep -v ASM | grep -v grep || true)
  [[ -z "$LMS" ]] && report "CRITICAL" "No LMS processes found" \
                  || report "OK" "LMS processes present"
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
  ps -ef | grep "[o]ra_pmon_${2}$" >/dev/null || {
    echo "[ERROR] SID $2 not running"; exit 1;
  }
  run_health_check "$2"
else
  usage
fi
