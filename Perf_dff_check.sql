-- ================================================================
-- Perf_dff_check.sql
--
-- Author      : vinay v deshmukh
-- Description : AWR Automated Analysis Tool - Complete Period Comparison
--               Fully configurable thresholds for load profile and cache ratios.
--               Designed to highlight major DB health metrics and efficiency hotspots.
-- Date        : 2025-11-06
-- Version     : 2.5
--
-- CHANGELOG:
--   v2.5 (2025-11-06): Configurable thresholds for diagnostics, 6 metrics in Module 4,
--                      bugfix for cache ratio visibility, all original modules preserved.
--   v2.4 (2025-10-21): Baseline - working with all original modules, no diagnostic add.
--
-- Modify thresholds in the section below as needed for your site.
-- ================================================================

-- Cache Ratio Difference Threshold (show changes >= this value)
DEFINE cache_diff_threshold = 0.1

-- Module 4 - Diagnostic Ratios Thresholds
DEFINE hard_parse_threshold = 10           -- Hard Parse % > this = HIGH
DEFINE redo_per_txn_threshold = 100        -- Redo per Commit (KB) > this = HIGH
DEFINE reads_per_txn_threshold = 50        -- Reads per Commit > this = HIGH
DEFINE writes_per_txn_threshold = 50       -- Writes per Commit (KB) > this = HIGH
DEFINE exec_parse_ratio_threshold = 3      -- Execute/Parse Ratio < this = LOW
DEFINE cpu_per_txn_threshold = 100         -- CPU per Commit (ms) > this = HIGH

-- ================================================================
-- END OF THRESHOLD CONFIGURATION
-- ================================================================

WHENEVER SQLERROR CONTINUE

SET ECHO OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 250
SET PAGESIZE 1000
SET LONG 10000
SET TRIMSPOOL ON
SET TRIMOUT ON

CLEAR SCREEN

PROMPT ================================================================
PROMPT        AWR AUTOMATED ANALYSIS TOOL - COMPLETE COMPARISON
PROMPT   Full Automated Analysis for Two Time Periods
PROMPT ================================================================
PROMPT

ACCEPT days_to_show PROMPT 'Number of days of snapshots to show [default 8]: ' DEFAULT '8'

PROMPT
PROMPT Loading available snapshots for last &&days_to_show days...
PROMPT

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
PROMPT SELECT BASE PERIOD (Earlier Period)
PROMPT ================================================================
PROMPT

ACCEPT base_start_input PROMPT 'Enter Base Period Starting Snapshot ID: '
ACCEPT base_end_input PROMPT 'Enter Base Period Ending Snapshot ID: '

DEFINE base_start = &base_start_input
DEFINE base_end = &base_end_input

PROMPT
PROMPT ================================================================
PROMPT SELECT COMPARISON PERIOD (Later Period)
PROMPT ================================================================
PROMPT

ACCEPT comp_start_input PROMPT 'Enter Comparison Period Starting Snapshot ID: '
ACCEPT comp_end_input PROMPT 'Enter Comparison Period Ending Snapshot ID: '

DEFINE comp_start = &comp_start_input
DEFINE comp_end = &comp_end_input

PROMPT
PROMPT Verifying snapshots...
PROMPT

BEGIN
    DECLARE
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count FROM dba_hist_snapshot 
        WHERE snap_id IN (&&base_start, &&base_end, &&comp_start, &&comp_end);

        IF v_count < 4 THEN
            RAISE_APPLICATION_ERROR(-20001, 'One or more snapshot IDs do not exist');
        END IF;

        IF &&base_start > &&base_end THEN
            RAISE_APPLICATION_ERROR(-20002, 'Base: Start snap must be < End snap');
        END IF;

        IF &&comp_start > &&comp_end THEN
            RAISE_APPLICATION_ERROR(-20003, 'Comparison: Start snap must be < End snap');
        END IF;

        DBMS_OUTPUT.PUT_LINE('All snapshots verified successfully.');
    END;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('ERROR: ' || SQLERRM);
END;
/

PROMPT
PROMPT Analysis Periods:
PROMPT

