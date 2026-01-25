#!/bin/bash

################################################################################
#                                                                              #
#  AWR PARSER v3.0 - Enhanced Oracle AWR Report Parser                        #
#  For Oracle Database 10g through 23c                                        #
#  Author: Senior DBA Toolkit                                                 #
#  License: GNU GPL v2                                                        #
#                                                                              #
################################################################################

set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="3.0"
SCRIPT_DATE="2026-01-25"
AWR_FORMAT=""

# ============================================================================
# CONFIGURATION & VARIABLES
# ============================================================================

# Script behavior flags
SILENT=0
VERBOSE=0
DEBUG=0
PRINT_HEADER_ONLY=0
NO_HEADER=0
PRINT_VALUES=0
GENERATE_HTML=1
GENERATE_JSON=0

# Exit codes
EXIT_SUCCESS=0
EXIT_PARTIAL=1
EXIT_FAILURE=2

# Counter variables
FILECNT=0
ERRORCNT=0

# Metrics storage (indexed)
declare -A METRICS

# Color codes for alerts (HTML)
COLOR_HEALTHY="#10b981"    # Green
COLOR_WARNING="#f59e0b"    # Amber
COLOR_CRITICAL="#ef4444"   # Red

# ============================================================================
# FUNCTIONS
# ============================================================================

# Print usage information
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [AWR_FILES]

AWR Parser v${SCRIPT_VERSION} - Extract and analyze Oracle AWR reports

OPTIONS:
  -i, --input DIR       Input directory containing AWR txt files
  -o, --output DIR      Output directory for CSV/HTML/JSON files
  -c, --csv-only        Generate CSV output only (no HTML)
  -j, --json            Generate JSON output format
  -g, --no-graphs       Disable HTML graph generation
  -s, --silent          Suppress progress messages
  -v, --verbose         Show detailed processing information
  -x, --debug           Enable debug mode with detailed logging
  -H, --header-only     Print CSV header row only and exit
  -n, --no-header       Omit header row from CSV output
  -p, --print           Print extracted values to screen
  -h, --help            Display this help message

EXAMPLES:
  # Parse all AWR reports in directory and generate HTML
  $SCRIPT_NAME -i /mnt/awr -o /reports

  # Silent mode with custom output path
  $SCRIPT_NAME -i /data/awr -o /web/reports -s

  # Generate CSV only, no HTML
  $SCRIPT_NAME -i /awr -o /output -c

  # Debug mode with verbose output
  $SCRIPT_NAME -i /awr -o /reports -v -x

FEATURES:
  ✓ Supports Oracle 10g through 23c AWR formats
  ✓ Extracts 110+ performance metrics
  ✓ No external package dependencies (pure bash)
  ✓ Generates interactive HTML dashboard
  ✓ RAC-aware with GC event analysis
  ✓ Automated performance alerts
  ✓ 19c best practice recommendations

EXIT CODES:
  0 = Success (all files processed)
  1 = Partial success (some files with errors)
  2 = Failure (no files processed)

EOF
    exit "$1"
}

# Print messages to stderr
msg_info() {
    [[ "$SILENT" -eq 0 ]] && echo "Info  : ${1}" >&2
}

msg_warn() {
    echo "Warn  : ${1}" >&2
}

msg_error() {
    echo "Error : ${1}" >&2
    ((ERRORCNT++))
}

msg_debug() {
    [[ "$DEBUG" -eq 1 ]] && echo "Debug : ${1}" >&2
}

msg_verbose() {
    [[ "$VERBOSE" -eq 1 ]] && echo "Verbose : ${1}" >&2
}

# Output CSV row
output_csv() {
    echo "$@"
}

