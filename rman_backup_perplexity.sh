#!/bin/sh
#
# RMAN Backup Solution - Production Ready
# File: rman_backup.sh
# Version: 1.0
# Description: Production RMAN backup script for Oracle databases
# Author: Oracle DBA Team
# Date: September 2025
#
# USAGE:
#   ./rman_backup.sh -i <instance_name> -t <backup_type> [-c <compression>]
#   
#   Arguments:
#     -i instance_name  : Oracle SID (required)
#     -t backup_type    : L0, L1, or Arch (case-insensitive, required)
#     -c compression    : Y or N (optional, defaults to config default)
#     -d                : Dry run mode - show what would be done without executing
#     -h                : Show help
#
# EXAMPLES:
#   ./rman_backup.sh -i ORCL -t L0 -c Y    # Full backup with compression
#   ./rman_backup.sh -i ORCL -t L1         # Incremental backup, default compression
#   ./rman_backup.sh -i PROD -t Arch       # Archive log backup only
#   ./rman_backup.sh -i TEST -t L0 -d      # Dry run for full backup
#
# EXIT CODES:
#   0  - Success (backup and retention cleanup completed)
#   1  - Invalid arguments or configuration error
#   2  - Oracle environment setup failure
#   3  - Database not running or not PRIMARY role
#   4  - RMAN backup operation failed
#   5  - Retention cleanup failed
#   6  - Lock file conflict (another instance running)
#
# LOG FILES (stored in ${base_dir}/logs/):
#   rman_backup_<instance>_<type>_<YYYYMMDD_HHMMSS>.log     - Main backup log
#   rman_errors_<instance>_<type>_<YYYYMMDD_HHMMSS>.log     - Error analysis log
#   rman_retention_<instance>_<type>_<YYYYMMDD_HHMMSS>.log  - Retention cleanup log
#

# Set strict error handling for production reliability
set -eu

# Script configuration constants
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly CONFIG_FILE="${SCRIPT_DIR}/rman_backup.conf"

# Global variables - initialized from config and arguments
INSTANCE_NAME=""
BACKUP_TYPE=""
COMPRESSION=""
DRY_RUN=0
ORACLE_HOME=""
ORACLE_SID=""
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# Configuration variables loaded from config file
base_dir=""
backup_L0_dir=""
backup_L1_dir=""
backup_Arch_dir=""
backup_format_L0=""
backup_format_L1=""
backup_format_Arch=""
channels=""
channel_max_size=""
oratab_path=""
retention_days=""
logs_dir=""
rman_binary=""
default_compression=""
environment_profile=""

# Log file paths - set after config is loaded
BACKUP_LOG=""
ERROR_LOG=""
RETENTION_LOG=""
LOCK_FILE=""

# Temporary files for RMAN operations
TEMP_RMAN_SCRIPT=""
TEMP_SQL_SCRIPT=""

#
# RMAN/ORA Error Mapping Table
# Maps common Oracle error codes to human-readable messages with suggested actions
#
declare_error_mappings() {
    # Error codes and their mappings - used by error_parser function
    # Format: "ERROR_CODE:Human readable message:Suggested action"
    cat <<'EOF'
ORA-19505:Failed to create backup file:Check disk space and directory permissions in backup destination
ORA-19511:I/O error occurred during backup operation:Verify media manager configuration and disk health
ORA-19514:Media manager error encountered:Check media manager logs and configuration
ORA-27037:Write error occurred on backup file:Check filesystem permissions and available disk space
ORA-27040:Unable to open backup file:Verify file permissions and directory accessibility
ORA-00257:Archive log destination full or quota exceeded:Free up space in archive destination or increase quota
ORA-27026:File not open or write error:Check file system health and permissions
RMAN-06002:No backup found in control file:Verify RMAN catalog configuration or recreate control file
RMAN-03009:Failure occurred during backup command execution:Check RMAN logs for detailed error information
RMAN-03002:Failure in RMAN channel allocation:Verify available system resources and RMAN configuration
RMAN-03030:Backup component not found:Check backup destination and RMAN catalog consistency
RMAN-03031:Could not allocate RMAN channel:Verify system resources and channel configuration parameters
RMAN-1054:Invalid RMAN command syntax used:Review RMAN command syntax and parameters
RMAN-06010:DBID mismatch or DBID not set:Set correct DBID or reconnect to proper target database
EOF
}