SELECT 'BASE - Start' AS period_type, snap_id, TO_CHAR(begin_interval_time, 'DD-MON-YYYY HH24:MI:SS') AS time
FROM dba_hist_snapshot WHERE snap_id = &&base_start
UNION ALL
SELECT 'BASE - End', snap_id, TO_CHAR(end_interval_time, 'DD-MON-YYYY HH24:MI:SS')
FROM dba_hist_snapshot WHERE snap_id = &&base_end
UNION ALL
SELECT 'COMPARISON - Start', snap_id, TO_CHAR(begin_interval_time, 'DD-MON-YYYY HH24:MI:SS')
FROM dba_hist_snapshot WHERE snap_id = &&comp_start
UNION ALL
SELECT 'COMPARISON - End', snap_id, TO_CHAR(end_interval_time, 'DD-MON-YYYY HH24:MI:SS')
FROM dba_hist_snapshot WHERE snap_id = &&comp_end;

PROMPT
PROMPT Analysis Configuration:
PROMPT   Base Period:              Snapshots &&base_start to &&base_end
PROMPT   Comparison Period:        Snapshots &&comp_start to &&comp_end
PROMPT   Cache Ratio Threshold:    &&cache_diff_threshold
PROMPT   Hard Parse % Threshold:   &&hard_parse_threshold
PROMPT   Redo per Txn Threshold:   &&redo_per_txn_threshold KB
PROMPT   Reads per Txn Threshold:  &&reads_per_txn_threshold
PROMPT   Writes per Txn Threshold: &&writes_per_txn_threshold KB
PROMPT   CPU per Txn Threshold:    &&cpu_per_txn_threshold ms
PROMPT

PROMPT

-- ================================================================
-- MODULE 1: WAIT EVENTS COMPARISON
-- ================================================================

PROMPT ================================================================
PROMPT MODULE 1: WAIT EVENTS COMPARISON
PROMPT ================================================================
PROMPT

PROMPT BASE PERIOD:
PROMPT

COLUMN event_name FORMAT A40
COLUMN time_waited_sec FORMAT 999,999.99
COLUMN pct_db_time FORMAT 999.99

WITH wait_events AS (
    SELECT e.event_name, (e.time_waited_micro - NVL(b.time_waited_micro, 0)) / 1000000 AS time_waited_sec
    FROM dba_hist_system_event b, dba_hist_system_event e
    WHERE b.snap_id(+) = &&base_start AND e.snap_id = &&base_end AND b.dbid(+) = e.dbid
    AND b.instance_number(+) = e.instance_number AND b.event_id(+) = e.event_id AND e.wait_class != 'Idle'
    AND (e.total_waits - NVL(b.total_waits, 0)) > 0
),
db_time_calc AS (
    SELECT ROUND((e.value - NVL(b.value,0))/1000000, 2) AS db_time_sec
    FROM dba_hist_sys_time_model b, dba_hist_sys_time_model e
    WHERE b.snap_id(+) = &&base_start AND e.snap_id = &&base_end AND b.stat_name(+) = 'DB time' AND e.stat_name = 'DB time'
    AND (e.value - NVL(b.value,0)) > 0
)
SELECT we.event_name, we.time_waited_sec, ROUND(we.time_waited_sec / dt.db_time_sec * 100, 2) AS pct_db_time
FROM wait_events we, db_time_calc dt WHERE we.time_waited_sec > 0
ORDER BY we.time_waited_sec DESC FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT COMPARISON PERIOD:
PROMPT

WITH wait_events AS (
    SELECT e.event_name, (e.time_waited_micro - NVL(b.time_waited_micro, 0)) / 1000000 AS time_waited_sec
    FROM dba_hist_system_event b, dba_hist_system_event e
    WHERE b.snap_id(+) = &&comp_start AND e.snap_id = &&comp_end AND b.dbid(+) = e.dbid
    AND b.instance_number(+) = e.instance_number AND b.event_id(+) = e.event_id AND e.wait_class != 'Idle'
    AND (e.total_waits - NVL(b.total_waits, 0)) > 0
),
db_time_calc AS (
    SELECT ROUND((e.value - NVL(b.value,0))/1000000, 2) AS db_time_sec
    FROM dba_hist_sys_time_model b, dba_hist_sys_time_model e
    WHERE b.snap_id(+) = &&comp_start AND e.snap_id = &&comp_end AND b.stat_name(+) = 'DB time' AND e.stat_name = 'DB time'
    AND (e.value - NVL(b.value,0)) > 0
)
SELECT we.event_name, we.time_waited_sec, ROUND(we.time_waited_sec / dt.db_time_sec * 100, 2) AS pct_db_time
FROM wait_events we, db_time_calc dt WHERE we.time_waited_sec > 0
ORDER BY we.time_waited_sec DESC FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT DIFFERENCE ANALYSIS:
PROMPT

COLUMN base_pct FORMAT 999.99
COLUMN comp_pct FORMAT 999.99
COLUMN diff_pct FORMAT 999.99
COLUMN trend FORMAT A20