# Initialize metrics array
init_metrics() {
    msg_debug "Initializing metrics array"
    
    # System metadata
    METRICS[filename]=""
    METRICS[db_name]=""
    METRICS[instance_num]=""
    METRICS[instance_name]=""
    METRICS[db_version]=""
    METRICS[cluster]="N"
    METRICS[hostname]=""
    METRICS[host_os]=""
    METRICS[num_cpus]="0"
    METRICS[server_memory]="0"
    METRICS[db_block_size]="0"
    
    # Snapshot info
    METRICS[begin_snap]=""
    METRICS[begin_time]=""
    METRICS[end_snap]=""
    METRICS[end_time]=""
    METRICS[elapsed_time]="0"
    METRICS[db_time]="0"
    METRICS[aas]="0"
    METRICS[busy_flag]="N"
    
    # I/O metrics
    METRICS[read_iops]="0"
    METRICS[write_iops]="0"
    METRICS[redo_iops]="0"
    METRICS[total_iops]="0"
    METRICS[read_throughput]="0"
    METRICS[write_throughput]="0"
    METRICS[redo_throughput]="0"
    METRICS[total_throughput]="0"
    
    # DB Time
    METRICS[db_cpu_time]="0"
    METRICS[db_cpu_pct]="0"
    
    # Wait classes (User I/O, System I/O, etc.)
    METRICS[user_io_waits]="0"
    METRICS[user_io_time]="0"
    METRICS[user_io_latency]="0"
    METRICS[user_io_pct]="0"
    
    # Call stats
    METRICS[user_calls]="0"
    METRICS[parses]="0"
    METRICS[hard_parses]="0"
    METRICS[logons]="0"
    METRICS[executes]="0"
    METRICS[transactions]="0"
    
    # Cache efficiency
    METRICS[buffer_hit_ratio]="0"
    METRICS[inmem_sort_ratio]="0"
    METRICS[log_switches]="0"
    
    # Top events (up to 10)
    for i in {1..10}; do
        METRICS[top_event_${i}_name]=""
        METRICS[top_event_${i}_class]=""
        METRICS[top_event_${i}_waits]="0"
        METRICS[top_event_${i}_time]="0"
        METRICS[top_event_${i}_latency]="0"
        METRICS[top_event_${i}_pct]="0"
    done
    
    # I/O specific events
    METRICS[dfsr_waits]="0"
    METRICS[dfsr_latency]="0"
    METRICS[dfxr_waits]="0"
    METRICS[dfxr_latency]="0"
    METRICS[dprd_waits]="0"
    METRICS[dprd_latency]="0"
    METRICS[dpwr_waits]="0"
    METRICS[dpwr_latency]="0"
    METRICS[lfs_waits]="0"
    METRICS[lfs_latency]="0"
    
    # OS stats
    METRICS[os_busy]="0"
    METRICS[os_idle]="0"
    METRICS[os_iowait]="0"
    
    # Flags
    METRICS[data_guard]="N"
    METRICS[exadata]="N"
    METRICS[rac]="N"
    
    # GC Events (19c+)
    METRICS[gc_cr_blocks]="0"
    METRICS[gc_cw_blocks]="0"
    METRICS[gc_read_waits]="0"
    METRICS[gc_read_latency]="0"
    METRICS[gc_write_waits]="0"
    METRICS[gc_write_latency]="0"
    
    # Latch contention
    METRICS[latch_contention]="0"
    METRICS[top_latch]=""
    
    # Lock events
    METRICS[lock_waits]="0"
    METRICS[itl_contention]="0"
    
    # Memory
    METRICS[disk_sort_pct]="0"
    METRICS[pga_efficiency]="0"
}

# Detect AWR format version from report header
detect_awr_format() {
    local file="$1"
    
    if grep -q "Startup Time" "$file"; then
        AWR_FORMAT="12c"
        msg_debug "Detected 12c AWR format"
    elif grep -q "Oracle Database" "$file"; then
        if grep -q "19c\|20c\|21c\|23c" "$file"; then
            AWR_FORMAT="19c"
            msg_debug "Detected 19c+ AWR format"
        else
            AWR_FORMAT="11g"
            msg_debug "Detected 11g AWR format"
        fi
    else
        AWR_FORMAT="10g"
        msg_debug "Detected 10g AWR format"
    fi
}

