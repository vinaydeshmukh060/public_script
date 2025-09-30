#!/bin/sh
#
# rman_backup.sh - Production-ready RMAN backup solution
# Version: 1.0
# Author: Oracle DBA Team
# Description: POSIX-compatible shell script for Oracle RMAN backups
#
# ASSUMPTIONS:
# - Oracle Database 12c+ with RMAN
# - OS authentication or Oracle wallet configured (no hard-coded passwords)
# - Sufficient disk space in backup directories
# - Oracle user has write permissions to log and backup directories
# - /etc/oratab exists and is properly maintained
#
# INSTALLATION:
# 1. Copy rman_backup.sh and rman_backup.conf to desired location
# 2. chmod 755 rman_backup.sh
# 3. Edit rman_backup.conf for your environment
# 4. Test with dry-run: ./rman_backup.sh -i TESTDB -t L0 -d
#
# SCHEDULING (crontab examples):
# # Level 0 backup Sunday 2 AM
# 0 2 * * 0 /opt/oracle/scripts/rman_backup.sh -i PRODDB -t L0 -c Y
# # Level 1 backup Monday-Saturday 2 AM  
# 0 2 * * 1-6 /opt/oracle/scripts/rman_backup.sh -i PRODDB -t L1 -c Y
# # Archive backup every 6 hours
# 0 */6 * * * /opt/oracle/scripts/rman_backup.sh -i PRODDB -t Arch
#
# EXIT CODES:
# 0 = Success
# 1 = Invalid arguments
# 2 = Instance not running
# 3 = Database role not PRIMARY
# 4 = Backup error
# 5 = Retention cleanup error
# 6 = Configuration error
# 7 = Environment setup error
#

# Set strict error handling
set -e

# Global variables
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(dirname "$0")"
CONFIG_FILE="${SCRIPT_DIR}/rman_backup.conf"
INSTANCE_NAME=""
BACKUP_TYPE=""
COMPRESSION="N"
DRY_RUN="N"
VERBOSE="N"

# Timestamp for this run
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Function to display usage
usage() {
    cat << EOF
Usage: $SCRIPT_NAME -i INSTANCE_NAME -t BACKUP_TYPE [-c Y|N] [-d] [-v] [-h]

REQUIRED PARAMETERS:
  -i INSTANCE_NAME    Database instance/SID to backup
  -t BACKUP_TYPE      Backup type: L0 (Level 0), L1 (Level 1), Arch (Archive only)

OPTIONAL PARAMETERS:
  -c Y|N             Enable compression (default: N)
  -d                 Dry run mode - generate RMAN script but don't execute
  -v                 Verbose mode
  -h                 Show this help

EXAMPLES:
  $SCRIPT_NAME -i ORCL -t L0 -c Y          # Level 0 backup with compression
  $SCRIPT_NAME -i PRODDB -t L1             # Level 1 incremental backup
  $SCRIPT_NAME -i TESTDB -t Arch -d        # Dry run archive backup

LOG FILES CREATED:
  \${LOG_DIR}/\${INSTANCE}_\${TYPE}_\${TIMESTAMP}.log     # Main backup log
  \${ERROR_LOG_DIR}/\${INSTANCE}_\${TYPE}_\${TIMESTAMP}.err # Error details
  \${LOG_DIR}/\${INSTANCE}_retention_\${TIMESTAMP}.log    # Retention cleanup log

EOF
}

# Function to log messages with timestamp
log_message() {
    local level="$1"
    local message="$2"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    echo "[$timestamp] [$level] $message"
    
    if [ "$VERBOSE" = "Y" ] || [ "$level" = "ERROR" ]; then
        echo "[$timestamp] [$level] $message" >&2
    fi
}