WITH base_waits AS (
    SELECT e.event_name, ROUND((e.time_waited_micro - NVL(b.time_waited_micro, 0)) / 1000000 / (SELECT (ee.value - bb.value)/1000000 FROM dba_hist_sys_time_model bb, dba_hist_sys_time_model ee WHERE bb.snap_id = &&base_start AND ee.snap_id = &&base_end AND bb.stat_name = 'DB time' AND ee.stat_name = 'DB time' AND (ee.value - bb.value) > 0) * 100, 2) AS pct_db_time
    FROM dba_hist_system_event b, dba_hist_system_event e WHERE b.snap_id(+) = &&base_start AND e.snap_id = &&base_end AND b.dbid(+) = e.dbid AND b.instance_number(+) = e.instance_number AND b.event_id(+) = e.event_id AND e.wait_class != 'Idle'
),
comp_waits AS (
    SELECT e.event_name, ROUND((e.time_waited_micro - NVL(b.time_waited_micro, 0)) / 1000000 / (SELECT (ee.value - bb.value)/1000000 FROM dba_hist_sys_time_model bb, dba_hist_sys_time_model ee WHERE bb.snap_id = &&comp_start AND ee.snap_id = &&comp_end AND bb.stat_name = 'DB time' AND ee.stat_name = 'DB time' AND (ee.value - bb.value) > 0) * 100, 2) AS pct_db_time
    FROM dba_hist_system_event b, dba_hist_system_event e WHERE b.snap_id(+) = &&comp_start AND e.snap_id = &&comp_end AND b.dbid(+) = e.dbid AND b.instance_number(+) = e.instance_number AND b.event_id(+) = e.event_id AND e.wait_class != 'Idle'
)
SELECT NVL(b.event_name, c.event_name) AS event_name, NVL(b.pct_db_time, 0) AS base_pct, NVL(c.pct_db_time, 0) AS comp_pct, ROUND(NVL(c.pct_db_time, 0) - NVL(b.pct_db_time, 0), 2) AS diff_pct,
    CASE WHEN NVL(c.pct_db_time, 0) > NVL(b.pct_db_time, 0) + 5 THEN 'WORSE' WHEN NVL(c.pct_db_time, 0) < NVL(b.pct_db_time, 0) - 5 THEN 'BETTER' ELSE 'STABLE' END AS trend
FROM base_waits b FULL OUTER JOIN comp_waits c ON b.event_name = c.event_name
WHERE NVL(b.pct_db_time, 0) BETWEEN 0 AND 100 AND NVL(c.pct_db_time, 0) BETWEEN 0 AND 100
  AND (NVL(b.pct_db_time, 0) > 1 OR NVL(c.pct_db_time, 0) > 1)
  AND ABS(NVL(c.pct_db_time, 0) - NVL(b.pct_db_time, 0)) > 0.5
ORDER BY ABS(NVL(c.pct_db_time, 0) - NVL(b.pct_db_time, 0)) DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT

-- ================================================================
-- MODULE 2: TOP SQL COMPARISON 
-- ================================================================

PROMPT ================================================================
PROMPT MODULE 2: TOP SQL STATEMENTS - COMPARISON
PROMPT ================================================================
PROMPT

PROMPT BASE PERIOD:
PROMPT

COLUMN sql_id FORMAT A15
COLUMN elapsed_time_sec FORMAT 999,999.99
COLUMN sql_text FORMAT A60 TRUNCATE

SELECT sql_id, ROUND(elapsed_time_delta / 1000000, 2) AS elapsed_time_sec, SUBSTR(sql_text, 1, 60) AS sql_text
FROM (SELECT st.sql_id, st.sql_text, ss.elapsed_time_delta FROM dba_hist_sqlstat ss, dba_hist_sqltext st WHERE ss.snap_id = &&base_end AND ss.sql_id = st.sql_id AND ss.dbid = st.dbid AND ss.elapsed_time_delta > 0)
ORDER BY elapsed_time_delta DESC FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT COMPARISON PERIOD:
PROMPT

SELECT sql_id, ROUND(elapsed_time_delta / 1000000, 2) AS elapsed_time_sec, SUBSTR(sql_text, 1, 60) AS sql_text
FROM (SELECT st.sql_id, st.sql_text, ss.elapsed_time_delta FROM dba_hist_sqlstat ss, dba_hist_sqltext st WHERE ss.snap_id = &&comp_end AND ss.sql_id = st.sql_id AND ss.dbid = st.dbid AND ss.elapsed_time_delta > 0)
ORDER BY elapsed_time_delta DESC FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT DIFFERENCE ANALYSIS:
PROMPT