#
# Display usage information and exit
#
show_usage() {
    echo "Usage: $SCRIPT_NAME -i <instance_name> -t <backup_type> [-c <compression>] [-d] [-h]"
    echo ""
    echo "Arguments:"
    echo "  -i instance_name  Oracle SID (required)"
    echo "  -t backup_type    L0 (full), L1 (incremental), or Arch (archive logs) - case insensitive"
    echo "  -c compression    Y (enable) or N (disable) compression - optional"
    echo "  -d                Dry run mode - show actions without executing"
    echo "  -h                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME -i ORCL -t L0 -c Y    # Full backup with compression"
    echo "  $SCRIPT_NAME -i ORCL -t L1         # Incremental backup"
    echo "  $SCRIPT_NAME -i PROD -t Arch       # Archive log backup"
    exit 1
}

#
# Log message with timestamp to specified file
# Args: $1=log_file, $2=message
#
log_message() {
    local log_file="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] $message" >> "$log_file"
}

#
# Log error message to error log and optionally to stderr
# Args: $1=message, $2=exit_code (optional)
#
log_error() {
    local message="$1"
    local exit_code="${2:-}"
    
    log_message "$ERROR_LOG" "ERROR: $message"
    echo "ERROR: $message" >&2
    
    if [ -n "$exit_code" ]; then
        log_message "$ERROR_LOG" "Script exiting with code $exit_code"
        exit "$exit_code"
    fi
}

#
# Cleanup function - removes temporary files and lock file
# Called on script exit via trap
#
cleanup() {
    local exit_code=$?
    
    # Remove temporary files if they exist
    [ -n "${TEMP_RMAN_SCRIPT:-}" ] && [ -f "$TEMP_RMAN_SCRIPT" ] && rm -f "$TEMP_RMAN_SCRIPT"
    [ -n "${TEMP_SQL_SCRIPT:-}" ] && [ -f "$TEMP_SQL_SCRIPT" ] && rm -f "$TEMP_SQL_SCRIPT"
    
    # Remove lock file if we created it
    [ -n "${LOCK_FILE:-}" ] && [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
    
    # Log cleanup completion if error log exists
    if [ -n "${ERROR_LOG:-}" ] && [ -f "$ERROR_LOG" ]; then
        if [ $exit_code -ne 0 ]; then
            log_message "$ERROR_LOG" "Script cleanup completed with exit code $exit_code"
        fi
    fi
    
    exit $exit_code
}

#
# Set trap for cleanup on script exit
#
trap cleanup EXIT INT TERM

#
# Parse command line arguments
# Sets global variables: INSTANCE_NAME, BACKUP_TYPE, COMPRESSION, DRY_RUN
#
parse_arguments() {
    # Check if no arguments provided
    if [ $# -eq 0 ]; then
        echo "ERROR: No arguments provided" >&2
        show_usage
    fi
    
    # Parse arguments using getopts
    while getopts "i:t:c:dh" opt; do
        case $opt in
            i) INSTANCE_NAME="$OPTARG" ;;
            t) BACKUP_TYPE="$(echo "$OPTARG" | tr '[:lower:]' '[:upper:]')" ;;
            c) COMPRESSION="$(echo "$OPTARG" | tr '[:lower:]' '[:upper:]')" ;;
            d) DRY_RUN=1 ;;
            h) show_usage ;;
            ?) 
                echo "ERROR: Invalid option" >&2
                show_usage
                ;;
        esac
    done
    
    # Validate required arguments
    if [ -z "$INSTANCE_NAME" ]; then
        echo "ERROR: Instance name (-i) is required" >&2
        show_usage
    fi
    
    if [ -z "$BACKUP_TYPE" ]; then
        echo "ERROR: Backup type (-t) is required" >&2
        show_usage
    fi
    
    # Validate backup type
    case "$BACKUP_TYPE" in
        L0|L1|ARCH) ;;
        *)
            echo "ERROR: Invalid backup type '$BACKUP_TYPE'. Must be L0, L1, or Arch" >&2
            show_usage
            ;;
    esac
    
    # Validate compression if provided
    if [ -n "$COMPRESSION" ] && [ "$COMPRESSION" != "Y" ] && [ "$COMPRESSION" != "N" ]; then
        echo "ERROR: Invalid compression value '$COMPRESSION'. Must be Y or N" >&2
        show_usage
    fi
}

