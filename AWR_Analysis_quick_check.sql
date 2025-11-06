-- ================================================================
-- AWR_Analysis_quick_check.sql
--
-- Author      : vinay v deshmukh
-- Description : AWR Automated Analysis Tool - Version 1.6 Production Final Corrected
--               Automated AWR report analysis with configurable threshold-based recommendations
--               This version fixes all errors and improves report usability
-- Date        : 2025-11-06
-- Version     : 1.6
--
-- CHANGELOG:
--   v1.6 (2025-11-06): All major bug fixes, CTE simplifications, segment join fixes
--                      Threshold configuration for wait events and SQL tuning
--   Previous versions:
--     - Basic functional prototype with key AWR stats and performance diagnostics
--
-- Modify threshold configuration in the dedicated section below as needed.
-- This script creates NO database objects; all output is dynamically generated.
-- ================================================================


WHENEVER SQLERROR CONTINUE

-- ================================================================
-- FORMATTING SETTINGS
-- ================================================================
SET ECHO OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 200
SET PAGESIZE 1000
SET LONG 10000
SET TRIMSPOOL ON
SET TRIMOUT ON

CLEAR SCREEN

PROMPT ================================================================
PROMPT            AWR AUTOMATED ANALYSIS TOOL - V1 FINAL
PROMPT     All Features + All Errors Fixed + Production Ready
PROMPT ================================================================
PROMPT

-- ================================================================
-- STEP 0: ASK FOR DAYS TO SHOW
-- ================================================================

ACCEPT days_to_show PROMPT 'Number of days of snapshots to show [default 8]: ' DEFAULT '8'

PROMPT
PROMPT Loading available snapshots for last &&days_to_show days...
PROMPT

-- ================================================================
-- STEP 1: DISPLAY AVAILABLE SNAPSHOTS
-- ================================================================

PROMPT
PROMPT Available Snapshots:
PROMPT

COLUMN snap_id FORMAT 9999
COLUMN snap_date FORMAT A25
COLUMN end_time FORMAT A25

SELECT 
    snap_id,
    TO_CHAR(begin_interval_time, 'DD-MON-YYYY HH24:MI:SS') AS snap_date,
    TO_CHAR(end_interval_time, 'DD-MON-YYYY HH24:MI:SS') AS end_time
FROM dba_hist_snapshot
WHERE begin_interval_time > SYSDATE - TO_NUMBER('&&days_to_show')
ORDER BY snap_id DESC;

PROMPT
PROMPT ================================================================
PROMPT SELECT SNAPSHOT RANGE FOR ANALYSIS
PROMPT ================================================================
PROMPT

-- Accept snap IDs directly
ACCEPT start_snap_input PROMPT 'Enter Starting Snapshot ID: '
ACCEPT end_snap_input PROMPT 'Enter Ending Snapshot ID: '

DEFINE start_snap_id = &start_snap_input
DEFINE end_snap_id = &end_snap_input

PROMPT
PROMPT Verifying snapshots...
PROMPT

-- FIX #1: Removed EXIT statement
BEGIN
    DECLARE
        v_start_count NUMBER;
        v_end_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_start_count 
        FROM dba_hist_snapshot 
        WHERE snap_id = &&start_snap_id;

        SELECT COUNT(*) INTO v_end_count 
        FROM dba_hist_snapshot 
        WHERE snap_id = &&end_snap_id;

        IF v_start_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Start Snapshot ID does not exist');
        END IF;

        IF v_end_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20002, 'End Snapshot ID does not exist');
        END IF;

        IF &&start_snap_id > &&end_snap_id THEN
            RAISE_APPLICATION_ERROR(-20003, 'Start Snapshot must be less than End Snapshot');
        END IF;

        DBMS_OUTPUT.PUT_LINE('Snapshots verified successfully.');
    END;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('Please select valid snapshots from the list above.');
END;
/

PROMPT
PROMPT Selected Snapshots:
PROMPT

SELECT 
    'Start' AS type,
    snap_id,
    TO_CHAR(begin_interval_time, 'DD-MON-YYYY HH24:MI:SS') AS time