COLUMN base_elapsed FORMAT 999,999.99
COLUMN comp_elapsed FORMAT 999,999.99
COLUMN diff_elapsed FORMAT 999,999.99

WITH base_sql AS (
    SELECT st.sql_id, SUBSTR(st.sql_text, 1, 50) AS sql_text, ROUND(ss.elapsed_time_delta / 1000000, 2) AS elapsed_sec
    FROM dba_hist_sqlstat ss, dba_hist_sqltext st WHERE ss.snap_id = &&base_end AND ss.sql_id = st.sql_id AND ss.dbid = st.dbid AND ss.elapsed_time_delta > 0
),
comp_sql AS (
    SELECT st.sql_id, SUBSTR(st.sql_text, 1, 50) AS sql_text, ROUND(ss.elapsed_time_delta / 1000000, 2) AS elapsed_sec
    FROM dba_hist_sqlstat ss, dba_hist_sqltext st WHERE ss.snap_id = &&comp_end AND ss.sql_id = st.sql_id AND ss.dbid = st.dbid AND ss.elapsed_time_delta > 0
)
SELECT 
    NVL(b.sql_id, c.sql_id) AS sql_id,
    CASE WHEN b.elapsed_sec IS NOT NULL THEN b.elapsed_sec ELSE NULL END AS base_elapsed,
    CASE WHEN c.elapsed_sec IS NOT NULL THEN c.elapsed_sec ELSE NULL END AS comp_elapsed,
    CASE WHEN b.elapsed_sec IS NOT NULL AND c.elapsed_sec IS NOT NULL THEN ROUND(c.elapsed_sec - b.elapsed_sec, 2) ELSE NULL END AS diff_elapsed,
    CASE 
        WHEN b.elapsed_sec IS NULL AND c.elapsed_sec IS NOT NULL THEN 'NEW'
        WHEN b.elapsed_sec IS NOT NULL AND c.elapsed_sec IS NULL THEN 'NOT RUN'
        WHEN c.elapsed_sec > b.elapsed_sec * 1.2 THEN 'SLOWER'
        WHEN c.elapsed_sec < b.elapsed_sec * 0.8 THEN 'FASTER'
        ELSE 'SIMILAR'
    END AS status,
    NVL(b.sql_text, c.sql_text) AS sql_text
FROM base_sql b
FULL OUTER JOIN comp_sql c ON b.sql_id = c.sql_id
WHERE (b.elapsed_sec IS NOT NULL OR c.elapsed_sec IS NOT NULL) AND ABS(NVL(c.elapsed_sec, 0) - NVL(b.elapsed_sec, 0)) > 1
ORDER BY ABS(NVL(c.elapsed_sec, 0) - NVL(b.elapsed_sec, 0)) DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT

-- ================================================================
-- MODULE 3: LOAD PROFILE AND CACHE RATIOS 
-- ================================================================

PROMPT ================================================================
PROMPT MODULE 3: LOAD PROFILE AND CACHE RATIOS - COMPARISON
PROMPT ================================================================
PROMPT

PROMPT BASE PERIOD - LOAD PROFILE:
PROMPT

COLUMN stat_name FORMAT A40
COLUMN per_second FORMAT 999,999.99

WITH snap_times AS (SELECT ROUND((CAST(s_end.end_interval_time AS DATE) - CAST(s_begin.begin_interval_time AS DATE)) * 86400, 2) AS elapsed_sec FROM dba_hist_snapshot s_begin, dba_hist_snapshot s_end WHERE s_begin.snap_id = &&base_start AND s_end.snap_id = &&base_end),
stats_delta AS (SELECT e.stat_name, e.value - NVL(b.value, 0) AS stat_value FROM dba_hist_sysstat b, dba_hist_sysstat e WHERE b.snap_id(+) = &&base_start AND e.snap_id = &&base_end AND b.stat_name(+) = e.stat_name AND b.instance_number(+) = e.instance_number AND b.dbid(+) = e.dbid AND e.stat_name IN ('parse count (total)', 'parse count (hard)', 'execute count', 'user commits', 'physical reads', 'physical writes', 'redo size'))
SELECT sd.stat_name, ROUND(sd.stat_value / st.elapsed_sec, 2) AS per_second FROM stats_delta sd, snap_times st ORDER BY sd.stat_name;

PROMPT
PROMPT COMPARISON PERIOD - LOAD PROFILE:
PROMPT

