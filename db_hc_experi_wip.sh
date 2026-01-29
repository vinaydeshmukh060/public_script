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