#
# Load and validate configuration file
# Sets all configuration variables from rman_backup.conf
#
load_configuration() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
        exit 1
    fi
    
    # Source the configuration file
    # shellcheck source=rman_backup.conf
    . "$CONFIG_FILE"
    
    # Validate required configuration variables
    local required_vars="base_dir backup_L0_dir backup_L1_dir backup_Arch_dir channels channel_max_size oratab_path retention_days logs_dir rman_binary default_compression"
    
    for var in $required_vars; do
        eval "value=\${$var:-}"
        if [ -z "$value" ]; then
            echo "ERROR: Required configuration variable '$var' not set in $CONFIG_FILE" >&2
            exit 1
        fi
    done
    
    # Set compression default if not provided via command line
    if [ -z "$COMPRESSION" ]; then
        COMPRESSION="$default_compression"
    fi
    
    # Expand variables in configuration paths
    eval "base_dir=\"$base_dir\""
    eval "backup_L0_dir=\"$backup_L0_dir\""
    eval "backup_L1_dir=\"$backup_L1_dir\""
    eval "backup_Arch_dir=\"$backup_Arch_dir\""
    eval "logs_dir=\"$logs_dir\""
    
    # Set log file paths based on configuration
    BACKUP_LOG="${logs_dir}/rman_backup_${INSTANCE_NAME}_${BACKUP_TYPE}_${TIMESTAMP}.log"
    ERROR_LOG="${logs_dir}/rman_errors_${INSTANCE_NAME}_${BACKUP_TYPE}_${TIMESTAMP}.log"
    RETENTION_LOG="${logs_dir}/rman_retention_${INSTANCE_NAME}_${BACKUP_TYPE}_${TIMESTAMP}.log"
    LOCK_FILE="${logs_dir}/.rman_backup_${INSTANCE_NAME}.lock"
}

#
# Create required directories for backup operation
# Creates backup target directories and logs directory
#
create_directories() {
    local dirs="$logs_dir"
    
    # Add backup directories based on backup type
    case "$BACKUP_TYPE" in
        L0) dirs="$dirs $backup_L0_dir $backup_Arch_dir" ;;
        L1) dirs="$dirs $backup_L1_dir $backup_Arch_dir" ;;
        ARCH) dirs="$dirs $backup_Arch_dir" ;;
    esac
    
    # Create directories if they don't exist
    for dir in $dirs; do
        if [ ! -d "$dir" ]; then
            if [ $DRY_RUN -eq 1 ]; then
                echo "DRY RUN: Would create directory: $dir"
            else
                if ! mkdir -p "$dir"; then
                    echo "ERROR: Failed to create directory: $dir" >&2
                    exit 1
                fi
            fi
        fi
    done
}

#
# Check for concurrent backup operations using lock file
# Creates lock file with current PID to prevent concurrent runs
#
check_lock_file() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        # Check if the process is still running
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Another backup process is running for instance $INSTANCE_NAME (PID: $lock_pid)" 6
        else
            # Stale lock file - remove it
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Create lock file with current PID
    if [ $DRY_RUN -eq 0 ]; then
        echo $$ > "$LOCK_FILE"
    fi
}