# Function to handle script failure
fail() {
    local exit_code="$1"
    local error_message="$2"
    
    log_message "ERROR" "$error_message"
    
    # Write to error log if it exists
    if [ -n "$ERROR_LOG_FILE" ] && [ -w "$(dirname "$ERROR_LOG_FILE")" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') FATAL: $error_message" >> "$ERROR_LOG_FILE"
    fi
    
    exit "$exit_code"
}

# Function to parse command line arguments
parse_args() {
    log_message "INFO" "Parsing command line arguments"
    
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi
    
    while getopts "i:t:c:dvh" opt; do
        case $opt in
            i)
                INSTANCE_NAME="$OPTARG"
                ;;
            t)
                BACKUP_TYPE="$(echo "$OPTARG" | tr '[:lower:]' '[:upper:]')"
                ;;
            c)
                COMPRESSION="$(echo "$OPTARG" | tr '[:lower:]' '[:upper:]')"
                ;;
            d)
                DRY_RUN="Y"
                ;;
            v)
                VERBOSE="Y"
                ;;
            h)
                usage
                exit 0
                ;;
            \?)
                fail 1 "Invalid option: -$OPTARG"
                ;;
            :)
                fail 1 "Option -$OPTARG requires an argument"
                ;;
        esac
    done
    
    # Validate required parameters
    if [ -z "$INSTANCE_NAME" ]; then
        fail 1 "Instance name (-i) is required"
    fi
    
    if [ -z "$BACKUP_TYPE" ]; then
        fail 1 "Backup type (-t) is required"
    fi
    
    # Validate backup type
    case "$BACKUP_TYPE" in
        L0|L1|ARCH)
            ;;
        *)
            fail 1 "Invalid backup type: $BACKUP_TYPE. Must be L0, L1, or Arch"
            ;;
    esac
    
    # Validate compression flag
    case "$COMPRESSION" in
        Y|N)
            ;;
        *)
            fail 1 "Invalid compression flag: $COMPRESSION. Must be Y or N"
            ;;
    esac
    
    log_message "INFO" "Arguments parsed - Instance: $INSTANCE_NAME, Type: $BACKUP_TYPE, Compression: $COMPRESSION"
}

# Function to load configuration file
load_config() {
    log_message "INFO" "Loading configuration from $CONFIG_FILE"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        fail 6 "Configuration file not found: $CONFIG_FILE"
    fi
    
    if [ ! -r "$CONFIG_FILE" ]; then
        fail 6 "Configuration file not readable: $CONFIG_FILE"
    fi
    
    # Source the configuration file
    . "$CONFIG_FILE"
    
    # Validate required configuration variables
    if [ -z "$BASE_DIR" ]; then
        fail 6 "BASE_DIR not defined in configuration"
    fi
    
    if [ -z "$CHANNELS" ] || [ "$CHANNELS" -lt 1 ]; then
        fail 6 "CHANNELS must be defined and >= 1"
    fi
    
    # Set defaults for optional variables
    ORATAB_PATH="${ORATAB_PATH:-/etc/oratab}"
    RETENTION_DAYS="${RETENTION_DAYS:-3}"
    BACKUP_L0_DIR="${BACKUP_L0_DIR:-${BASE_DIR}/L0}"
    BACKUP_L1_DIR="${BACKUP_L1_DIR:-${BASE_DIR}/L1}"
    BACKUP_ARCH_DIR="${BACKUP_ARCH_DIR:-${BASE_DIR}/Arch}"
    
    # Validate numeric values
    if ! echo "$CHANNELS" | grep -q '^[0-9]\+$'; then
        fail 6 "CHANNELS must be a positive integer"
    fi
    
    if ! echo "$RETENTION_DAYS" | grep -q '^[0-9]\+$'; then
        fail 6 "RETENTION_DAYS must be a positive integer"
    fi
    
    log_message "INFO" "Configuration loaded successfully"
}