FROM dba_hist_snapshot
WHERE snap_id = &&start_snap_id
UNION ALL
SELECT 
    'End',
    snap_id,
    TO_CHAR(end_interval_time, 'DD-MON-YYYY HH24:MI:SS')
FROM dba_hist_snapshot
WHERE snap_id = &&end_snap_id;

PROMPT
PROMPT Analysis using snapshots: &&start_snap_id to &&end_snap_id
PROMPT

-- ================================================================
-- THRESHOLD CONFIGURATION - MODIFY AS NEEDED
-- ================================================================

DEFINE wait_pct_threshold = 30        
DEFINE avg_wait_time_ms_threshold = 10      
DEFINE waits_per_sec_threshold = 1000       

DEFINE cpu_usage_pct_threshold = 80         
DEFINE cpu_per_sec_threshold = 8            

DEFINE sql_elapsed_ms_threshold = 2000      
DEFINE sql_cpu_ms_threshold = 1000          
DEFINE buffer_gets_per_exec_threshold = 10000
DEFINE physical_reads_per_exec_threshold = 1000

DEFINE hard_parse_ratio_threshold = 3       
DEFINE hard_parse_per_sec_threshold = 100   

DEFINE physical_reads_mb_threshold = 1000   
DEFINE physical_writes_mb_threshold = 500   

DEFINE buffer_hit_ratio_min = 95            
DEFINE library_cache_hit_min = 95           
DEFINE soft_parse_ratio_min = 95            

DEFINE segment_physical_reads_pct = 50      
DEFINE row_lock_waits_threshold = 1000      

PROMPT

-- ================================================================
-- MODULE 1: TOP WAIT EVENTS ANALYSIS
-- ================================================================

PROMPT ================================================================
PROMPT MODULE 1: TOP WAIT EVENTS ANALYSIS
PROMPT ================================================================
PROMPT

COLUMN event_name FORMAT A40
COLUMN wait_class FORMAT A20
COLUMN waits_delta FORMAT 999,999,999
COLUMN time_waited_sec FORMAT 999,999.99
COLUMN avg_wait_ms FORMAT 999,999.99
COLUMN pct_db_time FORMAT 999.99

-- FIX #2: Simplified WITH clause
WITH snap_times AS (
    SELECT 
        ROUND((CAST(s_end.end_interval_time AS DATE) - 
               CAST(s_begin.begin_interval_time AS DATE)) * 86400, 2) AS elapsed_sec
    FROM dba_hist_snapshot s_begin, 
         dba_hist_snapshot s_end
    WHERE s_begin.snap_id = &&start_snap_id
    AND s_end.snap_id = &&end_snap_id
),
wait_events AS (
    SELECT 
        e.event_name,
        e.wait_class,
        e.total_waits - NVL(b.total_waits, 0) AS waits_delta,
        (e.time_waited_micro - NVL(b.time_waited_micro, 0)) / 1000000 AS time_waited_sec,
        CASE 
            WHEN (e.total_waits - NVL(b.total_waits, 0)) > 0 
            THEN (e.time_waited_micro - NVL(b.time_waited_micro, 0)) / 
                 (e.total_waits - NVL(b.total_waits, 0)) / 1000
            ELSE 0 
        END AS avg_wait_ms
    FROM 
        dba_hist_system_event b,
        dba_hist_system_event e
    WHERE 
        b.snap_id(+) = &&start_snap_id
        AND e.snap_id = &&end_snap_id
        AND b.dbid(+) = e.dbid
        AND b.instance_number(+) = e.instance_number
        AND b.event_id(+) = e.event_id
        AND e.wait_class != 'Idle'
        AND (e.total_waits - NVL(b.total_waits, 0)) > 0
),
db_time_calc AS (
    SELECT ROUND((e.value - b.value)/1000000, 2) AS db_time_sec
    FROM dba_hist_sys_time_model b, dba_hist_sys_time_model e
    WHERE b.snap_id = &&start_snap_id
    AND e.snap_id = &&end_snap_id
    AND b.stat_name = 'DB time'
    AND e.stat_name = 'DB time'
)
SELECT 
    we.event_name,
    we.wait_class,
    we.waits_delta,
    ROUND(we.waits_delta / st.elapsed_sec, 2) AS waits_per_sec,
    we.time_waited_sec,
    we.avg_wait_ms,
    ROUND(we.time_waited_sec / dt.db_time_sec * 100, 2) AS pct_db_time