#
# Setup Oracle environment by reading oratab and setting ORACLE_HOME/ORACLE_SID
# Validates that the instance exists and is configured
#
setup_oracle_environment() {
    if [ ! -f "$oratab_path" ]; then
        log_error "Oracle oratab file not found: $oratab_path" 2
    fi
    
    # Parse oratab to find ORACLE_HOME for the given instance
    local oratab_entry
    oratab_entry=$(grep "^${INSTANCE_NAME}:" "$oratab_path" 2>/dev/null || true)
    
    if [ -z "$oratab_entry" ]; then
        log_error "Instance '$INSTANCE_NAME' not found in $oratab_path" 2
    fi
    
    # Extract ORACLE_HOME from oratab entry (format: SID:ORACLE_HOME:Y/N)
    ORACLE_HOME=$(echo "$oratab_entry" | cut -d: -f2)
    
    if [ -z "$ORACLE_HOME" ] || [ ! -d "$ORACLE_HOME" ]; then
        log_error "Invalid ORACLE_HOME '$ORACLE_HOME' for instance '$INSTANCE_NAME'" 2
    fi
    
    # Set Oracle environment variables
    ORACLE_SID="$INSTANCE_NAME"
    export ORACLE_HOME ORACLE_SID
    
    # Update PATH to include Oracle binaries
    PATH="${ORACLE_HOME}/bin:${PATH}"
    export PATH
    
    # Source environment profile if specified
    if [ -n "$environment_profile" ] && [ -f "/home/${environment_profile}/.bash_profile" ]; then
        # shellcheck source=/dev/null
        . "/home/${environment_profile}/.bash_profile"
    fi
    
    log_message "$BACKUP_LOG" "Oracle environment set: ORACLE_HOME=$ORACLE_HOME, ORACLE_SID=$ORACLE_SID"
}

#
# Verify that the Oracle instance is running and accessible
# Uses sqlplus to connect and check instance status
#
verify_instance_running() {
    # Create temporary SQL script to check instance status
    TEMP_SQL_SCRIPT="${logs_dir}/.check_instance_${INSTANCE_NAME}_$$.sql"
    
    cat > "$TEMP_SQL_SCRIPT" <<EOF
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SELECT status FROM v\$instance;
EXIT;
EOF
    
    # Execute SQL script to check instance status
    local instance_status
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY RUN: Would check instance status with: sqlplus -s / as sysdba @$TEMP_SQL_SCRIPT"
        instance_status="OPEN"  # Assume success for dry run
    else
        instance_status=$(sqlplus -s / as sysdba @"$TEMP_SQL_SCRIPT" 2>/dev/null | tr -d ' \n')
        
        if [ "$?" -ne 0 ] || [ -z "$instance_status" ]; then
            log_error "Cannot connect to Oracle instance '$INSTANCE_NAME' or instance is not running" 3
        fi
    fi
    
    if [ "$instance_status" != "OPEN" ]; then
        log_error "Oracle instance '$INSTANCE_NAME' is not in OPEN status (current: $instance_status)" 3
    fi
    
    log_message "$BACKUP_LOG" "Instance status verified: $instance_status"
}

#
# Verify that the database role is PRIMARY
# Connects to database and checks v$database.database_role
#
verify_database_role() {
    # Create temporary SQL script to check database role
    TEMP_SQL_SCRIPT="${logs_dir}/.check_role_${INSTANCE_NAME}_$$.sql"
    
    cat > "$TEMP_SQL_SCRIPT" <<EOF
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SELECT database_role FROM v\$database;
EXIT;
EOF
    
    # Execute SQL script to check database role
    local db_role
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY RUN: Would check database role with: sqlplus -s / as sysdba @$TEMP_SQL_SCRIPT"
        db_role="PRIMARY"  # Assume success for dry run
    else
        db_role=$(sqlplus -s / as sysdba @"$TEMP_SQL_SCRIPT" 2>/dev/null | tr -d ' \n')
        
        if [ "$?" -ne 0 ] || [ -z "$db_role" ]; then
            log_error "Cannot determine database role for instance '$INSTANCE_NAME'" 3
        fi
    fi
    
    if [ "$db_role" != "PRIMARY" ]; then
        log_error "Database role is '$db_role' - backups can only be taken on PRIMARY database" 3
    fi
    
    log_message "$BACKUP_LOG" "Database role verified: $db_role"
}