WITH snap_times AS (SELECT ROUND((CAST(s_end.end_interval_time AS DATE) - CAST(s_begin.begin_interval_time AS DATE)) * 86400, 2) AS elapsed_sec FROM dba_hist_snapshot s_begin, dba_hist_snapshot s_end WHERE s_begin.snap_id = &&comp_start AND s_end.snap_id = &&comp_end),
stats_delta AS (SELECT e.stat_name, e.value - NVL(b.value, 0) AS stat_value FROM dba_hist_sysstat b, dba_hist_sysstat e WHERE b.snap_id(+) = &&comp_start AND e.snap_id = &&comp_end AND b.stat_name(+) = e.stat_name AND b.instance_number(+) = e.instance_number AND b.dbid(+) = e.dbid AND e.stat_name IN ('parse count (total)', 'parse count (hard)', 'execute count', 'user commits', 'physical reads', 'physical writes', 'redo size'))
SELECT sd.stat_name, ROUND(sd.stat_value / st.elapsed_sec, 2) AS per_second FROM stats_delta sd, snap_times st ORDER BY sd.stat_name;

PROMPT
PROMPT LOAD PROFILE DIFFERENCE ANALYSIS:
PROMPT

COLUMN base_per_sec FORMAT 999,999.99
COLUMN comp_per_sec FORMAT 999,999.99
COLUMN diff_per_sec FORMAT 999,999.99

WITH base_stats AS (SELECT e.stat_name, ROUND((e.value - NVL(b.value, 0)) / ROUND((CAST(s_end.end_interval_time AS DATE) - CAST(s_begin.begin_interval_time AS DATE)) * 86400, 2), 4) AS per_second FROM dba_hist_sysstat b, dba_hist_sysstat e, dba_hist_snapshot s_begin, dba_hist_snapshot s_end WHERE b.snap_id(+) = &&base_start AND e.snap_id = &&base_end AND b.stat_name(+) = e.stat_name AND b.instance_number(+) = e.instance_number AND b.dbid(+) = e.dbid AND s_begin.snap_id = &&base_start AND s_end.snap_id = &&base_end AND e.stat_name IN ('parse count (total)', 'execute count', 'physical reads', 'physical writes', 'user commits', 'redo size')),
comp_stats AS (SELECT e.stat_name, ROUND((e.value - NVL(b.value, 0)) / ROUND((CAST(s_end.end_interval_time AS DATE) - CAST(s_begin.begin_interval_time AS DATE)) * 86400, 2), 4) AS per_second FROM dba_hist_sysstat b, dba_hist_sysstat e, dba_hist_snapshot s_begin, dba_hist_snapshot s_end WHERE b.snap_id(+) = &&comp_start AND e.snap_id = &&comp_end AND b.stat_name(+) = e.stat_name AND b.instance_number(+) = e.instance_number AND b.dbid(+) = e.dbid AND s_begin.snap_id = &&comp_start AND s_end.snap_id = &&comp_end AND e.stat_name IN ('parse count (total)', 'execute count', 'physical reads', 'physical writes', 'user commits', 'redo size'))
SELECT NVL(b.stat_name, c.stat_name) AS stat_name, NVL(b.per_second, 0) AS base_per_sec, NVL(c.per_second, 0) AS comp_per_sec, ROUND(NVL(c.per_second, 0) - NVL(b.per_second, 0), 4) AS diff_per_sec,
    CASE WHEN NVL(c.per_second, 0) > NVL(b.per_second, 0) * 1.1 THEN 'INCREASED' WHEN NVL(c.per_second, 0) < NVL(b.per_second, 0) * 0.9 THEN 'DECREASED' ELSE 'STABLE' END AS trend
FROM base_stats b FULL OUTER JOIN comp_stats c ON b.stat_name = c.stat_name
WHERE ABS(NVL(c.per_second, 0) - NVL(b.per_second, 0)) > 0.01
ORDER BY ABS(NVL(c.per_second, 0) - NVL(b.per_second, 0)) DESC;

PROMPT
PROMPT BASE PERIOD - CACHE RATIOS:
PROMPT

COLUMN ratio_name FORMAT A40
COLUMN ratio_pct FORMAT 999.99

WITH stats AS (SELECT e.stat_name, e.value - NVL(b.value, 0) AS stat_value FROM dba_hist_sysstat b, dba_hist_sysstat e WHERE b.snap_id(+) = &&base_start AND e.snap_id = &&base_end AND b.stat_name(+) = e.stat_name AND b.instance_number(+) = e.instance_number AND b.dbid(+) = e.dbid)
SELECT 'Buffer Cache Hit Ratio' AS ratio_name, ROUND((1 - ((SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'physical reads') / NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'session logical reads'), 0))) * 100, 2) AS ratio_pct FROM DUAL
UNION ALL SELECT 'Soft Parse Ratio', ROUND((1 - ((SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'parse count (hard)') / NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'parse count (total)'), 0))) * 100, 2) FROM DUAL;