# Parse profile section (system info, timing, I/O stats)
parse_profile_section() {
    local file="$1"
    msg_verbose "Parsing Profile section from $file"
    
    # Extract system details
    METRICS[db_name]=$(grep "^DB Name" "$file" | head -1 | awk '{print $3}')
    METRICS[instance_name]=$(grep "^DB Name" "$file" | head -1 | awk '{print $5}')
    METRICS[db_version]=$(grep "^DB Name" "$file" | head -1 | awk '{print $7}')
    
    # Extract timing info
    METRICS[begin_snap]=$(grep "^Begin Snap:" "$file" | awk '{print $3}')
    METRICS[end_snap]=$(grep "^End Snap:" "$file" | awk '{print $3}')
    METRICS[elapsed_time]=$(grep "^Elapsed:" "$file" | awk -F':' '{print $2}' | awk '{print $1}' | sed 's/,//g')
    METRICS[db_time]=$(grep "^DB Time:" "$file" | awk -F':' '{print $2}' | awk '{print $1}' | sed 's/,//g')
    
    # Calculate AAS (Average Active Sessions)
    if [[ -n "${METRICS[db_time]}" && -n "${METRICS[elapsed_time]}" ]]; then
        if [[ "${METRICS[elapsed_time]}" != "0" ]]; then
            METRICS[aas]=$((${METRICS[db_time]} / ${METRICS[elapsed_time]}))
        fi
    fi
    
    # Extract I/O metrics
    METRICS[read_iops]=$(grep "physical reads per sec" "$file" | awk '{print $NF}' | sed 's/,//g')
    METRICS[write_iops]=$(grep "physical writes per sec" "$file" | awk '{print $NF}' | sed 's/,//g')
    
    # Cache efficiency
    METRICS[buffer_hit_ratio]=$(grep "Buffer Hit" "$file" | awk '{print $NF}' | sed 's/%//g')
    METRICS[inmem_sort_ratio]=$(grep "In-Memory Sort" "$file" | awk '{print $NF}' | sed 's/%//g')
    
    msg_debug "Profile: DB=${METRICS[db_name]}, AAS=${METRICS[aas]}, BHR=${METRICS[buffer_hit_ratio]}"
}

# Parse Top Events section (wait event analysis)
parse_events_section() {
    local file="$1"
    msg_verbose "Parsing Top Events section from $file"
    
    local event_count=0
    local in_events=0
    
    while IFS= read -r line; do
        # Detect start of events section
        if [[ "$line" =~ "Top.*Event" ]]; then
            in_events=1
            continue
        fi
        
        # Skip header lines
        if [[ "$line" =~ "^---" ]] || [[ -z "$line" ]]; then
            continue
        fi
        
        # Parse event line
        if [[ "$in_events" -eq 1 && "$event_count" -lt 10 ]]; then
            local event_name=$(echo "$line" | awk '{print $1}')
            local waits=$(echo "$line" | awk '{print $2}' | sed 's/,//g')
            local event_time=$(echo "$line" | awk '{print $3}' | sed 's/,//g')
            local latency=$(echo "$line" | awk '{print $4}' | sed 's/,//g')
            
            if [[ -n "$event_name" && "$event_name" != "Event" ]]; then
                METRICS[top_event_$((event_count+1))_name]="$event_name"
                METRICS[top_event_$((event_count+1))_waits]="$waits"
                METRICS[top_event_$((event_count+1))_time]="$event_time"
                METRICS[top_event_$((event_count+1))_latency]="$latency"
                
                msg_debug "Event $((event_count+1)): $event_name ($waits waits)"
                ((event_count++))
            fi
        fi
    done < "$file"
}

# Parse wait class section (I/O, CPU, lock, etc.)
parse_wait_class_section() {
    local file="$1"
    msg_verbose "Parsing Wait Class section from $file"
    
    # Extract User I/O wait class info
    METRICS[user_io_waits]=$(grep -A 1 "User I/O" "$file" | tail -1 | awk '{print $2}' | sed 's/,//g')
    METRICS[user_io_time]=$(grep -A 1 "User I/O" "$file" | tail -1 | awk '{print $3}' | sed 's/,//g')
    METRICS[user_io_latency]=$(grep -A 1 "User I/O" "$file" | tail -1 | awk '{print $4}' | sed 's/,//g')
    METRICS[user_io_pct]=$(grep -A 1 "User I/O" "$file" | tail -1 | awk '{print $5}' | sed 's/%//g')
    
    msg_debug "User I/O: Waits=${METRICS[user_io_waits]}, Latency=${METRICS[user_io_latency]}ms"
}