#
# Verify RMAN binary exists and is executable
# Checks configured rman_binary path or searches PATH
#
verify_rman_binary() {
    local rman_cmd="$rman_binary"
    
    # If rman_binary is just 'rman', try to find it in PATH
    if [ "$rman_binary" = "rman" ]; then
        rman_cmd=$(which rman 2>/dev/null || echo "")
        if [ -z "$rman_cmd" ]; then
            log_error "RMAN binary not found in PATH" 2
        fi
    elif [ ! -x "$rman_binary" ]; then
        log_error "RMAN binary not found or not executable: $rman_binary" 2
    fi
    
    log_message "$BACKUP_LOG" "RMAN binary verified: $rman_cmd"
}

#
# Generate backup format string with date substitution
# Args: $1=format_template
# Returns: formatted string with date tokens replaced
#
generate_backup_format() {
    local format_template="$1"
    local current_date=$(date '+%d-%b-%Y')  # Format: 03-Oct-2025
    
    # Replace <date:dd-mon-yyyy> tokens with actual date
    echo "$format_template" | sed "s/<date:dd-mon-yyyy>/$current_date/g"
}

#
# Create RMAN script for backup operations
# Generates temporary RMAN script based on backup type and configuration
#
create_rman_script() {
    TEMP_RMAN_SCRIPT="${logs_dir}/.rman_script_${INSTANCE_NAME}_${BACKUP_TYPE}_$$.rman"
    
    # Determine backup format and directory based on backup type
    local backup_format=""
    local backup_dir=""
    
    case "$BACKUP_TYPE" in
        L0)
            backup_format=$(generate_backup_format "$backup_format_L0")
            backup_dir="$backup_L0_dir"
            ;;
        L1)
            backup_format=$(generate_backup_format "$backup_format_L1")
            backup_dir="$backup_L1_dir"
            ;;
        ARCH)
            backup_format=$(generate_backup_format "$backup_format_Arch")
            backup_dir="$backup_Arch_dir"
            ;;
    esac
    
    # Start creating RMAN script
    cat > "$TEMP_RMAN_SCRIPT" <<EOF
# RMAN Backup Script for $INSTANCE_NAME - $BACKUP_TYPE backup
# Generated: $(date)
# Compression: $COMPRESSION
CONNECT TARGET /;

# Configure RMAN settings
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '$backup_dir/cf_%F';

# Allocate channels based on configuration
RUN {
EOF
    
    # Add channel allocation to RMAN script
    local i=1
    while [ $i -le "$channels" ]; do
        echo "    ALLOCATE CHANNEL ch${i} DEVICE TYPE DISK MAXPIECESIZE ${channel_max_size};" >> "$TEMP_RMAN_SCRIPT"
        i=$((i + 1))
    done
    
    # Add backup commands based on backup type
    case "$BACKUP_TYPE" in
        L0)
            if [ "$COMPRESSION" = "Y" ]; then
                cat >> "$TEMP_RMAN_SCRIPT" <<EOF
    
    # Full backup (Level 0) with compression
    BACKUP AS COMPRESSED BACKUPSET 
           INCREMENTAL LEVEL 0 
           DATABASE 
           FORMAT '$backup_format'
           TAG 'L0_$(date +%Y%m%d_%H%M%S)';
    
    # Backup control file and spfile
    BACKUP AS COMPRESSED BACKUPSET 
           CURRENT CONTROLFILE 
           SPFILE 
           FORMAT '${backup_dir}/cf_spfile_%s_%p_%t';
    
    # Backup archive logs not already backed up
    BACKUP AS COMPRESSED BACKUPSET 
           ARCHIVELOG ALL NOT BACKED UP 
           FORMAT '$(generate_backup_format "$backup_format_Arch")'
           DELETE INPUT;
