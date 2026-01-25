#!/bin/bash

################################################################################
#                                                                              #
#  AWR PARSER v3.0 - Configuration File                                      #
#  Customize paths, thresholds, and behavior                                  #
#                                                                              #
################################################################################

# ============================================================================
# PATH CONFIGURATION
# ============================================================================

# Input directory containing AWR text files
export AWR_INPUT_PATH="/mnt/awr"

# Output directory for CSV, HTML, and JSON reports
export AWR_OUTPUT_PATH="/reports"

# CSV-specific output location (optional, uses AWR_OUTPUT_PATH if unset)
export CSV_OUTPUT_PATH="${AWR_OUTPUT_PATH}/csv"

# HTML-specific output location (optional, uses AWR_OUTPUT_PATH if unset)
export HTML_OUTPUT_PATH="${AWR_OUTPUT_PATH}/html"

# JSON-specific output location (optional, uses AWR_OUTPUT_PATH if unset)
export JSON_OUTPUT_PATH="${AWR_OUTPUT_PATH}/json"

# Archive directory for processed AWR files (optional)
export AWR_ARCHIVE_PATH="${AWR_OUTPUT_PATH}/archive"

# ============================================================================
# REPORT CONFIGURATION
# ============================================================================

# Report title
export REPORT_TITLE="Oracle AWR Performance Analysis"

# Include detailed recommendations
export INCLUDE_RECOMMENDATIONS=1

# Generate HTML dashboard
export GENERATE_HTML=1

# Generate JSON export
export GENERATE_JSON=0

# Generate graphs/charts
export ENABLE_CHARTS=1

# Comparative analysis (compare snapshots)
export COMPARATIVE_ANALYSIS=0

# ============================================================================
# EXECUTION MODES
# ============================================================================

# Verbose output (detailed logging)
export VERBOSE=1

# Silent mode (suppress info messages)
export SILENT=0

# Debug mode (very detailed logging)
export DEBUG=0

# Print extracted values to screen
export PRINT_VALUES=0

# ============================================================================
# PERFORMANCE THRESHOLDS (19c Best Practices)
# ============================================================================

# AAS Thresholds
export HEALTHY_AAS_THRESHOLD=0.5
export WARNING_AAS_THRESHOLD=2.0
export CRITICAL_AAS_THRESHOLD=4.0

# Buffer Hit Ratio Thresholds
export HEALTHY_BUFFER_HIT=95
export WARNING_BUFFER_HIT=90
export CRITICAL_BUFFER_HIT=80

# Latency Thresholds (milliseconds)
export HEALTHY_LATENCY_MS=5
export WARNING_LATENCY_MS=10
export CRITICAL_LATENCY_MS=20

# User I/O Latency Thresholds (milliseconds)
export HEALTHY_IO_LATENCY_MS=8
export WARNING_IO_LATENCY_MS=15
export CRITICAL_IO_LATENCY_MS=30

# Redo Log Sync Latency (milliseconds)
export HEALTHY_REDO_SYNC_MS=5
export WARNING_REDO_SYNC_MS=12
export CRITICAL_REDO_SYNC_MS=25

# Log Switch Threshold (per hour)
export HEALTHY_LOG_SWITCHES_PER_HOUR=0
export WARNING_LOG_SWITCHES_PER_HOUR=3
export CRITICAL_LOG_SWITCHES_PER_HOUR=6

# Parse Failure Ratio (% of parses that hard parse)
export HEALTHY_HARD_PARSE_RATIO=5
export WARNING_HARD_PARSE_RATIO=10
export CRITICAL_HARD_PARSE_RATIO=20

# ============================================================================
# RAC-SPECIFIC CONFIGURATION
# ============================================================================

# Enable RAC analysis
export ENABLE_RAC_ANALYSIS=1

# RAC Cluster name
export RAC_CLUSTER_NAME="PROD"

# Number of instances expected
export EXPECTED_INSTANCES=3