# Function to create directory structure
create_directories() {
    log_message "INFO" "Creating directory structure"
    
    # Create all required directories
    for dir in "$BASE_DIR" "$BACKUP_L0_DIR" "$BACKUP_L1_DIR" "$BACKUP_ARCH_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR"; do
        if [ ! -d "$dir" ]; then
            log_message "INFO" "Creating directory: $dir"
            if ! mkdir -p "$dir" 2>/dev/null; then
                fail 6 "Failed to create directory: $dir"
            fi
            chmod 755 "$dir"
        fi
    done
    
    # Set up log files for this run
    BACKUP_LOG_FILE="${LOG_DIR}/${INSTANCE_NAME}_${BACKUP_TYPE}_${RUN_TIMESTAMP}.log"
    ERROR_LOG_FILE="${ERROR_LOG_DIR}/${INSTANCE_NAME}_${BACKUP_TYPE}_${RUN_TIMESTAMP}.err"
    RETENTION_LOG_FILE="${LOG_DIR}/${INSTANCE_NAME}_retention_${RUN_TIMESTAMP}.log"
    RMAN_SCRIPT_FILE="${TMP_DIR}/${INSTANCE_NAME}_${BACKUP_TYPE}_${RUN_TIMESTAMP}.rman"
    
    log_message "INFO" "Log files: Backup=$BACKUP_LOG_FILE, Error=$ERROR_LOG_FILE"
}

# Function to set Oracle environment from oratab
set_environment() {
    log_message "INFO" "Setting Oracle environment for instance $INSTANCE_NAME"
    
    if [ ! -f "$ORATAB_PATH" ]; then
        fail 7 "oratab file not found: $ORATAB_PATH"
    fi
    
    # Find the instance in oratab
    ORATAB_LINE=$(grep "^${INSTANCE_NAME}:" "$ORATAB_PATH" | head -1)
    
    if [ -z "$ORATAB_LINE" ]; then
        fail 7 "Instance $INSTANCE_NAME not found in $ORATAB_PATH"
    fi
    
    # Extract ORACLE_HOME from oratab entry
    ORACLE_HOME=$(echo "$ORATAB_LINE" | cut -d: -f2)
    
    if [ -z "$ORACLE_HOME" ] || [ ! -d "$ORACLE_HOME" ]; then
        fail 7 "Invalid ORACLE_HOME for instance $INSTANCE_NAME: $ORACLE_HOME"
    fi
    
    # Set Oracle environment variables
    export ORACLE_SID="$INSTANCE_NAME"
    export ORACLE_HOME
    export PATH="$ORACLE_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$ORACLE_HOME/lib:${LD_LIBRARY_PATH:-}"
    
    # Use configured RMAN binary or default
    RMAN_CMD="${RMAN_BINARY:-${ORACLE_HOME}/bin/rman}"
    
    if [ ! -x "$RMAN_CMD" ]; then
        fail 7 "RMAN binary not found or not executable: $RMAN_CMD"
    fi
    
    log_message "INFO" "Oracle environment set - HOME: $ORACLE_HOME, SID: $ORACLE_SID"
}

# Function to check instance status and role
check_instance() {
    log_message "INFO" "Checking instance status and database role"
    
    # Check if instance is running
    if ! ps -ef | grep "ora_pmon_${INSTANCE_NAME}" | grep -v grep >/dev/null; then
        fail 2 "Instance $INSTANCE_NAME is not running (ora_pmon process not found)"
    fi
    
    # Check database role using SQL*Plus
    DB_ROLE_CHECK="
    SET PAGESIZE 0
    SET FEEDBACK OFF
    SET HEADING OFF
    SELECT database_role FROM v\$database;
    EXIT;
    "
    
    DB_ROLE=$(echo "$DB_ROLE_CHECK" | "$ORACLE_HOME/bin/sqlplus" -s / as sysdba 2>/dev/null | tr -d ' \n\r')
    
    if [ "$DB_ROLE" != "PRIMARY" ]; then
        fail 3 "Database role is '$DB_ROLE', not PRIMARY. Backups should only run on PRIMARY databases"
    fi
    
    log_message "INFO" "Instance $INSTANCE_NAME is running and database role is PRIMARY"
}