EOF
            else
                cat >> "$TEMP_RMAN_SCRIPT" <<EOF
    
    # Full backup (Level 0) without compression
    BACKUP AS BACKUPSET 
           INCREMENTAL LEVEL 0 
           DATABASE 
           FORMAT '$backup_format'
           TAG 'L0_$(date +%Y%m%d_%H%M%S)';
    
    # Backup control file and spfile
    BACKUP AS BACKUPSET 
           CURRENT CONTROLFILE 
           SPFILE 
           FORMAT '${backup_dir}/cf_spfile_%s_%p_%t';
    
    # Backup archive logs not already backed up
    BACKUP AS BACKUPSET 
           ARCHIVELOG ALL NOT BACKED UP 
           FORMAT '$(generate_backup_format "$backup_format_Arch")'
           DELETE INPUT;
EOF
            fi
            ;;
        L1)
            if [ "$COMPRESSION" = "Y" ]; then
                cat >> "$TEMP_RMAN_SCRIPT" <<EOF
    
    # Incremental backup (Level 1) with compression
    BACKUP AS COMPRESSED BACKUPSET 
           INCREMENTAL LEVEL 1 
           DATABASE 
           FORMAT '$backup_format'
           TAG 'L1_$(date +%Y%m%d_%H%M%S)';
    
    # Backup control file and spfile
    BACKUP AS COMPRESSED BACKUPSET 
           CURRENT CONTROLFILE 
           SPFILE 
           FORMAT '${backup_dir}/cf_spfile_%s_%p_%t';
    
    # Backup archive logs not already backed up
    BACKUP AS COMPRESSED BACKUPSET 
           ARCHIVELOG ALL NOT BACKED UP 
           FORMAT '$(generate_backup_format "$backup_format_Arch")'
           DELETE INPUT;
EOF
            else
                cat >> "$TEMP_RMAN_SCRIPT" <<EOF
    
    # Incremental backup (Level 1) without compression
    BACKUP AS BACKUPSET 
           INCREMENTAL LEVEL 1 
           DATABASE 
           FORMAT '$backup_format'
           TAG 'L1_$(date +%Y%m%d_%H%M%S)';
    
    # Backup control file and spfile
    BACKUP AS BACKUPSET 
           CURRENT CONTROLFILE 
           SPFILE 
           FORMAT '${backup_dir}/cf_spfile_%s_%p_%t';
    
    # Backup archive logs not already backed up
    BACKUP AS BACKUPSET 
           ARCHIVELOG ALL NOT BACKED UP 
           FORMAT '$(generate_backup_format "$backup_format_Arch")'
           DELETE INPUT;
EOF
            fi
            ;;
        ARCH)
            if [ "$COMPRESSION" = "Y" ]; then
                cat >> "$TEMP_RMAN_SCRIPT" <<EOF
    
    # Archive log backup with compression
    BACKUP AS COMPRESSED BACKUPSET 
           ARCHIVELOG ALL NOT BACKED UP 
           FORMAT '$backup_format'
           DELETE INPUT;
EOF
            else
                cat >> "$TEMP_RMAN_SCRIPT" <<EOF
    
    # Archive log backup without compression
    BACKUP AS BACKUPSET 
           ARCHIVELOG ALL NOT BACKED UP 
           FORMAT '$backup_format'
           DELETE INPUT;
EOF
            fi
            ;;
    esac
    
    # Close RMAN script
    cat >> "$TEMP_RMAN_SCRIPT" <<EOF

    # Release allocated channels
EOF
    
    # Add channel release commands
    local i=1
    while [ $i -le "$channels" ]; do
        echo "    RELEASE CHANNEL ch${i};" >> "$TEMP_RMAN_SCRIPT"
        i=$((i + 1))
    done
    
    cat >> "$TEMP_RMAN_SCRIPT" <<EOF
}

EXIT;
EOF
    
    log_message "$BACKUP_LOG" "RMAN script created: $TEMP_RMAN_SCRIPT"
}