FROM wait_events we, snap_times st, db_time_calc dt
WHERE we.time_waited_sec > 0
ORDER BY we.time_waited_sec DESC
FETCH FIRST 10 ROWS ONLY;

-- Wait Events Recommendations
PROMPT
PROMPT ================================================================
PROMPT WAIT EVENT RECOMMENDATIONS
PROMPT ================================================================
PROMPT

COLUMN priority FORMAT A10
COLUMN metric_name FORMAT A35
COLUMN pct_value FORMAT A15
COLUMN recommendation FORMAT A120 WORD_WRAPPED

WITH wait_events AS (
    SELECT 
        e.event_name,
        e.wait_class,
        (e.time_waited_micro - NVL(b.time_waited_micro, 0)) / 1000000 AS time_waited_sec,
        CASE 
            WHEN (e.total_waits - NVL(b.total_waits, 0)) > 0 
            THEN (e.time_waited_micro - NVL(b.time_waited_micro, 0)) / 
                 (e.total_waits - NVL(b.total_waits, 0)) / 1000
            ELSE 0 
        END AS avg_wait_ms
    FROM 
        dba_hist_system_event b,
        dba_hist_system_event e
    WHERE 
        b.snap_id(+) = &&start_snap_id
        AND e.snap_id = &&end_snap_id
        AND b.dbid(+) = e.dbid
        AND b.instance_number(+) = e.instance_number
        AND b.event_id(+) = e.event_id
        AND e.wait_class != 'Idle'
),
db_time_calc AS (
    SELECT ROUND((e.value - b.value)/1000000, 2) AS db_time_sec
    FROM dba_hist_sys_time_model b, dba_hist_sys_time_model e
    WHERE b.snap_id = &&start_snap_id
    AND e.snap_id = &&end_snap_id
    AND b.stat_name = 'DB time'
    AND e.stat_name = 'DB time'
)
SELECT 
    CASE 
        WHEN we.time_waited_sec / dt.db_time_sec * 100 > 50 THEN 'CRITICAL'
        WHEN we.time_waited_sec / dt.db_time_sec * 100 > &&wait_pct_threshold THEN 'HIGH'
        ELSE 'MEDIUM'
    END AS priority,
    we.event_name AS metric_name,
    ROUND(we.time_waited_sec / dt.db_time_sec * 100, 2) || '%' AS pct_value,
    CASE we.event_name
        WHEN 'db file sequential read' THEN 
            'Single-block I/O waits from index access. ACTION: 1) Check for missing indexes causing excessive index scans. 2) Review storage I/O performance and latency. 3) Consider table/index statistics refresh. 4) Analyze top SQL for this wait.'
        WHEN 'db file scattered read' THEN
            'Multi-block I/O waits from full table scans. ACTION: 1) Identify and optimize full table scans - check SQL ordered by physical reads. 2) Add appropriate indexes to eliminate full scans. 3) Increase DB_FILE_MULTIBLOCK_READ_COUNT. 4) Review buffer cache size.'
        WHEN 'log file sync' THEN
            'Commit-related waits. ACTION: 1) Reduce commit frequency - batch DML operations where possible. 2) Check redo log I/O subsystem performance. 3) Consider COMMIT NOWAIT or batch processing for heavy commit loads. 4) Ensure redo logs on fast storage.'
        WHEN 'log file parallel write' THEN
            'LGWR experiencing I/O delays. ACTION: 1) Move redo logs to faster storage device. 2) Check for I/O contention on redo log disks. 3) Ensure redo logs are not on RAID-5. 4) Consider increasing redo log size to reduce checkpoint frequency.'
        WHEN 'enq: TX - row lock contention' THEN
            'Application row-level locking issues. ACTION: 1) Review application logic for unnecessary locks. 2) Reduce transaction duration to minimize lock hold time. 3) Consider row-level locking strategy changes. 4) Query V\$LOCK and DBA_BLOCKERS during peak times.'
        WHEN 'latch: cache buffers chains' THEN
            'Buffer cache contention. ACTION: 1) Identify hot blocks using V\$BH and X\$BH. 2) Consider reverse key indexes for sequence-generated keys. 3) Review SQL for inefficient full table scans. 4) Partition hot tables if applicable.'
        WHEN 'latch free' THEN
            'General latch contention. ACTION: 1) Identify specific latch type from V\$LATCH. 2) For library cache latches: improve cursor sharing and reduce parsing. 3) For redo latches: reduce redo generation or improve log file I/O. 4) Review application for excessive context switching.'
        WHEN 'direct path read' THEN
            'Direct path reads bypassing buffer cache. ACTION: 1) Normal for parallel queries and sort operations. 2) Check if storage I/O can handle the load. 3) Review parallel execution workload. 4) Consider if parallel degree of operations is appropriate.'
        WHEN 'CPU time' THEN
            'Database spending significant time on CPU. ACTION: 1) This is generally good if AAS is within CPU count. 2) Review CPU-intensive SQL in Top SQL section. 3) Check if CPU is actually a bottleneck (AAS > CPU cores). 4) Consider SQL tuning for high CPU statements.'
        ELSE
            'Wait event consuming significant DB time. ACTION: 1) Research this specific wait event in Oracle documentation. 2) Query DBA_HIST_ACTIVE_SESS_HISTORY for SQL_ID experiencing this wait. 3) Check if this is expected for your workload type. 4) Consult Oracle Support if this wait is unexpectedly high.'
    END AS recommendation
