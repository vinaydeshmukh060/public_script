-- ============================================================
-- Script  : sqlid_analysis.sql
-- Purpose : Clean Forensic SQL_ID Analysis 
-- Author  : Vinay V Deshmukh
-- Version : 1.0
-- Date    : 03-Feb-2026
--
-- Notes   :
--   - Evidence-based SQL_ID analysis using GV$ and AWR views
--   - Non-interactive, cron-safe execution
--   - Designed for Oracle Database 19c
-- ============================================================

set feedback off
set verify off
set heading on
set pages 200
set lines 160
set trimspool on
set tab off

-- ============================================================
-- Capture report timestamp (must be before DEFINE OFF)
-- ============================================================
set define on
column rpt new_value rpt
select to_char(sysdate,'YYYY-MM-DD HH24:MI:SS') rpt from dual;

-- ============================================================
-- Accept SQL_ID as argument
-- ============================================================
variable sql_id varchar2(13)
exec :sql_id := '&1'
set define off

-- Safety check
begin
  if :sql_id is null then
    raise_application_error(-20001,'SQL_ID argument missing');
  end if;
end;
/

prompt ============================================================
prompt SQL_ID FORENSIC ANALYSIS REPORT
prompt SQL_ID    : 76wqq7dmct79p
prompt Generated : &rpt
prompt ============================================================

-- ============================================================
prompt [1] SQL IDENTITY AND EXECUTION FOOTPRINT
prompt ------------------------------------------------------------

col inst_id              format 99
col parsing_schema_name  format a12
col module               format a40
col executions           format 999,999
col elapsed_sec          format 9990.999999
col cpu_sec              format 9990.999999
col buffer_gets          format 999,999,999
col disk_reads           format 999,999,999
col rows_processed       format 999,999,999
col sharable_kb          format 999,999.99

select inst_id,
       parsing_schema_name,
       module,
       executions,
       elapsed_time/1e6 elapsed_sec,
       cpu_time/1e6 cpu_sec,
       buffer_gets,
       disk_reads,
       rows_processed,
       sharable_mem/1024 sharable_kb
from gv$sql
where sql_id = :sql_id
order by inst_id;

-- ============================================================
prompt [2] SQL TEXT (AWR)
prompt ------------------------------------------------------------

select dbms_lob.substr(sql_text, 4000, 1) sql_text
from dba_hist_sqltext
where sql_id = :sql_id;

-- ============================================================
prompt [3] EXECUTION QUALITY (AWR SUMMARY)
prompt ------------------------------------------------------------

select
  sum(executions_delta) executions,
  round(sum(elapsed_time_delta)/1e6,6) total_elapsed_sec,
  round(sum(cpu_time_delta)/1e6,6)     total_cpu_sec,
  round(sum(buffer_gets_delta))         total_buffer_gets,
  round(sum(disk_reads_delta))          total_disk_reads
from dba_hist_sqlstat
where sql_id = :sql_id;

-- ============================================================
prompt [4] PLAN STABILITY (AWR)
prompt ------------------------------------------------------------

select plan_hash_value,
       count(distinct snap_id) snaps,
       sum(executions_delta) executions
from dba_hist_sqlstat
where sql_id = :sql_id
group by plan_hash_value;

-- ============================================================
prompt [5] PLAN RISK INDICATORS
prompt ------------------------------------------------------------

select
  case
    when max(buffer_gets/nullif(executions,0)) > 100000
      then 'HIGH LOGICAL IO PER EXECUTION'
    when max(rows_processed/nullif(executions,0)) < 10
      then 'LOW ROW RETURN – CHECK FILTER SELECTIVITY'
    else 'NO OBVIOUS PLAN RISK'
  end as plan_risk
from gv$sql
where sql_id = :sql_id;

-- ============================================================
prompt [6] WAIT CLASS DISTRIBUTION (ASH)
prompt ------------------------------------------------------------

select
  nvl(wait_class,'CPU') wait_class,
  count(*) samples,
  round(count(*)*100/sum(count(*)) over (),2) pct
from dba_hist_active_sess_history
where sql_id = :sql_id
group by wait_class
order by samples desc;

-- ============================================================
prompt [7] CURSOR / HARD PARSE REASONS
prompt ------------------------------------------------------------

select
  dbms_lob.substr(reason,50,1) reason,
  count(*) occurrences
from gv$sql_shared_cursor
where sql_id = :sql_id
and reason is not null
group by dbms_lob.substr(reason,50,1);

-- ============================================================
prompt [8] BIND SENSITIVITY
prompt ------------------------------------------------------------

select is_bind_sensitive,
       is_bind_aware,
       executions
from gv$sql
where sql_id = :sql_id;

-- ============================================================
prompt [9] FORENSIC FINDING
prompt ------------------------------------------------------------

select
  case
    when sum(executions_delta) < 10
      then 'INSUFFICIENT EXECUTIONS – NO TUNING RECOMMENDED'
    when count(distinct plan_hash_value) > 1
      then 'PLAN INSTABILITY DETECTED'
    when sum(cpu_time_delta) > sum(elapsed_time_delta)*0.85
      then 'CPU BOUND SQL'
    else 'NO CRITICAL PERFORMANCE RISK DETECTED'
  end finding
from dba_hist_sqlstat
where sql_id = :sql_id;

-- ============================================================
prompt [10] RECOMMENDATIONS
prompt ------------------------------------------------------------

prompt - Do not tune unless execution volume increases
prompt - Monitor for plan changes across AWR snapshots
prompt - Re-run analysis after sufficient workload
prompt - Avoid hints; prefer evidence-backed actions

prompt ============================================================
prompt END OF REPORT
prompt ============================================================

set feedback on