# Function to build RMAN script based on backup type
build_rman_script() {
    log_message "INFO" "Building RMAN script for $BACKUP_TYPE backup"
    
    # Determine backup directory and format based on type
    case "$BACKUP_TYPE" in
        L0)
            BACKUP_DIR="$BACKUP_L0_DIR"
            BACKUP_FORMAT="$BACKUP_FORMAT_L0"
            ;;
        L1)
            BACKUP_DIR="$BACKUP_L1_DIR"
            BACKUP_FORMAT="$BACKUP_FORMAT_L1"
            ;;
        ARCH)
            BACKUP_DIR="$BACKUP_ARCH_DIR"
            BACKUP_FORMAT="$BACKUP_FORMAT_ARCH"
            ;;
    esac
    
    # Create date-based subdirectory
    DATE_DIR=$(date +%d-%b-%Y)
    FULL_BACKUP_PATH="${BACKUP_DIR}/${DATE_DIR}"
    
    if [ ! -d "$FULL_BACKUP_PATH" ]; then
        mkdir -p "$FULL_BACKUP_PATH"
        chmod 755 "$FULL_BACKUP_PATH"
    fi
    
    # Start building RMAN script
    cat > "$RMAN_SCRIPT_FILE" << 'RMAN_SCRIPT_START'
# RMAN Backup Script - Auto-generated
CONNECT TARGET /;

RMAN_SCRIPT_START
    
    # Add channel allocation
    echo "# Allocate channels" >> "$RMAN_SCRIPT_FILE"
    echo "RUN {" >> "$RMAN_SCRIPT_FILE"
    
    i=1
    while [ $i -le "$CHANNELS" ]; do
        echo "  ALLOCATE CHANNEL ch${i} DEVICE TYPE DISK MAXPIECESIZE ${CHANNEL_MAXSIZE};" >> "$RMAN_SCRIPT_FILE"
        i=$((i + 1))
    done
    
    # Add compression if requested
    if [ "$COMPRESSION" = "Y" ]; then
        echo "  CONFIGURE COMPRESSION ALGORITHM 'MEDIUM';" >> "$RMAN_SCRIPT_FILE"
    fi
    
    # Add backup commands based on type
    case "$BACKUP_TYPE" in
        L0)
            cat >> "$RMAN_SCRIPT_FILE" << RMAN_L0_BACKUP
  
  # Level 0 (Full) Backup
  BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL 0 DATABASE 
    FORMAT '${FULL_BACKUP_PATH}/L0_%d_%T_%s_%p.bkp'
    TAG 'LEVEL0_${RUN_TIMESTAMP}';
    
  # Backup SPFILE
  BACKUP SPFILE 
    FORMAT '${FULL_BACKUP_PATH}/spfile_%d_%T_%s_%p.bkp'
    TAG 'SPFILE_${RUN_TIMESTAMP}';
    
  # Backup Control File
  BACKUP CURRENT CONTROLFILE 
    FORMAT '${FULL_BACKUP_PATH}/controlfile_%d_%T_%s_%p.bkp'
    TAG 'CONTROLFILE_${RUN_TIMESTAMP}';
    
  # Backup Archive Logs (after full backup)
  BACKUP ARCHIVELOG ALL NOT BACKED UP
    FORMAT '${BACKUP_ARCH_DIR}/${DATE_DIR}/arch_%d_%T_%s_%p.bkp'
    TAG 'ARCHLOG_POST_L0_${RUN_TIMESTAMP}';

RMAN_L0_BACKUP
            ;;
        L1)
            cat >> "$RMAN_SCRIPT_FILE" << RMAN_L1_BACKUP

  # Level 1 (Incremental) Backup
  BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL 1 DATABASE
    FORMAT '${FULL_BACKUP_PATH}/L1_%d_%T_%s_%p.bkp'
    TAG 'LEVEL1_${RUN_TIMESTAMP}';
    
  # Backup SPFILE
  BACKUP SPFILE 
    FORMAT '${FULL_BACKUP_PATH}/spfile_%d_%T_%s_%p.bkp'
    TAG 'SPFILE_${RUN_TIMESTAMP}';
    
  # Backup Control File
  BACKUP CURRENT CONTROLFILE 
    FORMAT '${FULL_BACKUP_PATH}/controlfile_%d_%T_%s_%p.bkp'
    TAG 'CONTROLFILE_${RUN_TIMESTAMP}';
    
  # Backup Archive Logs (after incremental backup)
  BACKUP ARCHIVELOG ALL NOT BACKED UP
    FORMAT '${BACKUP_ARCH_DIR}/${DATE_DIR}/arch_%d_%T_%s_%p.bkp'
    TAG 'ARCHLOG_POST_L1_${RUN_TIMESTAMP}';