# GC efficiency threshold (%)
export HEALTHY_GC_EFFICIENCY=90
export WARNING_GC_EFFICIENCY=80
export CRITICAL_GC_EFFICIENCY=70

# Interconnect latency warning (ms)
export WARNING_INTERCONNECT_LATENCY_MS=15
export CRITICAL_INTERCONNECT_LATENCY_MS=30

# ============================================================================
# EXADATA-SPECIFIC CONFIGURATION
# ============================================================================

# Enable Exadata metrics analysis
export ENABLE_EXADATA_ANALYSIS=0

# Smart scan efficiency threshold (%)
export HEALTHY_SMART_SCAN_EFFICIENCY=75
export WARNING_SMART_SCAN_EFFICIENCY=50
export CRITICAL_SMART_SCAN_EFFICIENCY=25

# Cell cache hit ratio threshold (%)
export HEALTHY_CELL_CACHE_HIT=85
export WARNING_CELL_CACHE_HIT=70
export CRITICAL_CELL_CACHE_HIT=50

# ============================================================================
# ORACLE CLOUD CONFIGURATION
# ============================================================================

# Enable Oracle Cloud (OCI) metrics
export ENABLE_CLOUD_ANALYSIS=0

# Enable Autonomous Database specific analysis
export ENABLE_AUTONOMOUS_DB=0

# ============================================================================
# 19c-SPECIFIC FEATURES
# ============================================================================

# Enable 19c+ specific analysis
export ENABLE_19C_ANALYSIS=1

# Enable 21c+ specific analysis
export ENABLE_21C_ANALYSIS=1

# Enable 23c+ specific analysis
export ENABLE_23C_ANALYSIS=0

# Adaptive Query Optimization detection
export DETECT_ADAPTIVE_OPTIMIZATION=1

# In-Memory option detection
export DETECT_IN_MEMORY=1

# Real Application Clustering (RAC) detection
export DETECT_RAC=1

# Data Guard detection
export DETECT_DATA_GUARD=1

# ============================================================================
# ALERT CONFIGURATION
# ============================================================================

# Enable threshold-based alerts
export ENABLE_ALERTS=1

# Alert on AAS vs CPU ratio
export ALERT_AAS_VS_CPU=1

# Alert email configuration (for production)
export ALERT_EMAIL=""
export ALERT_EMAIL_ENABLED=0

# Slack webhook for notifications
export SLACK_WEBHOOK_URL=""
export SLACK_NOTIFICATIONS_ENABLED=0

# ============================================================================
# FILTERING & EXCLUSIONS
# ============================================================================

# Exclude AWR reports older than N days
export EXCLUDE_OLDER_THAN_DAYS=0

# Include only reports from specific databases (comma-separated)
export INCLUDE_DATABASES=""

# Exclude specific databases (comma-separated)
export EXCLUDE_DATABASES=""

# Include only reports from specific instances (comma-separated)
export INCLUDE_INSTANCES=""

# ============================================================================
# PROCESSING OPTIONS
# ============================================================================

# Maximum number of files to process in parallel
export MAX_PARALLEL_JOBS=3

# Timeout for processing each file (seconds)
export FILE_PROCESSING_TIMEOUT=60

# Memory-efficient mode (for large files)
export MEMORY_EFFICIENT_MODE=0

# ============================================================================
# BACKUP & ARCHIVE
# ============================================================================

# Archive processed files
export ARCHIVE_PROCESSED_FILES=0

# Compression format (gzip, bzip2, xz, or none)
export COMPRESSION_FORMAT="none"

# Retain original files after processing
export RETAIN_ORIGINAL_FILES=1

# ============================================================================
# LOGGING & AUDIT
# ============================================================================

# Log file location
export LOG_FILE="${AWR_OUTPUT_PATH}/awr_parser.log"

# Enable audit logging (track all operations)
export ENABLE_AUDIT_LOG=0

# Audit log file
export AUDIT_LOG_FILE="${AWR_OUTPUT_PATH}/awr_audit.log"