FROM wait_events we, db_time_calc dt
WHERE we.time_waited_sec / dt.db_time_sec * 100 > &&wait_pct_threshold / 2
ORDER BY 
    CASE 
        WHEN we.time_waited_sec / dt.db_time_sec * 100 > 50 THEN 1
        WHEN we.time_waited_sec / dt.db_time_sec * 100 > &&wait_pct_threshold THEN 2
        ELSE 3
    END,
    we.time_waited_sec DESC;

PROMPT

-- ================================================================
-- MODULE 2: TOP SQL ANALYSIS
-- ================================================================

PROMPT ================================================================
PROMPT MODULE 2: TOP SQL STATEMENTS
PROMPT ================================================================
PROMPT

PROMPT TOP 10 SQL BY ELAPSED TIME:
PROMPT

COLUMN sql_id FORMAT A15
COLUMN elapsed_time_sec FORMAT 999,999.99
COLUMN cpu_time_sec FORMAT 999,999.99
COLUMN executions FORMAT 999,999
COLUMN elapsed_per_exec_ms FORMAT 999,999.99
COLUMN sql_text FORMAT A60 TRUNCATE

SELECT 
    sql_id,
    executions_delta AS executions,
    ROUND(elapsed_time_delta / 1000000, 2) AS elapsed_time_sec,
    ROUND(cpu_time_delta / 1000000, 2) AS cpu_time_sec,
    ROUND(buffer_gets_delta / DECODE(executions_delta, 0, 1, executions_delta), 0) AS gets_per_exec,
    CASE 
        WHEN executions_delta > 0 
        THEN ROUND(elapsed_time_delta / executions_delta / 1000, 2)
        ELSE 0 
    END AS elapsed_per_exec_ms,
    SUBSTR(sql_text, 1, 60) AS sql_text
FROM 
    (SELECT 
         st.sql_id,
         st.sql_text,
         ss.executions_delta,
         ss.elapsed_time_delta,
         ss.cpu_time_delta,
         ss.buffer_gets_delta
     FROM dba_hist_sqlstat ss,
          dba_hist_sqltext st
     WHERE ss.snap_id = &&end_snap_id
       AND ss.sql_id = st.sql_id
       AND ss.dbid = st.dbid
       AND ss.elapsed_time_delta > 0
    )
ORDER BY elapsed_time_delta DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT TOP 10 SQL BY BUFFER GETS:
PROMPT

