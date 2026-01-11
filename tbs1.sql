SET PAGESIZE 100
SET LINESIZE 500
SET FEEDBACK ON

COLUMN container FORMAT A25
COLUMN tbs FORMAT A20
COLUMN dfiles FORMAT 9999
COLUMN alloc_mb FORMAT 99999
COLUMN used_mb FORMAT 99999
COLUMN df_left FORMAT 9999
COLUMN autoextend_mb FORMAT 999999
COLUMN growth_daily_mb FORMAT 9999.9
COLUMN remaining_mb FORMAT 99999999
COLUMN delta_trend FORMAT A12
COLUMN df_status FORMAT A10
COLUMN sust_weeks FORMAT 99999999
COLUMN sust_years FORMAT 99999999999.9

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
    ROUND(SUM(
      CASE 
        WHEN ctf.AUTOEXTENSIBLE = 'YES' 
        THEN GREATEST(0, NVL(ctf.MAXBYTES,ctf.BYTES) - ctf.BYTES)
        ELSE 0 
      END
    )/1024/1024,0) autoextend_mb,
    ROUND(100*(SUM(NVL(ctf.USER_BYTES,0))/NULLIF(SUM(ctf.BYTES),0)),1) pct_used
  FROM CDB_DATA_FILES ctf
  LEFT JOIN V$PDBS pdb ON ctf.CON_ID = pdb.CON_ID
  GROUP BY ctf.CON_ID, ctf.TABLESPACE_NAME, pdb.NAME
  HAVING SUM(ctf.BYTES) > 0
),
growth_proxy AS (
  SELECT 
    CON_ID,
    tablespace_name,
    NVL(GREATEST(0,(SUM(bytes)/1024/1024)/30), 0) daily_growth_mb
  FROM CDB_SEGMENTS
  GROUP BY CON_ID, tablespace_name
),
future_capacity AS (
  SELECT 
    tc.*,
    ROUND((tc.df_left * 32768 + tc.autoextend_mb),0) AS remaining_mb,
    NVL(gp.daily_growth_mb, 0) daily_growth_mb
  FROM ts_capacity tc
  LEFT JOIN growth_proxy gp ON tc.CON_ID = gp.CON_ID AND tc.tbs = gp.tablespace_name
),
df_analysis AS (
  SELECT 
    fc.*,
    CASE 
      WHEN fc.daily_growth_mb > 100 THEN 'INCREASING'
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
  da.autoextend_mb,
  ROUND(da.daily_growth_mb,1) "GROWTH_DAILY(MB)",
  da.remaining_mb,
  da.delta_trend,
  da.df_status,
  NULLIF(ROUND(da.remaining_mb / NULLIF(da.daily_growth_mb * 7,0),0),999999999) sust_weeks,
  NULLIF(ROUND(da.remaining_mb / NULLIF(da.daily_growth_mb * 52,0),1),999999.9) sust_years
FROM df_analysis da
ORDER BY sust_weeks ASC NULLS LAST, da.pct_used DESC;
