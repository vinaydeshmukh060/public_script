# AWR PARSER v3.0 - QUICK START & DEPLOYMENT GUIDE

## 📦 What You're Getting

Three production-ready shell scripts for complete AWR analysis:

```
awr_parser_v3.sh        - Main AWR parser (extracts 110+ metrics)
awr_html_gen.sh         - HTML dashboard generator
awr_config.sh           - Configuration file (customize behavior)
```

**No external packages needed** - pure bash with standard Unix tools only.

---

## 🚀 INSTALLATION (5 minutes)

### Step 1: Extract Files

```bash
# Create installation directory
mkdir -p /opt/oracle/awr_parser_v3
cd /opt/oracle/awr_parser_v3

# Copy the three scripts here (you have them in files downloaded)
cp awr_parser_v3.sh .
cp awr_html_gen.sh .
cp awr_config.sh .

# Make executable
chmod +x *.sh
```

### Step 2: Configure Paths

Edit `awr_config.sh` to set your environment:

```bash
# For a DBA in Devanahalli, Karnataka
cat > awr_config.sh <<'EOF'
export AWR_INPUT_PATH="/mnt/oracle/awr_reports"
export AWR_OUTPUT_PATH="/data/reports"
export GENERATE_HTML=1
export VERBOSE=1
export ENABLE_ALERTS=1
export ENABLE_RAC_ANALYSIS=1
export ENABLE_19C_ANALYSIS=1
EOF
```

### Step 3: Test Installation

```bash
# Check syntax (no errors = good to go)
bash -n awr_parser_v3.sh
bash -n awr_html_gen.sh
bash -n awr_config.sh

# Print help
./awr_parser_v3.sh --help

# Expected output:
# Usage: awr_parser_v3.sh [OPTIONS] [AWR_FILES]
# ✓ Installation successful
```

### Step 4: Create Symbolic Link (Optional)

```bash
sudo ln -s /opt/oracle/awr_parser_v3/awr_parser_v3.sh /usr/local/bin/awr_parser
sudo ln -s /opt/oracle/awr_parser_v3/awr_html_gen.sh /usr/local/bin/awr_html_gen

# Now you can run from anywhere:
awr_parser --help
```

---

## ⚡ QUICK START USAGE

### Basic Usage (Most Common)

```bash
# 1. Set your paths
cd /opt/oracle/awr_parser_v3
source awr_config.sh

# 2. Copy your AWR reports to input directory
mkdir -p /mnt/oracle/awr_reports
cp /home/oracle/awr/*.txt /mnt/oracle/awr_reports/

# 3. Run parser
./awr_parser_v3.sh -i /mnt/oracle/awr_reports -o /data/reports -v

# Output:
# Info  : Processing: awr_db_5678_5679.txt
# Info  : Processing: awr_db_5679_5680.txt
# ...
# ✓ Completed: PROD01 (v19c)
# CSV file: /data/reports/awr_analysis_20260125_112034.csv
```

### Example 1: Production Database Analysis

```bash
#!/bin/bash
# analyze_prod.sh

source /opt/oracle/awr_parser_v3/awr_config.sh

export AWR_INPUT_PATH="/u01/oracle/admin/PROD/awr"
export AWR_OUTPUT_PATH="/reports/prod"
export VERBOSE=1

/opt/oracle/awr_parser_v3/awr_parser_v3.sh \
    -i "$AWR_INPUT_PATH" \
    -o "$AWR_OUTPUT_PATH" \
    -v

# Generate HTML report
/opt/oracle/awr_parser_v3/awr_html_gen.sh \
    "$AWR_OUTPUT_PATH/awr_analysis_*.csv" \
    "$AWR_OUTPUT_PATH/index.html"

echo "Reports ready at: $AWR_OUTPUT_PATH"
```

### Example 2: RAC Cluster Analysis

```bash
#!/bin/bash
# analyze_rac.sh

source /opt/oracle/awr_parser_v3/awr_config.sh

export ENABLE_RAC_ANALYSIS=1
export EXPECTED_INSTANCES=3
export AWR_INPUT_PATH="/mnt/shared/awr/RAC_CLUSTER"
export AWR_OUTPUT_PATH="/reports/rac_analysis"
export VERBOSE=1

# Process all RAC instances
for instance in 1 2 3; do
    echo "Processing PROD0${instance}..."
    find "$AWR_INPUT_PATH" -name "*PROD0${instance}*" -type f | \
    xargs -I {} /opt/oracle/awr_parser_v3/awr_parser_v3.sh \
        -i "$(dirname {})" \
        -o "$AWR_OUTPUT_PATH"
done

echo "✓ RAC cluster analysis complete"
```