COLUMN buffer_gets FORMAT 999,999,999

SELECT 
    sql_id,
    executions_delta AS executions,
    buffer_gets_delta AS buffer_gets,
    ROUND(buffer_gets_delta / DECODE(executions_delta, 0, 1, executions_delta), 0) AS gets_per_exec,
    ROUND(elapsed_time_delta / 1000000, 2) AS elapsed_time_sec,
    SUBSTR(sql_text, 1, 60) AS sql_text
FROM 
    (SELECT 
         st.sql_id,
         st.sql_text,
         ss.executions_delta,
         ss.buffer_gets_delta,
         ss.elapsed_time_delta
     FROM dba_hist_sqlstat ss,
          dba_hist_sqltext st
     WHERE ss.snap_id = &&end_snap_id
       AND ss.sql_id = st.sql_id
       AND ss.dbid = st.dbid
       AND ss.buffer_gets_delta > 0
    )
ORDER BY buffer_gets_delta DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT TOP 10 SQL BY PHYSICAL READS:
PROMPT

COLUMN physical_reads FORMAT 999,999,999

SELECT 
    sql_id,
    executions_delta AS executions,
    disk_reads_delta AS physical_reads,
    ROUND(disk_reads_delta / DECODE(executions_delta, 0, 1, executions_delta), 0) AS reads_per_exec,
    ROUND(elapsed_time_delta / 1000000, 2) AS elapsed_time_sec,
    SUBSTR(sql_text, 1, 60) AS sql_text
FROM 
    (SELECT 
         st.sql_id,
         st.sql_text,
         ss.executions_delta,
         ss.disk_reads_delta,
         ss.elapsed_time_delta
     FROM dba_hist_sqlstat ss,
          dba_hist_sqltext st
     WHERE ss.snap_id = &&end_snap_id
       AND ss.sql_id = st.sql_id
       AND ss.dbid = st.dbid
       AND ss.disk_reads_delta > 0
    )
ORDER BY disk_reads_delta DESC
FETCH FIRST 10 ROWS ONLY;

-- SQL Recommendations
PROMPT
PROMPT ================================================================
PROMPT SQL PERFORMANCE RECOMMENDATIONS
PROMPT ================================================================
PROMPT