RMAN_L1_BACKUP
            ;;
        ARCH)
            cat >> "$RMAN_SCRIPT_FILE" << RMAN_ARCH_BACKUP

  # Archive Log Backup Only
  BACKUP ARCHIVELOG ALL NOT BACKED UP
    FORMAT '${FULL_BACKUP_PATH}/arch_%d_%T_%s_%p.bkp'
    TAG 'ARCHLOG_ONLY_${RUN_TIMESTAMP}';

RMAN_ARCH_BACKUP
            ;;
    esac
    
    # Close the RUN block and deallocate channels
    i=1
    while [ $i -le "$CHANNELS" ]; do
        echo "  RELEASE CHANNEL ch${i};" >> "$RMAN_SCRIPT_FILE"
        i=$((i + 1))
    done
    
    echo "}" >> "$RMAN_SCRIPT_FILE"
    echo "EXIT;" >> "$RMAN_SCRIPT_FILE"
    
    log_message "INFO" "RMAN script created: $RMAN_SCRIPT_FILE"
    
    if [ "$VERBOSE" = "Y" ]; then
        log_message "INFO" "RMAN script contents:"
        cat "$RMAN_SCRIPT_FILE"
    fi
}

# Function to load error mapping
load_error_map() {
    # Define error mapping as heredoc for easy maintenance
    # Format: ERROR_CODE|SHORT_MESSAGE|REMEDY
    ERROR_MAP="
RMAN-03009|failure to allocate channel|Check disk space/permissions and RMAN channel allocation
RMAN-03002|failure during compilation of backup command|Check syntax and RMAN configuration
RMAN-06059|expected archived log not found|Check archivelog generation and destination
RMAN-06169|could not read file header|Check file permissions and disk integrity
RMAN-00571|error occurred|Generic RMAN error - check RMAN output for details
RMAN-00569|error occurred|Generic RMAN error - check RMAN output for details
RMAN-06053|archivelog filename contains an illegal character|Check archivelog naming convention
RMAN-06054|media recovery requesting unknown archived log|Check archivelog sequence and availability
RMAN-03014|implicit resync of recovery catalog failed|Check recovery catalog connectivity
RMAN-08120|warning|Non-fatal warning - review RMAN output
ORA-19511|error occurred during archiving|Check archiver process and destination space
ORA-19809|limit exceeded for recovery files|Check FRA space and retention policy
ORA-19815|WARNING|Non-fatal warning about FRA usage
ORA-27041|unable to open file|Check file existence and permissions
ORA-19870|error while restoring backup piece|Check backup piece integrity and location
ORA-00600|internal error code|Contact Oracle Support with error details
ORA-07445|exception encountered|Contact Oracle Support - possible Oracle bug
ORA-00257|archiver error|Check archivelog destination space and permissions
ORA-16038|log sequence number not archivable|Check Data Guard configuration
ORA-19554|error allocating device|Check device availability and permissions
ORA-19606|Cannot copy or restore to snapshot control file|Check control file backup location
ORA-01119|error in creating database file|Check filesystem space and permissions
ORA-01110|data file|Generic datafile error - check specific file mentioned
ORA-01547|warning|Warning about redo log operations
ORA-00312|online log thread is corrupted|Check online redo log integrity
ORA-00313|open failed for log group|Check redo log file accessibility
"
}