### Example 3: Silent Mode (Cron Job)

```bash
#!/bin/bash
# /opt/oracle/bin/daily_awr_analysis.sh

source /opt/oracle/awr_parser_v3/awr_config.sh

# Timestamp for backup
BACKUP_DATE=$(date +%Y%m%d)
REPORT_DIR="/reports/daily/${BACKUP_DATE}"

# Create output directory
mkdir -p "$REPORT_DIR"

# Run parser silently
/opt/oracle/awr_parser_v3/awr_parser_v3.sh \
    -i "$AWR_INPUT_PATH" \
    -o "$REPORT_DIR" \
    -s  # Silent mode

# Check exit code
if [[ $? -eq 0 ]]; then
    # Generate HTML
    /opt/oracle/awr_parser_v3/awr_html_gen.sh \
        "$REPORT_DIR/"*.csv \
        "$REPORT_DIR/index.html"
    
    # Email report
    mail -s "Daily AWR Analysis - $BACKUP_DATE" \
        dba-team@company.com < "$REPORT_DIR/index.html"
fi
```

---

## 📊 OUTPUT FILES

### CSV Output

Location: `/data/reports/awr_analysis_20260125_112034.csv`

Contains 110+ columns:
- System info (DB name, version, instance, cluster)
- Performance metrics (AAS, I/O, latency)
- Wait events (top 10, specific I/O events)
- Cache efficiency (buffer hit, sort ratio)
- Call statistics (parses, executes, transactions)
- OS statistics
- RAC metrics (if applicable)
- Exadata metrics (if applicable)

**Import into Excel:**
1. Open Excel
2. Data → From Text/CSV
3. Select the CSV file
4. Click Import
5. Create pivot tables and charts

### HTML Dashboard

Location: `/data/reports/index.html`

Interactive dashboard with:
- **System Overview** - DB, instance, version info
- **Performance Scorecards** - Color-coded health status
- **Top Events Analysis** - Top 5-10 wait events
- **I/O Analysis** - IOPS, latency, throughput
- **RAC Metrics** - GC efficiency, interconnect performance
- **Active Alerts** - Threshold-based warnings
- **Recommendations** - 19c best practices
- **Responsive Design** - Works on mobile/tablet

**View:** Open in any web browser
```bash
open /data/reports/index.html  # macOS
xdg-open /data/reports/index.html  # Linux
```

---

## ⚙️ COMMON CONFIGURATIONS

### For Oracle 19c Databases

```bash
# awr_config.sh settings
export ENABLE_19C_ANALYSIS=1
export ENABLE_RAC_ANALYSIS=1
export ENABLE_ALERTS=1
export HEALTHY_BUFFER_HIT=95
export HEALTHY_LATENCY_MS=5
```

### For RAC Environments

```bash
export ENABLE_RAC_ANALYSIS=1
export RAC_CLUSTER_NAME="PROD"
export EXPECTED_INSTANCES=4
export HEALTHY_GC_EFFICIENCY=90
export WARNING_INTERCONNECT_LATENCY_MS=15
```

### For Exadata

```bash
export ENABLE_EXADATA_ANALYSIS=1
export HEALTHY_SMART_SCAN_EFFICIENCY=75
export HEALTHY_CELL_CACHE_HIT=85
```

### For Autonomous Database

```bash
export ENABLE_CLOUD_ANALYSIS=1
export ENABLE_AUTONOMOUS_DB=1
export ENABLE_ALERTS=1
```

---

## 🔧 ADVANCED OPTIONS

### Parallel Processing (Multiple Databases)

```bash
#!/bin/bash
# process_all_dbs.sh

DATABASES=("PROD01" "DEV02" "UAT03" "TEST04")
OUTPUT_BASE="/reports"

for db in "${DATABASES[@]}"; do
    (
        echo "Processing $db..."
        ./awr_parser_v3.sh \
            -i "/mnt/awr/${db}" \
            -o "${OUTPUT_BASE}/${db}" \
            -s
    ) &
    
    # Limit concurrent jobs
    if [[ $(jobs -r -p | wc -l) -ge 3 ]]; then
        wait -n
    fi
done

wait
echo "All databases processed"
```

### Email Reports Automatically

```bash
#!/bin/bash
# email_reports.sh

REPORT_PATH="/reports/html/index.html"
TO_EMAIL="dba-team@company.com"
SUBJECT="Daily AWR Analysis - $(date +%Y-%m-%d)"

# Use 'mutt' or 'mail' to send
mail -s "$SUBJECT" \
    -a "Content-Type: text/html" \
    "$TO_EMAIL" < "$REPORT_PATH"
```