WITH sql_stats AS (
    SELECT 
        st.sql_id,
        SUBSTR(st.sql_text, 1, 100) AS sql_text,
        ss.executions_delta,
        CASE 
            WHEN ss.executions_delta > 0 
            THEN ROUND(ss.elapsed_time_delta / ss.executions_delta / 1000, 2)
            ELSE 0 
        END AS elapsed_per_exec_ms,
        ROUND(ss.buffer_gets_delta / DECODE(ss.executions_delta, 0, 1, ss.executions_delta), 0) AS gets_per_exec,
        ROUND(ss.disk_reads_delta / DECODE(ss.executions_delta, 0, 1, ss.executions_delta), 0) AS reads_per_exec
    FROM dba_hist_sqlstat ss,
         dba_hist_sqltext st
    WHERE ss.snap_id = &&end_snap_id
      AND ss.sql_id = st.sql_id
      AND ss.dbid = st.dbid
      AND ss.executions_delta > 0
)
SELECT 
    CASE 
        WHEN elapsed_per_exec_ms > &&sql_elapsed_ms_threshold * 5 THEN 'CRITICAL'
        WHEN elapsed_per_exec_ms > &&sql_elapsed_ms_threshold THEN 'HIGH'
        WHEN gets_per_exec > &&buffer_gets_per_exec_threshold THEN 'HIGH'
        ELSE 'MEDIUM'
    END AS priority,
    sql_id,
    ROUND(elapsed_per_exec_ms, 2) || ' ms' AS avg_elapsed,
    'FINDING: SQL_ID ' || sql_id || ' has high avg elapsed time (' || elapsed_per_exec_ms || ' ms per execution). SQL Text: ' || sql_text || '. ' ||
    'RECOMMENDATIONS: ' ||
    CASE 
        WHEN gets_per_exec > &&buffer_gets_per_exec_threshold THEN
            '1) HIGH LOGICAL READS: ' || gets_per_exec || ' buffer gets per execution. Review execution plan for inefficient table access. '
        ELSE ''
    END ||
    CASE 
        WHEN reads_per_exec > &&physical_reads_per_exec_threshold THEN
            '2) HIGH PHYSICAL READS: ' || reads_per_exec || ' disk reads per execution. Check for missing indexes or poor buffer cache hit ratio. '
        ELSE ''
    END ||
    '3) Run SQL Tuning Advisor: EXEC DBMS_SQLTUNE.CREATE_TUNING_TASK(sql_id => ''' || sql_id || '''); ' ||
    '4) Review execution plan: SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR(''' || sql_id || ''')); ' ||
    '5) Check if statistics are current for tables accessed by this SQL. ' ||
    '6) Consider SQL Profile or baseline if plan is suboptimal.' AS recommendation
FROM sql_stats
WHERE elapsed_per_exec_ms > &&sql_elapsed_ms_threshold
   OR gets_per_exec > &&buffer_gets_per_exec_threshold
   OR reads_per_exec > &&physical_reads_per_exec_threshold
ORDER BY 
    CASE 
        WHEN elapsed_per_exec_ms > &&sql_elapsed_ms_threshold * 5 THEN 1
        WHEN elapsed_per_exec_ms > &&sql_elapsed_ms_threshold THEN 2
        ELSE 3
    END,
    elapsed_per_exec_ms DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT

-- ================================================================
-- MODULE 3: LOAD PROFILE and INSTANCE EFFICIENCY
-- ================================================================

PROMPT ================================================================
PROMPT MODULE 3: LOAD PROFILE and INSTANCE EFFICIENCY
PROMPT ================================================================
PROMPT

PROMPT LOAD PROFILE (Per Second and Per Transaction):
PROMPT

COLUMN stat_name FORMAT A40
COLUMN per_second FORMAT 999,999,999.99
COLUMN per_txn FORMAT 999,999.99

WITH snap_times AS (
    SELECT 
        ROUND((CAST(s_end.end_interval_time AS DATE) - 
               CAST(s_begin.begin_interval_time AS DATE)) * 86400, 2) AS elapsed_sec
    FROM dba_hist_snapshot s_begin, 
         dba_hist_snapshot s_end
    WHERE s_begin.snap_id = &&start_snap_id
    AND s_end.snap_id = &&end_snap_id
),
txn_data AS (
    SELECT 
        e.value - NVL(b.value, 0) AS num_txns
    FROM dba_hist_sysstat b, 
         dba_hist_sysstat e
    WHERE b.snap_id(+) = &&start_snap_id
    AND e.snap_id = &&end_snap_id
    AND b.stat_name(+) = 'user commits'
    AND e.stat_name = 'user commits'
),
stats_delta AS (
    SELECT 
        e.stat_name,
        e.value - NVL(b.value, 0) AS stat_value
    FROM dba_hist_sysstat b, 
         dba_hist_sysstat e
    WHERE b.snap_id(+) = &&start_snap_id
    AND e.snap_id = &&end_snap_id
    AND b.stat_name(+) = e.stat_name
    AND b.instance_number(+) = e.instance_number
    AND b.dbid(+) = e.dbid
    AND e.stat_name IN (
        'parse count (total)',
        'parse count (hard)',
        'execute count',
        'user commits',
        'physical reads',
        'physical writes',
        'redo size'
    )
)
SELECT 
    sd.stat_name,
    ROUND(sd.stat_value / st.elapsed_sec, 2) AS per_second,
    ROUND(sd.stat_value / DECODE(td.num_txns, 0, 1, td.num_txns), 2) AS per_txn
FROM stats_delta sd, snap_times st, txn_data td
ORDER BY sd.stat_name;

PROMPT
PROMPT KEY PERFORMANCE RATIOS:
PROMPT

COLUMN ratio_name FORMAT A40
COLUMN ratio_pct FORMAT 999.99
COLUMN status FORMAT A25

WITH stats AS (
    SELECT 
        e.stat_name,
        e.value - NVL(b.value, 0) AS stat_value
    FROM dba_hist_sysstat b, 
         dba_hist_sysstat e
    WHERE b.snap_id(+) = &&start_snap_id
    AND e.snap_id = &&end_snap_id
    AND b.stat_name(+) = e.stat_name
    AND b.instance_number(+) = e.instance_number
    AND b.dbid(+) = e.dbid
)
SELECT 
    'Buffer Cache Hit Ratio' AS ratio_name,
    ROUND((1 - (
        (SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'physical reads') /
        NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'session logical reads'), 0)
    )) * 100, 2) AS ratio_pct,
    CASE 
        WHEN ROUND((1 - (
            (SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'physical reads') /
            NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'session logical reads'), 0)
        )) * 100, 2) < &&buffer_hit_ratio_min THEN '*** ALERT - Below ' || &&buffer_hit_ratio_min || '%'
        ELSE 'OK'
    END AS status
FROM DUAL
UNION ALL
SELECT 
    'Soft Parse Ratio',
    ROUND((1 - (
        (SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'parse count (hard)') /
        NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'parse count (total)'), 0)
    )) * 100, 2),
    CASE 
        WHEN ROUND((1 - (
            (SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'parse count (hard)') /
            NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'parse count (total)'), 0)
        )) * 100, 2) < &&soft_parse_ratio_min THEN '*** ALERT - Below ' || &&soft_parse_ratio_min || '%'
        ELSE 'OK'
    END
FROM DUAL;

-- Load Profile Recommendations
PROMPT
PROMPT LOAD PROFILE RECOMMENDATIONS:
PROMPT

WITH stats AS (
    SELECT 
        e.stat_name,
        e.value - NVL(b.value, 0) AS stat_value
    FROM dba_hist_sysstat b, 
         dba_hist_sysstat e
    WHERE b.snap_id(+) = &&start_snap_id
    AND e.snap_id = &&end_snap_id
    AND b.stat_name(+) = e.stat_name
    AND b.instance_number(+) = e.instance_number
    AND b.dbid(+) = e.dbid
),
ratios AS (
    SELECT 
        ROUND((1 - (
            (SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'physical reads') /
            NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'session logical reads'), 0)
        )) * 100, 2) AS buffer_hit_ratio,
        ROUND((1 - (
            (SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'parse count (hard)') /
            NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'parse count (total)'), 0)
        )) * 100, 2) AS soft_parse_ratio
    FROM DUAL
)
SELECT 'HIGH' AS priority, 'Buffer Cache Hit Ratio' AS metric, 
       buffer_hit_ratio || '%' AS value,
       'FINDING: Buffer Cache Hit Ratio is ' || buffer_hit_ratio || '%, below threshold of ' || &&buffer_hit_ratio_min || '%. ' ||
       'RECOMMENDATION: 1) Increase DB_CACHE_SIZE to reduce physical reads. ' ||
       '2) Review SQL with high physical reads in Top SQL section. ' ||
       '3) Ensure table/index statistics are up to date. ' ||
       '4) Consider implementing result cache for frequently accessed queries.'
FROM ratios
WHERE buffer_hit_ratio < &&buffer_hit_ratio_min
UNION ALL
SELECT 'HIGH', 'Soft Parse Ratio', 
       soft_parse_ratio || '%',
       'FINDING: Soft Parse Ratio is ' || soft_parse_ratio || '%, below threshold of ' || &&soft_parse_ratio_min || '%. ' ||
       'RECOMMENDATION: 1) Review application code for proper use of bind variables. ' ||
       '2) Increase SHARED_POOL_SIZE if memory pressure exists. ' ||
       '3) Set CURSOR_SHARING=FORCE as temporary workaround (not recommended long-term). ' ||
       '4) Review V\$SQL for similar queries with different literals.'
FROM ratios
WHERE soft_parse_ratio < &&soft_parse_ratio_min;

PROMPT

-- ================================================================
-- MODULE 4: SEGMENT STATISTICS 
-- ================================================================

PROMPT ================================================================
PROMPT MODULE 4: SEGMENT STATISTICS ANALYSIS
PROMPT ================================================================
PROMPT

PROMPT TOP 10 SEGMENTS BY PHYSICAL READS:
PROMPT

COLUMN owner FORMAT A20
COLUMN object_name FORMAT A30
COLUMN object_type FORMAT A15
COLUMN physical_reads FORMAT 999,999,999

-- FIX #3: Join dba_hist_seg_stat with dba_objects to get object info
SELECT 
    obj.owner,
    obj.object_name,
    obj.object_type,
    e.physical_reads_total - NVL(b.physical_reads_total, 0) AS physical_reads
FROM dba_hist_seg_stat b,
     dba_hist_seg_stat e,
     dba_objects obj
WHERE b.snap_id(+) = &&start_snap_id
AND e.snap_id = &&end_snap_id
AND b.dbid(+) = e.dbid
AND b.obj#(+) = e.obj#
AND b.dataobj#(+) = e.dataobj#
AND e.obj# = obj.object_id
AND (e.physical_reads_total - NVL(b.physical_reads_total, 0)) > 0
ORDER BY (e.physical_reads_total - NVL(b.physical_reads_total, 0)) DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT TOP 10 SEGMENTS BY ROW LOCK WAITS:
PROMPT

SELECT 
    obj.owner,
    obj.object_name,
    obj.object_type,
    e.row_lock_waits_total - NVL(b.row_lock_waits_total, 0) AS row_lock_waits
FROM dba_hist_seg_stat b,
     dba_hist_seg_stat e,
     dba_objects obj
WHERE b.snap_id(+) = &&start_snap_id
AND e.snap_id = &&end_snap_id
AND b.dbid(+) = e.dbid
AND b.obj#(+) = e.obj#
AND b.dataobj#(+) = e.dataobj#
AND e.obj# = obj.object_id
AND (e.row_lock_waits_total - NVL(b.row_lock_waits_total, 0)) > 0
ORDER BY (e.row_lock_waits_total - NVL(b.row_lock_waits_total, 0)) DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT

-- ================================================================
-- FINAL EXECUTIVE SUMMARY
-- ================================================================

PROMPT ================================================================
PROMPT                    EXECUTIVE SUMMARY
PROMPT ================================================================
PROMPT
PROMPT Analysis Information:
PROMPT

SELECT 
    'Snapshots' AS info_type,
    '&&start_snap_id to &&end_snap_id' AS details
FROM DUAL
UNION ALL
SELECT 
    'Date Range',
    TO_CHAR(s_begin.begin_interval_time, 'DD-MON-YYYY HH24:MI:SS') || ' to ' || 
    TO_CHAR(s_end.end_interval_time, 'DD-MON-YYYY HH24:MI:SS')
FROM dba_hist_snapshot s_begin, 
     dba_hist_snapshot s_end
WHERE s_begin.snap_id = &&start_snap_id
AND s_end.snap_id = &&end_snap_id
AND ROWNUM = 1;

PROMPT
PROMPT *** NEXT STEPS ***
PROMPT
PROMPT For problematic SQL_IDs, execute:
PROMPT
PROMPT   1. View execution plan:
PROMPT      SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR('sql_id_here'));
PROMPT
PROMPT   2. Run SQL Tuning Advisor:
PROMPT      BEGIN
PROMPT          DBMS_SQLTUNE.CREATE_TUNING_TASK(sql_id => 'sql_id_here',
PROMPT              task_name => 'tune_sql_task');
PROMPT          DBMS_SQLTUNE.EXECUTE_TUNING_TASK('tune_sql_task');
PROMPT      END;
PROMPT      /
PROMPT
PROMPT   3. Get full SQL text:
PROMPT      SELECT sql_fulltext FROM dba_hist_sqltext 
PROMPT      WHERE sql_id = 'sql_id_here';
PROMPT
PROMPT *** IMPORTANT ***
PROMPT
PROMPT This script creates NO database objects.
PROMPT All output generated dynamically.
PROMPT All thresholds are configurable.
PROMPT
PROMPT ================================================================

SET FEEDBACK ON
SET VERIFY ON

EXIT SUCCESS