PROMPT
PROMPT COMPARISON PERIOD - CACHE RATIOS:
PROMPT

WITH stats AS (SELECT e.stat_name, e.value - NVL(b.value, 0) AS stat_value FROM dba_hist_sysstat b, dba_hist_sysstat e WHERE b.snap_id(+) = &&comp_start AND e.snap_id = &&comp_end AND b.stat_name(+) = e.stat_name AND b.instance_number(+) = e.instance_number AND b.dbid(+) = e.dbid)
SELECT 'Buffer Cache Hit Ratio' AS ratio_name, ROUND((1 - ((SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'physical reads') / NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'session logical reads'), 0))) * 100, 2) AS ratio_pct FROM DUAL
UNION ALL SELECT 'Soft Parse Ratio', ROUND((1 - ((SELECT NVL(stat_value, 0) FROM stats WHERE stat_name = 'parse count (hard)') / NULLIF((SELECT NVL(stat_value, 1) FROM stats WHERE stat_name = 'parse count (total)'), 0))) * 100, 2) FROM DUAL;

PROMPT
PROMPT CACHE RATIOS DIFFERENCE ANALYSIS:
PROMPT

COLUMN base_ratio FORMAT 999.99
COLUMN comp_ratio FORMAT 999.99
COLUMN diff_ratio FORMAT 999.99

WITH base_ratios AS (
    SELECT 'Buffer Cache Hit Ratio' AS ratio_name,
        ROUND((1 - (
            (SELECT ee.value - NVL(bb.value, 0) FROM dba_hist_sysstat bb, dba_hist_sysstat ee WHERE bb.snap_id(+) = &&base_start AND ee.snap_id = &&base_end AND bb.stat_name(+) = 'physical reads' AND ee.stat_name = 'physical reads' AND bb.instance_number(+) = ee.instance_number AND bb.dbid(+) = ee.dbid FETCH FIRST 1 ROWS ONLY) /
            NULLIF((SELECT ee.value - NVL(bb.value, 0) FROM dba_hist_sysstat bb, dba_hist_sysstat ee WHERE bb.snap_id(+) = &&base_start AND ee.snap_id = &&base_end AND bb.stat_name(+) = 'session logical reads' AND ee.stat_name = 'session logical reads' AND bb.instance_number(+) = ee.instance_number AND bb.dbid(+) = ee.dbid FETCH FIRST 1 ROWS ONLY), 0)
        )) * 100, 2) AS ratio_value
    FROM DUAL
    UNION ALL
    SELECT 'Soft Parse Ratio',
        ROUND((1 - (
            (SELECT ee.value - NVL(bb.value, 0) FROM dba_hist_sysstat bb, dba_hist_sysstat ee WHERE bb.snap_id(+) = &&base_start AND ee.snap_id = &&base_end AND bb.stat_name(+) = 'parse count (hard)' AND ee.stat_name = 'parse count (hard)' AND bb.instance_number(+) = ee.instance_number AND bb.dbid(+) = ee.dbid FETCH FIRST 1 ROWS ONLY) /
            NULLIF((SELECT ee.value - NVL(bb.value, 0) FROM dba_hist_sysstat bb, dba_hist_sysstat ee WHERE bb.snap_id(+) = &&base_start AND ee.snap_id = &&base_end AND bb.stat_name(+) = 'parse count (total)' AND ee.stat_name = 'parse count (total)' AND bb.instance_number(+) = ee.instance_number AND bb.dbid(+) = ee.dbid FETCH FIRST 1 ROWS ONLY), 0)
        )) * 100, 2)
    FROM DUAL
),
comp_ratios AS (
    SELECT 'Buffer Cache Hit Ratio' AS ratio_name,
        ROUND((1 - (
            (SELECT ee.value - NVL(bb.value, 0) FROM dba_hist_sysstat bb, dba_hist_sysstat ee WHERE bb.snap_id(+) = &&comp_start AND ee.snap_id = &&comp_end AND bb.stat_name(+) = 'physical reads' AND ee.stat_name = 'physical reads' AND bb.instance_number(+) = ee.instance_number AND bb.dbid(+) = ee.dbid FETCH FIRST 1 ROWS ONLY) /
            NULLIF((SELECT ee.value - NVL(bb.value, 0) FROM dba_hist_sysstat bb, dba_hist_sysstat ee WHERE bb.snap_id(+) = &&comp_start AND ee.snap_id = &&comp_end AND bb.stat_name(+) = 'session logical reads' AND ee.stat_name = 'session logical reads' AND bb.instance_number(+) = ee.instance_number AND bb.dbid(+) = ee.dbid FETCH FIRST 1 ROWS ONLY), 0)
        )) * 100, 2) AS ratio_value
    FROM DUAL
    UNION ALL
    SELECT 'Soft Parse Ratio',
        ROUND((1 - (
            (SELECT ee.value - NVL(bb.value, 0) FROM dba_hist_sysstat bb, dba_hist_sysstat ee WHERE bb.snap_id(+) = &&comp_start AND ee.snap_id = &&comp_end AND bb.stat_name(+) = 'parse count (hard)' AND ee.stat_name = 'parse count (hard)' AND bb.instance_number(+) = ee.instance_number AND bb.dbid(+) = ee.dbid FETCH FIRST 1 ROWS ONLY) /
            NULLIF((SELECT ee.value - NVL(bb.value, 0) FROM dba_hist_sysstat bb, dba_hist_sysstat ee WHERE bb.snap_id(+) = &&comp_start AND ee.snap_id = &&comp_end AND bb.stat_name(+) = 'parse count (total)' AND ee.stat_name = 'parse count (total)' AND bb.instance_number(+) = ee.instance_number AND bb.dbid(+) = ee.dbid FETCH FIRST 1 ROWS ONLY), 0)
        )) * 100, 2)
    FROM DUAL
)
SELECT b.ratio_name, b.ratio_value AS base_ratio, c.ratio_value AS comp_ratio, ROUND(c.ratio_value - b.ratio_value, 2) AS diff_ratio,
    CASE WHEN c.ratio_value > b.ratio_value + 1 THEN 'IMPROVED' WHEN c.ratio_value < b.ratio_value - 1 THEN 'DEGRADED' ELSE 'STABLE' END AS trend