#
# Execute RMAN backup operation
# Runs the generated RMAN script and captures output
#
execute_rman_backup() {
    log_message "$BACKUP_LOG" "Starting RMAN backup operation: $BACKUP_TYPE for instance $INSTANCE_NAME"
    log_message "$BACKUP_LOG" "Compression: $COMPRESSION, Channels: $channels"
    
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY RUN: Would execute RMAN script:"
        echo "Command: $rman_binary cmdfile=\"$TEMP_RMAN_SCRIPT\" msglog=\"$BACKUP_LOG\""
        echo ""
        echo "RMAN Script contents:"
        cat "$TEMP_RMAN_SCRIPT"
        return 0
    fi
    
    # Execute RMAN with the generated script
    if ! "$rman_binary" cmdfile="$TEMP_RMAN_SCRIPT" msglog="$BACKUP_LOG"; then
        log_error "RMAN backup operation failed - check $BACKUP_LOG for details" 4
    fi
    
    log_message "$BACKUP_LOG" "RMAN backup operation completed successfully"
}

#
# Parse RMAN log for errors and create error report
# Scans backup log for RMAN/ORA errors and maps them to human-readable messages
#
parse_backup_errors() {
    local error_found=0
    
    log_message "$ERROR_LOG" "Scanning backup log for errors: $BACKUP_LOG"
    
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY RUN: Would scan $BACKUP_LOG for RMAN/ORA errors"
        return 0
    fi
    
    # Check if backup log exists
    if [ ! -f "$BACKUP_LOG" ]; then
        log_error "Backup log file not found: $BACKUP_LOG" 4
    fi
    
    # Search for ORA- and RMAN- errors in backup log
    local error_lines
    error_lines=$(grep -E "(ORA-[0-9]+|RMAN-[0-9]+)" "$BACKUP_LOG" 2>/dev/null || true)
    
    if [ -n "$error_lines" ]; then
        error_found=1
        log_message "$ERROR_LOG" "Errors detected in backup operation:"
        log_message "$ERROR_LOG" "Raw error lines from backup log:"
        
        # Log each error line
        echo "$error_lines" | while IFS= read -r line; do
            log_message "$ERROR_LOG" "  $line"
        done
        
        log_message "$ERROR_LOG" ""
        log_message "$ERROR_LOG" "Error analysis and suggested actions:"
        
        # Map errors to human-readable messages
        declare_error_mappings | while IFS=':' read -r error_code message action; do
            if echo "$error_lines" | grep -q "$error_code"; then
                log_message "$ERROR_LOG" "[$error_code] $message"
                log_message "$ERROR_LOG" "  Action: $action"
                log_message "$ERROR_LOG" ""
            fi
        done
        
        # Check for unmapped errors
        local unmapped_errors
        unmapped_errors=$(echo "$error_lines" | grep -oE "(ORA-[0-9]+|RMAN-[0-9]+)" | sort -u)
        
        # Create list of mapped error codes for comparison
        local mapped_codes
        mapped_codes=$(declare_error_mappings | cut -d':' -f1 | tr '\n' '|' | sed 's/|$//')
        
        echo "$unmapped_errors" | while IFS= read -r error_code; do
            if ! echo "$error_code" | grep -qE "($mapped_codes)"; then
                log_message "$ERROR_LOG" "[$error_code] Unknown RMAN/ORA error - consult alert log and RMAN output"
                log_message "$ERROR_LOG" "  Action: Review Oracle alert log and detailed RMAN output for more information"
                log_message "$ERROR_LOG" ""
            fi
        done
    else
        log_message "$ERROR_LOG" "No RMAN/ORA errors detected in backup operation"
    fi
    
    if [ $error_found -eq 1 ]; then
        log_error "Backup completed with errors - see $ERROR_LOG for details" 4
    fi
}