### Archive Old Reports

```bash
#!/bin/bash
# archive_old_reports.sh

REPORTS_DIR="/reports"
ARCHIVE_DIR="/backup/awr_archive"
DAYS_TO_KEEP=30

# Find and compress reports older than N days
find "$REPORTS_DIR" -name "*.csv" -mtime +$DAYS_TO_KEEP | \
    xargs -I {} tar -czf "$ARCHIVE_DIR/{}.tar.gz" {} && \
    rm {}

echo "Archive complete - kept last $DAYS_TO_KEEP days"
```

---

## 🎯 CRON JOB SETUP

### Daily Analysis at 2 AM

```bash
# crontab -e
0 2 * * * /opt/oracle/bin/daily_awr_analysis.sh

# With logging
0 2 * * * /opt/oracle/bin/daily_awr_analysis.sh >> /var/log/awr_parser.log 2>&1
```

### Weekly Detailed Report (Sundays)

```bash
0 3 * * 0 /opt/oracle/bin/weekly_awr_report.sh
```

### Monthly Summary (1st of month)

```bash
0 1 1 * * /opt/oracle/bin/monthly_awr_summary.sh
```

---

## ✅ VALIDATION & TESTING

### Test AWR File Processing

```bash
# Create sample test file
cat > /tmp/test_awr.txt <<'EOF'
DB Name          TESTDB
Instance Number  1
Instance Name    TESTDB_1
Database Version 19.0.0.0.0
Begin Snap: 12345
End Snap: 12346
DB Time: 60
Elapsed: 5
Buffer Hit Ratio: 95
EOF

# Run parser on test file
./awr_parser_v3.sh -i /tmp -o /tmp/output -v

# Check output
ls -la /tmp/output/
cat /tmp/output/awr_analysis_*.csv
```

### Verify HTML Generation

```bash
# Generate test HTML
./awr_html_gen.sh /tmp/output/awr_analysis_*.csv /tmp/test_report.html

# Check file size (should be >50KB)
ls -lh /tmp/test_report.html

# Open in browser
open /tmp/test_report.html  # macOS
# or
firefox /tmp/test_report.html  # Linux
```

### Check Exit Codes

```bash
# Success = 0
./awr_parser_v3.sh -i /mnt/awr -o /tmp/out
echo "Exit code: $?"  # Should be 0

# Partial success = 1 (some errors)
# Failure = 2 (no files processed)
```

---

## 🐛 TROUBLESHOOTING

### Issue: "No AWR files found"

```bash
# Check file naming
ls -la /mnt/awr/

# AWR files must match:
# awr*.txt or *awrrpt*.txt

# If files have different naming, rename:
for f in *.txt; do 
    mv "$f" "awr_${f}"
done
```

### Issue: Permission Denied

```bash
# Make scripts executable
chmod +x awr_parser_v3.sh awr_html_gen.sh

# Check directory permissions
chmod 755 /opt/oracle/awr_parser_v3/
```

### Issue: Output Directory Creation Fails

```bash
# Ensure parent directory exists
mkdir -p /data/reports

# Check permissions
ls -ld /data/
# Should show: drwxr-xr-x (755)

# Fix permissions if needed
chmod 755 /data
```

### Issue: CSV File Empty

```bash
# Run in debug mode
./awr_parser_v3.sh -i /mnt/awr -o /tmp/out -x

# Check for parsing errors
grep "Error" /tmp/out/awr_analysis_*.csv

# Verify AWR file format
head -20 /mnt/awr/awr_sample.txt
```

### Enable Debug Mode

```bash
# Run with verbose + debug
./awr_parser_v3.sh \
    -i /mnt/awr \
    -o /tmp/out \
    -v  # Verbose
    -x  # Debug
    
# Check for detailed debug output
```

---

## 📈 PERFORMANCE TIPS

### For Large Reports

```bash
# Use silent mode (faster)
./awr_parser_v3.sh \
    -i /mnt/large_awr \
    -o /reports \
    -s  # Silent mode - skips verbose output
```

### For Multiple Files

```bash
# Process in parallel (up to 3 at a time)
ls /mnt/awr/*.txt | \
    xargs -P 3 -I {} \
    ./awr_parser_v3.sh -i {} -o /reports -s
```

### Monitor Processing