FROM base_ratios b, comp_ratios c WHERE b.ratio_name = c.ratio_name AND ABS(c.ratio_value - b.ratio_value) > &&cache_diff_threshold;

PROMPT

-- ================================================================
-- MODULE 4: KEY DIAGNOSTIC RATIOS (ISSUE DETECTION - CONFIGURABLE)
-- ================================================================

PROMPT ================================================================
PROMPT MODULE 4: KEY DIAGNOSTIC RATIOS (Issue Detection)
PROMPT ================================================================
PROMPT
PROMPT BASE PERIOD - DIAGNOSTIC METRICS:
PROMPT

COLUMN diag_metric FORMAT A40
COLUMN base_metric FORMAT 999,999.99
COLUMN issue FORMAT A30

WITH base_stats AS (
    SELECT e.stat_name, e.value - NVL(b.value, 0) AS stat_value
    FROM dba_hist_sysstat b, dba_hist_sysstat e 
    WHERE b.snap_id(+) = &&base_start AND e.snap_id = &&base_end 
    AND b.stat_name(+) = e.stat_name AND b.instance_number(+) = e.instance_number AND b.dbid(+) = e.dbid
)
SELECT 
    'Hard Parse %' AS diag_metric,
    ROUND(((SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'parse count (hard)') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'parse count (total)'), 0)) * 100, 2) AS base_metric,
    CASE WHEN ((SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'parse count (hard)') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'parse count (total)'), 0)) * 100 > &&hard_parse_threshold
         THEN 'HIGH - Cursor Issue' ELSE 'Normal' END AS issue
FROM DUAL
UNION ALL
SELECT
    'Redo per Commit (KB)',
    ROUND((SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'redo size') / 
           NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'user commits'), 0) / 1024, 2),
    CASE WHEN (SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'redo size') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'user commits'), 0) / 1024 > &&redo_per_txn_threshold
         THEN 'HIGH - Large Txns' ELSE 'Normal' END
FROM DUAL
UNION ALL
SELECT
    'Reads per Commit',
    ROUND((SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'physical reads') / 
           NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'user commits'), 0), 2),
    CASE WHEN (SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'physical reads') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'user commits'), 0) > &&reads_per_txn_threshold
         THEN 'HIGH - Cache Miss' ELSE 'Normal' END