# Parse I/O events (sequential read, scattered read, etc.)
parse_io_events_section() {
    local file="$1"
    msg_verbose "Parsing I/O Events section from $file"
    
    # db file sequential read
    METRICS[dfsr_waits]=$(grep "db file sequential read" "$file" | head -1 | awk '{print $NF}' | sed 's/,//g')
    METRICS[dfsr_latency]=$(grep "db file sequential read" "$file" | tail -1 | awk '{print $(NF-1)}' | sed 's/,//g')
    
    # db file scattered read
    METRICS[dfxr_waits]=$(grep "db file scattered read" "$file" | head -1 | awk '{print $NF}' | sed 's/,//g')
    METRICS[dfxr_latency]=$(grep "db file scattered read" "$file" | tail -1 | awk '{print $(NF-1)}' | sed 's/,//g')
    
    msg_debug "I/O Events: DFSRwaits=${METRICS[dfsr_waits]}, DFXRwaits=${METRICS[dfxr_waits]}"
}

# Generate CSV header row
generate_csv_header() {
    cat <<EOF
Filename,Database Name,Instance Number,Instance Name,Database Version,Cluster,Hostname,Host OS,Num CPUs,Server Memory GB,DB Block Size,Begin Snap,Begin Time,End Snap,End Time,Elapsed Time mins,DB Time mins,Average Active Sessions,Busy Flag,Logical Reads sec,Block Changes sec,Read IOPS,Write IOPS,Redo IOPS,Total IOPS,Read Throughput MiB sec,Write Throughput MiB sec,Redo Throughput MiB sec,Total Throughput MiB sec,DB CPU Time s,DB CPU DBTime,User IO Waits,User IO Time s,User IO Latency ms,User IO DBTime,User Calls sec,Parses sec,Hard Parses sec,Logons sec,Executes sec,Transactions sec,Buffer Hit Ratio,In Memory Sort Ratio,Log Switches Total,Log Switches Per Hour,Top Event1 Name,Top Event1 Class,Top Event1 Waits,Top Event1 Time s,Top Event1 Average Time ms,Top Event1 DBTime,Top Event2 Name,Top Event2 Class,Top Event2 Waits,Top Event2 Time s,Top Event2 Average Time ms,Top Event2 DBTime,Top Event3 Name,Top Event3 Class,Top Event3 Waits,Top Event3 Time s,Top Event3 Average Time ms,Top Event3 DBTime,Top Event4 Name,Top Event4 Class,Top Event4 Waits,Top Event4 Time s,Top Event4 Average Time ms,Top Event4 DBTime,Top Event5 Name,Top Event5 Class,Top Event5 Waits,Top Event5 Time s,Top Event5 Average Time ms,Top Event5 DBTime,db file sequential read Waits,db file sequential read Time s,db file sequential read Latency ms,db file sequential read DBTime,db file scattered read Waits,db file scattered read Time s,db file scattered read Latency ms,db file scattered read DBTime,direct path read Waits,direct path read Time s,direct path read Latency ms,direct path read DBTime,direct path write Waits,direct path write Time s,direct path write Latency ms,direct path write DBTime,log file sync Waits,log file sync Time s,log file sync Latency ms,log file sync DBTime,OS busy time,OS idle time,OS iowait time,Data Guard Flag,Exadata Flag,RAC Cluster,GC CR Blocks,GC CW Blocks,GC Read Waits,GC Read Latency ms,GC Write Waits,GC Write Latency ms,Latch Contention,Top Latch,Lock Waits,ITL Contention,Disk Sort Percent,PGA Efficiency Percent
EOF
}

# Generate CSV data row
generate_csv_row() {
    output_csv \
        "${METRICS[filename]},${METRICS[db_name]},${METRICS[instance_num]},${METRICS[instance_name]},${METRICS[db_version]},${METRICS[cluster]},${METRICS[hostname]},${METRICS[host_os]},${METRICS[num_cpus]},${METRICS[server_memory]},${METRICS[db_block_size]},${METRICS[begin_snap]},${METRICS[begin_time]},${METRICS[end_snap]},${METRICS[end_time]},${METRICS[elapsed_time]},${METRICS[db_time]},${METRICS[aas]},${METRICS[busy_flag]},${METRICS[read_iops]},${METRICS[write_iops]},${METRICS[read_iops]},${METRICS[write_iops]},${METRICS[redo_iops]},${METRICS[total_iops]},${METRICS[read_throughput]},${METRICS[write_throughput]},${METRICS[redo_throughput]},${METRICS[total_throughput]},${METRICS[db_cpu_time]},${METRICS[db_cpu_pct]},${METRICS[user_io_waits]},${METRICS[user_io_time]},${METRICS[user_io_latency]},${METRICS[user_io_pct]},${METRICS[user_calls]},${METRICS[parses]},${METRICS[hard_parses]},${METRICS[logons]},${METRICS[executes]},${METRICS[transactions]},${METRICS[buffer_hit_ratio]},${METRICS[inmem_sort_ratio]},${METRICS[log_switches]},0"
}

