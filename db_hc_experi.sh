#!/bin/bash
###############################################################################
# Script Name : db_hc_experi.sh
# Version     : 2.2 FINAL
# Purpose     : Oracle DB Health Check (CDB + PDB aware, DG aware)
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
set pages 0 feed off head off verify off echo off
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
IS_RAC=$(sql_exec "
select case when count(*) > 1 then 'YES' else 'NO' end
from gv\$instance;
")

report "INFO" "DB=$DB_NAME ROLE=$DB_ROLE CDB=$IS_CDB RAC=$IS_RAC"

#######################################
# DATAGUARD CHECK
#######################################
if [[ "$DB_ROLE" =~ PRIMARY|STANDBY ]]; then
  sql_exec "
select name, value
from v\$dataguard_stats
where name in ('transport lag','apply lag');
" | while read -r name value; do
    [[ -z "$value" ]] && continue
    mins=$(echo "$value" | awk -F: '{print ($1*60)+$2}')

    if [[ "$mins" -ge "$DG_CRIT_MIN" ]]; then
      report "CRITICAL" "DG $name = $value"
    elif [[ "$mins" -ge "$DG_WARN_MIN" ]]; then
      report "WARNING" "DG $name = $value"
    else
      report "OK" "DG $name = $value"
    fi
  done
else
  report "INFO" "Data Guard not configured – DG checks skipped"
fi

#######################################
# LMS CHECK
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  ps -eLo comm | grep -q ora_lms \
    && report "OK" "LMS processes running" \
    || report "CRITICAL" "LMS processes missing"
else
  report "INFO" "Non-RAC DB – LMS check skipped"
fi

#######################################
# HUGEPAGES
#######################################
total=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
free=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)

if [[ "$total" -eq 0 ]]; then
  report "CRITICAL" "HugePages not configured"
elif [[ "$free" -eq 0 ]]; then
  report "OK" "HugePages fully utilized"
else
  report "WARNING" "HugePages free=$free total=$total"
fi

#######################################
# TABLESPACE CHECK (CDB + PDB AWARE)
#######################################
check_tablespaces() {
  local container="$1"

  sql_exec "
select tablespace_name, round(used_percent)
from dba_tablespace_usage_metrics;
" | while read -r tbs used; do
    [[ ! "$used" =~ ^[0-9]+$ ]] && continue

    if [[ "$used" -ge "$TBS_CRIT" ]]; then
      report "CRITICAL" "[$container] Tablespace $tbs ${used}%"
    elif [[ "$used" -ge "$TBS_WARN" ]]; then
      report "WARNING" "[$container] Tablespace $tbs ${used}%"
    else
      report "OK" "[$container] Tablespace $tbs ${used}%"
    fi
  done
}

if [[ "$IS_CDB" == "YES" ]]; then

  # ---- CDB$ROOT ----
  sql_exec "alter session set container=CDB\$ROOT;"
  check_tablespaces "CDB\$ROOT"

  # ---- PDBs ----
  sql_exec "
select name
from v\$pdbs
where open_mode = 'READ WRITE';
" | while read -r pdb; do
      sql_exec "alter session set container=$pdb;"
      check_tablespaces "$pdb"
  done

else
  check_tablespaces "NON-CDB"
fi

#######################################
# ALERT LOG (SHOW ERRORS)
#######################################
trace=$(sql_exec "
select value from v\$diag_info where name='Diag Trace';
")
inst=$(sql_exec "select instance_name from v\$instance;")
alert="${trace}/alert_${inst}.log"

since=$(date -d "$ALERT_LOOKBACK_HOURS hours ago" '+%Y-%m-%d %H:%M:%S')
TMP_ALERT="/tmp/alert_${ORACLE_SID}_$$"

if [[ ! -f "$alert" ]]; then
  report "WARNING" "Alert log not found: $alert"
else
  awk -v s="$since" '$0>=s && /ORA-|ERROR|FATAL/' "$alert" > "$TMP_ALERT" || true

  if [[ -s "$TMP_ALERT" ]]; then
    report "WARNING" "Alert log errors in last ${ALERT_LOOKBACK_HOURS}h"
    awk 'NR<=5 {print "           " $0}' "$TMP_ALERT"

    echo "---- Alert log errors (last ${ALERT_LOOKBACK_HOURS}h) ----" >> "$LOG_FILE"
    cat "$TMP_ALERT" >> "$LOG_FILE"
    echo "---------------------------------------------------------" >> "$LOG_FILE"
  else
    report "OK" "No alert log errors in last ${ALERT_LOOKBACK_HOURS}h"
  fi
fi

rm -f "$TMP_ALERT"

#######################################
# END
#######################################
report "INFO" "Health check completed"
report "INFO" "Log file: $LOG_FILE"