FROM DUAL
UNION ALL
SELECT
    'Writes per Commit (KB)',
    ROUND((SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'physical writes') / 
           NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'user commits'), 0) * 8 / 1024, 2),
    CASE WHEN (SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'physical writes') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'user commits'), 0) * 8 / 1024 > &&writes_per_txn_threshold
         THEN 'HIGH - I/O Writes' ELSE 'Normal' END
FROM DUAL
UNION ALL
SELECT
    'Execute/Parse Ratio',
    ROUND((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'execute count') /
           NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'parse count (total)'), 0), 2),
    CASE WHEN (SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'execute count') /
            NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'parse count (total)'), 0) < &&exec_parse_ratio_threshold
         THEN 'LOW - Poor reuse' ELSE 'Normal' END
FROM DUAL
UNION ALL
SELECT
    'CPU per Commit (ms)',
    ROUND((SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'CPU used by this session') / 
           NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'user commits'), 0) / 1000, 2),
    CASE WHEN (SELECT NVL(stat_value, 0) FROM base_stats WHERE stat_name = 'CPU used by this session') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM base_stats WHERE stat_name = 'user commits'), 0) / 1000 > &&cpu_per_txn_threshold
         THEN 'HIGH - CPU Intensive' ELSE 'Normal' END
FROM DUAL;

PROMPT
PROMPT COMPARISON PERIOD - DIAGNOSTIC METRICS:
PROMPT

WITH comp_stats AS (
    SELECT e.stat_name, e.value - NVL(b.value, 0) AS stat_value
    FROM dba_hist_sysstat b, dba_hist_sysstat e 
    WHERE b.snap_id(+) = &&comp_start AND e.snap_id = &&comp_end 
    AND b.stat_name(+) = e.stat_name AND b.instance_number(+) = e.instance_number AND b.dbid(+) = e.dbid
)
SELECT 
    'Hard Parse %' AS diag_metric,
    ROUND(((SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'parse count (hard)') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'parse count (total)'), 0)) * 100, 2) AS base_metric,
    CASE WHEN ((SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'parse count (hard)') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'parse count (total)'), 0)) * 100 > &&hard_parse_threshold
         THEN 'HIGH - Cursor Issue' ELSE 'Normal' END AS issue
FROM DUAL
UNION ALL
SELECT
    'Redo per Commit (KB)',
    ROUND((SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'redo size') / 
           NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'user commits'), 0) / 1024, 2),
    CASE WHEN (SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'redo size') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'user commits'), 0) / 1024 > &&redo_per_txn_threshold
         THEN 'HIGH - Large Txns' ELSE 'Normal' END
FROM DUAL
UNION ALL
SELECT
    'Reads per Commit',
    ROUND((SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'physical reads') / 
           NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'user commits'), 0), 2),
    CASE WHEN (SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'physical reads') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'user commits'), 0) > &&reads_per_txn_threshold
         THEN 'HIGH - Cache Miss' ELSE 'Normal' END
FROM DUAL
UNION ALL
SELECT
    'Writes per Commit (KB)',
    ROUND((SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'physical writes') / 
           NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'user commits'), 0) * 8 / 1024, 2),
    CASE WHEN (SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'physical writes') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'user commits'), 0) * 8 / 1024 > &&writes_per_txn_threshold
         THEN 'HIGH - I/O Writes' ELSE 'Normal' END
FROM DUAL
UNION ALL
SELECT
    'Execute/Parse Ratio',
    ROUND((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'execute count') /
           NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'parse count (total)'), 0), 2),
    CASE WHEN (SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'execute count') /
            NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'parse count (total)'), 0) < &&exec_parse_ratio_threshold
         THEN 'LOW - Poor reuse' ELSE 'Normal' END
FROM DUAL
UNION ALL
SELECT
    'CPU per Commit (ms)',
    ROUND((SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'CPU used by this session') / 
           NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'user commits'), 0) / 1000, 2),
    CASE WHEN (SELECT NVL(stat_value, 0) FROM comp_stats WHERE stat_name = 'CPU used by this session') / 
            NULLIF((SELECT NVL(stat_value, 1) FROM comp_stats WHERE stat_name = 'user commits'), 0) / 1000 > &&cpu_per_txn_threshold
         THEN 'HIGH - CPU Intensive' ELSE 'Normal' END
FROM DUAL;

PROMPT

PROMPT ================================================================
PROMPT                    ANALYSIS COMPLETE
PROMPT ================================================================
PROMPT
PROMPT Base Period:        Snapshots &&base_start to &&base_end
PROMPT Comparison Period:  Snapshots &&comp_start to &&comp_end
PROMPT
PROMPT ================================================================

SET FEEDBACK ON
SET VERIFY ON

EXIT SUCCESS