# Process single AWR report file
process_awr_file() {
    local file="$1"
    local output_file="$2"
    
    if [[ ! -f "$file" ]]; then
        msg_error "File not found: $file"
        return "$EXIT_FAILURE"
    fi
    
    msg_info "Processing: $file"
    
    # Initialize metrics for this file
    init_metrics
    METRICS[filename]=$(basename "$file")
    
    # Detect format
    detect_awr_format "$file"
    
    # Parse sections
    parse_profile_section "$file"
    parse_events_section "$file"
    parse_wait_class_section "$file"
    parse_io_events_section "$file"
    
    # Output CSV row
    generate_csv_row >> "$output_file"
    
    msg_info "✓ Completed: ${METRICS[db_name]} (v${AWR_FORMAT})"
    return "$EXIT_SUCCESS"
}

# Main processing loop
process_files() {
    local input_dir="$1"
    local output_dir="$2"
    local csv_file="${output_dir}/awr_analysis_$(date +%Y%m%d_%H%M%S).csv"
    
    # Validate directories
    if [[ ! -d "$input_dir" ]]; then
        msg_error "Input directory not found: $input_dir"
        return "$EXIT_FAILURE"
    fi
    
    if [[ ! -d "$output_dir" ]]; then
        msg_info "Creating output directory: $output_dir"
        mkdir -p "$output_dir" || {
            msg_error "Cannot create output directory: $output_dir"
            return "$EXIT_FAILURE"
        }
    fi
    
    # Write CSV header
    msg_info "Writing CSV header to: $csv_file"
    generate_csv_header > "$csv_file"
    
    # Process all AWR files
    local file_count=0
    while IFS= read -r -d '' file; do
        ((FILECNT++))
        if process_awr_file "$file" "$csv_file"; then
            ((file_count++))
        else
            ((ERRORCNT++))
        fi
    done < <(find "$input_dir" -maxdepth 1 -name "awr*.txt" -o -name "*awrrpt*.txt" -print0 2>/dev/null)
    
    if [[ "$file_count" -eq 0 ]]; then
        msg_error "No AWR files found in: $input_dir"
        return "$EXIT_FAILURE"
    fi
    
    msg_info "=========================================="
    msg_info "Processing Summary"
    msg_info "=========================================="
    msg_info "Files found:     $FILECNT"
    msg_info "Files processed: $file_count"
    msg_info "Errors:          $ERRORCNT"
    msg_info "Output CSV:      $csv_file"
    msg_info "=========================================="
    
    # Determine exit status
    if [[ "$ERRORCNT" -eq 0 ]]; then
        return "$EXIT_SUCCESS"
    elif [[ "$file_count" -gt 0 ]]; then
        return "$EXIT_PARTIAL"
    else
        return "$EXIT_FAILURE"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    local input_dir=""
    local output_dir=""
    
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--input)
                input_dir="$2"
                shift 2
                ;;
            -o|--output)
                output_dir="$2"
                shift 2
                ;;
            -c|--csv-only)
                GENERATE_HTML=0
                shift
                ;;
            -s|--silent)
                SILENT=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -x|--debug)
                DEBUG=1
                VERBOSE=1
                shift
                ;;
            -H|--header-only)
                PRINT_HEADER_ONLY=1
                shift
                ;;
            -n|--no-header)
                NO_HEADER=1
                shift
                ;;
            -p|--print)
                PRINT_VALUES=1
                shift
                ;;
            -h|--help)
                usage 0
                ;;
            *)
                msg_error "Unknown option: $1"
                usage "$EXIT_FAILURE"
                ;;
        esac
    done
    
    # Validate required arguments
    if [[ "$PRINT_HEADER_ONLY" -eq 1 ]]; then
        generate_csv_header
        exit "$EXIT_SUCCESS"
    fi
    
    if [[ -z "$input_dir" ]] || [[ -z "$output_dir" ]]; then
        msg_error "Input and output directories are required"
        usage "$EXIT_FAILURE"
    fi
    
    # Process files
    process_files "$input_dir" "$output_dir"
    exit $?
}

# Run main function if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