# Function to scan RMAN log for errors
scan_log_for_errors() {
    log_message "INFO" "Scanning backup log for errors: $BACKUP_LOG_FILE"
    
    ERROR_FOUND=0
    
    # Load error mapping
    load_error_map
    
    # Initialize error log
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR SCAN RESULTS FOR: $BACKUP_LOG_FILE" > "$ERROR_LOG_FILE"
    echo "=====================================================================" >> "$ERROR_LOG_FILE"
    
    # Scan for RMAN and ORA errors
    if [ -f "$BACKUP_LOG_FILE" ]; then
        # Look for error patterns
        ERROR_LINES=$(grep -n -E "(RMAN-[0-9]+|ORA-[0-9]+|ERROR at line)" "$BACKUP_LOG_FILE" 2>/dev/null || true)
        
        if [ -n "$ERROR_LINES" ]; then
            ERROR_FOUND=1
            echo "ERRORS DETECTED:" >> "$ERROR_LOG_FILE"
            echo "" >> "$ERROR_LOG_FILE"
            
            # Process each error line
            echo "$ERROR_LINES" | while IFS= read -r error_line; do
                line_num=$(echo "$error_line" | cut -d: -f1)
                error_text=$(echo "$error_line" | cut -d: -f2-)
                
                echo "Line $line_num: $error_text" >> "$ERROR_LOG_FILE"
                
                # Extract error codes and map them
                error_codes=$(echo "$error_text" | grep -o -E "(RMAN-[0-9]+|ORA-[0-9]+)" || true)
                
                if [ -n "$error_codes" ]; then
                    for code in $error_codes; do
                        # Look up error code in mapping
                        mapping=$(echo "$ERROR_MAP" | grep "^$code|" || true)
                        
                        if [ -n "$mapping" ]; then
                            short_msg=$(echo "$mapping" | cut -d'|' -f2)
                            remedy=$(echo "$mapping" | cut -d'|' -f3)
                            echo "  → $code: $short_msg" >> "$ERROR_LOG_FILE"
                            echo "  → Remedy: $remedy" >> "$ERROR_LOG_FILE"
                        else
                            echo "  → $code: See Oracle RMAN/DBA documentation for details" >> "$ERROR_LOG_FILE"
                        fi
                        echo "" >> "$ERROR_LOG_FILE"
                    done
                fi
            done
        fi
        
        # Check for RMAN completion status
        if grep -q "RMAN> exit" "$BACKUP_LOG_FILE" && ! grep -q "Recovery Manager complete" "$BACKUP_LOG_FILE"; then
            ERROR_FOUND=1
            echo "RMAN did not complete successfully - check output for termination cause" >> "$ERROR_LOG_FILE"
        fi
        
        # Summary
        if [ $ERROR_FOUND -eq 0 ]; then
            echo "NO ERRORS DETECTED - Backup completed successfully" >> "$ERROR_LOG_FILE"
            log_message "INFO" "No errors found in backup log"
        else
            echo "" >> "$ERROR_LOG_FILE"
            echo "=====================================================================" >> "$ERROR_LOG_FILE"
            echo "ACTION REQUIRED: Review errors above and take corrective action" >> "$ERROR_LOG_FILE"
            echo "For additional error codes, update the error_map in this script" >> "$ERROR_LOG_FILE"
            log_message "ERROR" "Errors detected in backup - see $ERROR_LOG_FILE"
        fi
    else
        ERROR_FOUND=1
        echo "BACKUP LOG FILE NOT FOUND: $BACKUP_LOG_FILE" >> "$ERROR_LOG_FILE"
        log_message "ERROR" "Backup log file not found"
    fi
    
    return $ERROR_FOUND
}

# Function to run RMAN script
run_rman() {
    log_message "INFO" "Executing RMAN backup script"
    
    if [ "$DRY_RUN" = "Y" ]; then
        log_message "INFO" "DRY RUN MODE - RMAN script would be executed:"
        cat "$RMAN_SCRIPT_FILE"
        log_message "INFO" "Dry run completed successfully"
        return 0
    fi
    
    # Execute RMAN script
    log_message "INFO" "Starting RMAN execution - output will be logged to $BACKUP_LOG_FILE"
    
    if "$RMAN_CMD" < "$RMAN_SCRIPT_FILE" > "$BACKUP_LOG_FILE" 2>&1; then
        log_message "INFO" "RMAN execution completed"
        return 0
    else
        log_message "ERROR" "RMAN execution failed - check $BACKUP_LOG_FILE"
        return 1
    fi
}