```bash
# Watch progress
watch -n 1 'ls -l /reports/awr_analysis_*.csv'

# Or use tail
tail -f /reports/awr_analysis_*.csv
```

---

## 📞 SUPPORT & DOCUMENTATION

### What's Included

✅ **awr_parser_v3.sh** - 2500+ lines, 12 functions, full AWR parsing
✅ **awr_html_gen.sh** - 800+ lines, 6 functions, dashboard generation
✅ **awr_config.sh** - 300+ lines, 50+ configuration options
✅ **This Quick Start Guide** - Complete usage documentation

### Key Metrics Extracted (110+)

**System & Timing:**
- DB name, version, instance, cluster type
- Begin/end snapshots with timestamps
- Elapsed time, DB time, AAS
- Database busy flag

**I/O Performance:**
- Read/Write IOPS (ops per second)
- Throughput (MiB/sec) for reads, writes, redo
- Latency metrics (average wait time)

**Wait Events:**
- Top 10 foreground events
- Top 5 I/O events (sequential, scattered, direct path, log)
- All wait classes (User I/O, CPU, Commit, Network, etc.)

**Call Statistics:**
- User calls, parses, hard parses
- Logons, executes, transactions
- Parse rates and ratios

**Cache Efficiency:**
- Buffer hit ratio (%)
- In-memory sort ratio (%)
- Log switches (per hour)

**RAC Metrics:**
- Global Cache (GC) efficiency
- Interconnect latency
- CR/CW block distribution

**System OS Stats:**
- CPU busy, idle, iowait time
- OS resource contention

**Feature Detection:**
- Data Guard active (Y/N)
- Exadata platform (Y/N)
- RAC cluster (Y/N)

---

## 🎓 LEARNING PATH

**Day 1:** Basic usage
```bash
# Install, configure, run on single database
./awr_parser_v3.sh -i /mnt/awr -o /reports -v
```

**Day 2:** Explore output
```bash
# Review CSV in Excel, examine metrics
open /reports/awr_analysis_*.csv

# View HTML dashboard
open /reports/index.html
```

**Day 3:** Customize configuration
```bash
# Edit awr_config.sh for your environment
# Adjust thresholds, enable/disable features
vim awr_config.sh
```

**Day 4:** Automate with cron
```bash
# Set up daily analysis schedule
crontab -e
```

**Day 5:** RAC & Advanced
```bash
# Enable RAC analysis, multiple databases
export ENABLE_RAC_ANALYSIS=1
./analyze_rac.sh
```

---

## 📝 EXAMPLE OUTPUT

### CSV Columns (First 20 of 110+)

```
Filename,Database Name,Instance Number,Instance Name,Database Version,Cluster,Hostname,Host OS,Num CPUs,Server Memory GB,DB Block Size,Begin Snap,Begin Time,End Snap,End Time,Elapsed Time mins,DB Time mins,Average Active Sessions,Busy Flag,Logical Reads sec,...
```

### HTML Dashboard Sections

```
✓ System Overview       - DB/Instance/Version/Cluster
✓ Performance Scorecards - AAS, Buffer Hit, Parse Success
✓ I/O Analysis         - IOPS, Throughput, Latency
✓ Top 5 Wait Events    - Event name, waits, latency, % DBTime
✓ RAC Cluster Metrics  - GC efficiency, interconnect, instances
✓ Active Alerts        - Performance threshold violations
✓ Recommendations      - 19c best practices
✓ Report Info          - Generated date, version, source
```

---

## ✨ KEY FEATURES

✅ **No Package Dependencies** - Pure bash with standard Unix tools
✅ **Supports 10g-23c** - All modern Oracle versions
✅ **RAC-Aware** - GC metrics and cluster analysis
✅ **19c Best Practices** - Adaptive query optimization, In-Memory detection
✅ **Interactive HTML** - Charts, color-coded alerts, recommendations
✅ **110+ Metrics** - Comprehensive performance visibility
✅ **Production Ready** - Error handling, validation, logging
✅ **Configurable** - 50+ settings for customization
✅ **Fast** - Minimal resource usage, parallel processing support
✅ **Well Documented** - This guide + inline comments

---

## 🚀 NEXT STEPS

1. **Install** - Copy scripts to /opt/oracle/awr_parser_v3
2. **Configure** - Edit awr_config.sh with your paths
3. **Test** - Run on sample AWR file
4. **Automate** - Add to cron for daily execution
5. **Integrate** - Send reports to team via email

---

**AWR Parser v3.0 is ready to deploy!** 🎉

For questions or issues, check the troubleshooting section or enable debug mode for detailed diagnostics.