# Log level (INFO, WARN, ERROR, DEBUG)
export LOG_LEVEL="INFO"

# ============================================================================
# INTEGRATION OPTIONS
# ============================================================================

# Prometheus metrics export
export EXPORT_PROMETHEUS_METRICS=0
export PROMETHEUS_PUSHGATEWAY_URL="localhost:9091"

# Grafana datasource export
export EXPORT_GRAFANA_DATASOURCE=0

# InfluxDB export
export EXPORT_INFLUXDB=0
export INFLUXDB_URL="http://localhost:8086"
export INFLUXDB_DATABASE="oracle_metrics"

# ELK Stack export
export EXPORT_ELK_STACK=0
export ELASTICSEARCH_URL="http://localhost:9200"

# ============================================================================
# CUSTOMIZATION
# ============================================================================

# Company/Department name for reports
export COMPANY_NAME="Your Organization"

# Department name
export DEPARTMENT_NAME="Database Engineering"

# Contact email for report recipients
export REPORT_CONTACT_EMAIL="dba@example.com"

# Custom CSS file path (optional)
export CUSTOM_CSS_PATH=""

# Custom logo URL (for HTML reports)
export LOGO_URL=""

# ============================================================================
# ADVANCED OPTIONS
# ============================================================================

# Detect and report anomalies
export DETECT_ANOMALIES=1

# Anomaly sensitivity level (1=sensitive, 5=conservative)
export ANOMALY_SENSITIVITY_LEVEL=3

# Trending analysis period (days)
export TRENDING_ANALYSIS_PERIOD=7

# Compare against baseline
export ENABLE_BASELINE_COMPARISON=0
export BASELINE_PERIOD="previous_week"

# ============================================================================
# VALIDATION
# ============================================================================

# Validate AWR file format before processing
export VALIDATE_AWR_FORMAT=1

# Skip corrupted or invalid files
export SKIP_INVALID_FILES=1

# Strict validation (fail on any error)
export STRICT_VALIDATION=0

# ============================================================================
# CLEANUP & MAINTENANCE
# ============================================================================

# Auto-cleanup old reports (days to retain)
export AUTO_CLEANUP_ENABLED=0
export REPORTS_RETENTION_DAYS=90

# Delete temporary files after processing
export DELETE_TEMP_FILES=1

# Compress output files
export COMPRESS_OUTPUT=0

# ============================================================================
# FUNCTION: Load Configuration
# ============================================================================

# Source this file in your scripts with:
# source /path/to/awr_config.sh

# Validate configuration on load
validate_config() {
    if [[ ! -d "$AWR_INPUT_PATH" ]]; then
        echo "Error: AWR_INPUT_PATH does not exist: $AWR_INPUT_PATH" >&2
        return 1
    fi
    
    if [[ ! -d "$AWR_OUTPUT_PATH" ]]; then
        echo "Creating output directory: $AWR_OUTPUT_PATH" >&2
        mkdir -p "$AWR_OUTPUT_PATH" || {
            echo "Error: Cannot create output directory: $AWR_OUTPUT_PATH" >&2
            return 1
        }
    fi
    
    return 0
}

# Print configuration summary
print_config_summary() {
    cat <<EOF
============================================================
AWR PARSER v3.0 - CONFIGURATION SUMMARY
============================================================
Input Path:          $AWR_INPUT_PATH
Output Path:         $AWR_OUTPUT_PATH
Generate HTML:       $GENERATE_HTML
Generate JSON:       $GENERATE_JSON
Verbose Mode:        $VERBOSE
RAC Analysis:        $ENABLE_RAC_ANALYSIS
19c Analysis:        $ENABLE_19C_ANALYSIS
Alerts Enabled:      $ENABLE_ALERTS
============================================================
EOF
}

# Export all variables for use in subshells
export_all_vars() {
    declare -x AWR_INPUT_PATH
    declare -x AWR_OUTPUT_PATH
    declare -x VERBOSE
    declare -x DEBUG
    declare -x GENERATE_HTML
}