#
# Execute RMAN retention policy cleanup
# Runs REPORT OBSOLETE and DELETE OBSOLETE based on configured retention
#
execute_retention_cleanup() {
    log_message "$RETENTION_LOG" "Starting retention cleanup for instance $INSTANCE_NAME"
    log_message "$RETENTION_LOG" "Retention policy: $retention_days days"
    
    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY RUN: Would execute retention cleanup:"
        echo "RMAN commands:"
        echo "  CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF $retention_days DAYS;"
        echo "  REPORT OBSOLETE;"
        echo "  DELETE OBSOLETE NOPROMPT;"
        return 0
    fi
    
    # Create RMAN script for retention cleanup
    local retention_script="${logs_dir}/.rman_retention_${INSTANCE_NAME}_$$.rman"
    
    cat > "$retention_script" <<EOF
CONNECT TARGET /;

# Configure retention policy
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF $retention_days DAYS;

# Report obsolete backups
REPORT OBSOLETE;

# Delete obsolete backups
DELETE OBSOLETE NOPROMPT;

EXIT;
EOF
    
    # Execute retention cleanup
    if ! "$rman_binary" cmdfile="$retention_script" msglog="$RETENTION_LOG"; then
        log_message "$ERROR_LOG" "WARNING: Retention cleanup failed - check $RETENTION_LOG"
        rm -f "$retention_script"
        return 5
    fi
    
    rm -f "$retention_script"
    log_message "$RETENTION_LOG" "Retention cleanup completed successfully"
    
    # Check retention log for errors
    local retention_errors
    retention_errors=$(grep -E "(ORA-[0-9]+|RMAN-[0-9]+)" "$RETENTION_LOG" 2>/dev/null || true)
    
    if [ -n "$retention_errors" ]; then
        log_message "$ERROR_LOG" "Errors detected during retention cleanup:"
        echo "$retention_errors" | while IFS= read -r line; do
            log_message "$ERROR_LOG" "  $line"
        done
        return 5
    fi
}

#
# Main execution function - orchestrates the entire backup process
#
main() {
    echo "RMAN Backup Script Starting - $(date)"
    echo "Instance: $INSTANCE_NAME, Type: $BACKUP_TYPE, Compression: $COMPRESSION"
    
    if [ $DRY_RUN -eq 1 ]; then
        echo "***** DRY RUN MODE - No actual operations will be performed *****"
    fi
    
    # Load configuration and setup
    load_configuration
    create_directories
    check_lock_file
    
    # Initialize log files
    if [ $DRY_RUN -eq 0 ]; then
        log_message "$BACKUP_LOG" "RMAN backup started: $BACKUP_TYPE for instance $INSTANCE_NAME"
        log_message "$ERROR_LOG" "Error log initialized for backup: $BACKUP_TYPE ($INSTANCE_NAME)"
    fi
    
    # Setup Oracle environment and verify prerequisites
    setup_oracle_environment
    verify_rman_binary
    verify_instance_running
    verify_database_role
    
    # Create and execute RMAN backup
    create_rman_script
    execute_rman_backup
    
    # Parse backup results for errors
    parse_backup_errors
    
    # Execute retention cleanup
    local retention_result=0
    execute_retention_cleanup || retention_result=$?
    
    # Final status reporting
    if [ $DRY_RUN -eq 1 ]; then
        echo ""
        echo "DRY RUN COMPLETED - No actual backup operations were performed"
        echo "Log files that would be created:"
        echo "  Backup log: $BACKUP_LOG"
        echo "  Error log:  $ERROR_LOG"
        echo "  Retention log: $RETENTION_LOG"
    else
        if [ $retention_result -eq 0 ]; then
            log_message "$BACKUP_LOG" "Backup and retention cleanup completed successfully"
            echo "SUCCESS: Backup completed successfully"
            echo "Log files:"
            echo "  Backup log: $BACKUP_LOG"
            echo "  Error log:  $ERROR_LOG"
            echo "  Retention log: $RETENTION_LOG"
        else
            log_error "Backup completed but retention cleanup failed" $retention_result
        fi
    fi
}

# Execute main function with all command line arguments
parse_arguments "$@"
main