SET PAGESIZE 100
SET LINESIZE 500
SET FEEDBACK ON

COLUMN container FORMAT A25
COLUMN tbs FORMAT A20
COLUMN dfiles FORMAT 9999
COLUMN alloc_mb FORMAT 99999
COLUMN used_mb FORMAT 99999
COLUMN df_left FORMAT 9999
COLUMN growth_daily_mb FORMAT 9999.9
COLUMN growth_weekly_mb FORMAT 99999.9
COLUMN remaining_mb FORMAT 99999999
COLUMN delta_trend FORMAT A12
COLUMN df_status FORMAT A10
COLUMN sust_weeks FORMAT 99999999
COLUMN sust_years FORMAT 999999.9

PROMPT 
PROMPT ========================================================
PROMPT Tablespace Sustainability Report - CDB Wide
PROMPT Datafile Limit: 1023 | 32GB/File | Output in MB
PROMPT ========================================================

WITH ts_capacity AS (
  SELECT 
    ctf.CON_ID,
    NVL(pdb.NAME,'CDB$ROOT') container,
    ctf.TABLESPACE_NAME tbs,
    COUNT(*) dfiles,
    ROUND(SUM(ctf.BYTES)/1024/1024,0) alloc_mb,
    ROUND(SUM(NVL(ctf.USER_BYTES,0))/1024/1024,0) used_mb,
    (1023-COUNT(*)) df_left,
    ROUND(100*(SUM(NVL(ctf.USER_BYTES,0))/NULLIF(SUM(ctf.BYTES),0)),1) pct_used
  FROM CDB_DATA_FILES ctf
  LEFT JOIN V$PDBS pdb ON ctf.CON_ID = pdb.CON_ID
  WHERE ctf.TABLESPACE_NAME NOT LIKE '%UNDO%' 
    AND ctf.TABLESPACE_NAME NOT LIKE '%TEMP%'
  GROUP BY ctf.CON_ID, ctf.TABLESPACE_NAME, pdb.NAME
  HAVING SUM(ctf.BYTES) > 0
),
-- ACTUAL 4-WEEK Monday-Sunday growth from AWR (Diagnostics Pack required)
weekly_growth AS (
  SELECT 
    con_id,
    tablespace_name,
    TRUNC(end_interval_time, 'IW') week_start,  -- Monday of week
    SUM(bytes)/1024/1024 end_mb,
    LAG(SUM(bytes)/1024/1024) OVER (
      PARTITION BY con_id, tablespace_name 
      ORDER BY TRUNC(end_interval_time, 'IW')
    ) start_mb,
    -- Daily avg per week (Mon-Sun)
    (SUM(bytes) - LAG(SUM(bytes)) OVER (
      PARTITION BY con_id, tablespace_name 
      ORDER BY TRUNC(end_interval_time, 'IW')
    )) / 1024 / 1024 / 7 daily_avg_mb
  FROM CDB_HIST_SEG_STAT
  WHERE end_interval_time >= TRUNC(SYSDATE, 'IW') - 28  -- Last 4 weeks
    AND tablespace_name NOT LIKE '%UNDO%'
    AND tablespace_name NOT LIKE '%TEMP%'
  GROUP BY con_id, tablespace_name, TRUNC(end_interval_time, 'IW')
),
growth_proxy AS (
  -- 4-week average daily growth (Mon-Sun weeks)
  SELECT 
    con_id, tablespace_name,
    NVL(AVG(daily_avg_mb), 0.1) daily_growth_mb
  FROM weekly_growth 
  WHERE week_start >= TRUNC(SYSDATE, 'IW') - 21  -- Last 4 Mondays
  GROUP BY con_id, tablespace_name
),
future_capacity AS (
  SELECT 
    tc.*,
    ROUND((tc.df_left * 32768),0) AS remaining_mb,
    NVL(gp.daily_growth_mb, 0.1) daily_growth_mb
  FROM ts_capacity tc
  LEFT JOIN growth_proxy gp ON tc.CON_ID = gp.CON_ID AND tc.tbs = gp.tablespace_name
),
df_analysis AS (
  SELECT 
    fc.*,
    ROUND(fc.daily_growth_mb * 7,1) AS growth_weekly_mb,
    CASE 
      WHEN fc.daily_growth_mb > 10 THEN 'GROWING'
      WHEN fc.daily_growth_mb > 1 THEN 'STABLE'
      ELSE 'IDLE'
    END AS delta_trend,
    CASE 
      WHEN fc.df_left < 123 THEN 'CRITICAL'
      WHEN fc.df_left < 323 THEN 'WARNING'     
      ELSE 'OK'
    END AS df_status
  FROM future_capacity fc
)
SELECT 
  da.container||'/'||da.tbs AS container,
  da.dfiles,
  da.alloc_mb,
  da.used_mb,
  da.df_left,
  ROUND(da.daily_growth_mb,1) "GROWTH_DAILY(MB)",
  da.growth_weekly_mb "GROWTH_WEEKLY(MB)",
  da.remaining_mb,
  da.delta_trend,
  da.df_status,
  ROUND(da.remaining_mb / (da.daily_growth_mb * 7),0) sust_weeks,
  ROUND(da.remaining_mb / (da.daily_growth_mb * 52),1) sust_years
FROM df_analysis da
ORDER BY sust_weeks ASC NULLS LAST, da.pct_used DESC;