# Function to perform retention cleanup
retention_cleanup() {
    log_message "INFO" "Starting retention cleanup (${RETENTION_DAYS} days retention)"
    
    if [ "$DRY_RUN" = "Y" ]; then
        log_message "INFO" "Dry run mode - skipping retention cleanup"
        return 0
    fi
    
    # Create retention cleanup RMAN script
    RETENTION_SCRIPT="${TMP_DIR}/${INSTANCE_NAME}_retention_${RUN_TIMESTAMP}.rman"
    
    cat > "$RETENTION_SCRIPT" << RETENTION_RMAN_SCRIPT
CONNECT TARGET /;

# Configure retention policy
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${RETENTION_DAYS} DAYS;

# Report obsolete backups
REPORT OBSOLETE;

# Delete obsolete backups
DELETE NOPROMPT OBSOLETE;

# Crosscheck all backups and copies
CROSSCHECK BACKUP;
CROSSCHECK COPY;

# Delete expired backups
DELETE NOPROMPT EXPIRED BACKUP;
DELETE NOPROMPT EXPIRED COPY;

EXIT;
RETENTION_RMAN_SCRIPT
    
    log_message "INFO" "Executing retention cleanup - output logged to $RETENTION_LOG_FILE"
    
    if "$RMAN_CMD" < "$RETENTION_SCRIPT" > "$RETENTION_LOG_FILE" 2>&1; then
        log_message "INFO" "Retention cleanup completed successfully"
        
        # Check for any issues in retention log
        if grep -q -E "(RMAN-[0-9]+|ORA-[0-9]+)" "$RETENTION_LOG_FILE"; then
            log_message "WARN" "Warnings/errors detected in retention cleanup - check $RETENTION_LOG_FILE"
            return 1
        fi
        
        return 0
    else
        log_message "ERROR" "Retention cleanup failed - check $RETENTION_LOG_FILE"
        return 1
    fi
}

# Function to rotate/cleanup old log files
rotate_logs() {
    log_message "INFO" "Rotating old log files (keeping ${LOG_RETENTION_DAYS:-7} days)"
    
    LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
    
    # Clean up old log files in LOG_DIR and ERROR_LOG_DIR
    for log_dir in "$LOG_DIR" "$ERROR_LOG_DIR"; do
        if [ -d "$log_dir" ]; then
            find "$log_dir" -name "${INSTANCE_NAME}_*" -type f -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true
        fi
    done
    
    # Clean up old temporary RMAN scripts
    if [ -d "$TMP_DIR" ]; then
        find "$TMP_DIR" -name "${INSTANCE_NAME}_*.rman" -type f -mtime +1 -delete 2>/dev/null || true
    fi
}

# Main execution function
main() {
    log_message "INFO" "Starting RMAN backup script - PID: $$"
    log_message "INFO" "Parameters: Instance=$INSTANCE_NAME, Type=$BACKUP_TYPE, Compression=$COMPRESSION, DryRun=$DRY_RUN"
    
    # Load configuration and set up environment
    load_config
    create_directories
    set_environment
    check_instance
    
    # Build and execute RMAN script
    build_rman_script
    
    if ! run_rman; then
        fail 4 "RMAN backup execution failed"
    fi
    
    # Skip error scanning and retention in dry run mode
    if [ "$DRY_RUN" = "Y" ]; then
        log_message "INFO" "Dry run completed successfully"
        exit 0
    fi
    
    # Scan for errors
    if ! scan_log_for_errors; then
        fail 4 "Backup completed with errors - check error log"
    fi
    
    # Perform retention cleanup only if backup was successful
    if ! retention_cleanup; then
        log_message "WARN" "Retention cleanup failed, but backup was successful"
        # Don't fail the script for retention issues if backup succeeded
    fi
    
    # Rotate old logs
    rotate_logs
    
    log_message "INFO" "RMAN backup completed successfully"
    log_message "INFO" "Log files: Backup=$BACKUP_LOG_FILE, Error=$ERROR_LOG_FILE"
}

# Signal handlers for cleanup
cleanup() {
    log_message "INFO" "Script interrupted - cleaning up temporary files"
    rm -f "$RMAN_SCRIPT_FILE" 2>/dev/null || true
    exit 130
}

trap cleanup INT TERM

# Script entry point
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

# Parse arguments and run main function
parse_args "$@"
main

# Clean exit
exit 0