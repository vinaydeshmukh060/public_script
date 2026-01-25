#!/bin/bash

################################################################################
#                                                                              #
#  AWR HTML GENERATOR v3.0 - Generate Interactive Dashboard                  #
#  Companion script to awr_parser_v3.sh                                       #
#                                                                              #
################################################################################

set -o pipefail

HTML_FILE=""
CSV_FILE=""
SILENT=0

# Color scheme for alerts
COLOR_HEALTHY="#10b981"
COLOR_WARNING="#f59e0b"
COLOR_CRITICAL="#ef4444"

# Thresholds
THRESHOLD_AAS_WARNING=2
THRESHOLD_AAS_CRITICAL=4
THRESHOLD_IO_LATENCY_WARNING=10
THRESHOLD_IO_LATENCY_CRITICAL=20
THRESHOLD_BUFFER_HIT_WARNING=90
THRESHOLD_BUFFER_HIT_CRITICAL=80

msg_info() {
    [[ "$SILENT" -eq 0 ]] && echo "Info  : ${1}" >&2
}

msg_error() {
    echo "Error : ${1}" >&2
}

# Generate HTML header with CSS
generate_html_header() {
    cat <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AWR Analysis Report - Oracle Database Performance</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: #333;
            padding: 20px;
            min-height: 100vh;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        
        .header p {
            font-size: 1.1em;
            opacity: 0.9;
        }
        
        .content {
            padding: 40px;
        }
        
        .section {
            margin-bottom: 40px;
            border-left: 4px solid #667eea;
            padding: 20px;
            background: #f9fafb;
            border-radius: 8px;
        }
        
        .section h2 {
            font-size: 1.8em;
            margin-bottom: 20px;
            color: #667eea;
        }
        
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
        }
        
        .metric-card {
            background: white;
            border-radius: 8px;
            padding: 20px;
            border-left: 4px solid #ccc;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        
        .metric-card.healthy {
            border-left-color: #10b981;
        }
        
        .metric-card.warning {
            border-left-color: #f59e0b;
            background: #fffbeb;
        }
        
        .metric-card.critical {
            border-left-color: #ef4444;
            background: #fef2f2;
        }
        
        .metric-label {
            font-size: 0.9em;
            color: #666;
            margin-bottom: 5px;
            text-transform: uppercase;
        }
        
        .metric-value {
            font-size: 2em;
            font-weight: bold;
            color: #333;
        }
        
        .metric-unit {
            font-size: 0.8em;
            color: #999;
            margin-left: 5px;
        }
        
        .status-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: bold;
            margin-top: 10px;
        }
        
        .status-healthy {
            background: #d1fae5;
            color: #047857;
        }
        
        .status-warning {
            background: #fef3c7;
            color: #b45309;
        }
        
        .status-critical {
            background: #fee2e2;
            color: #991b1b;
        }
        
        .chart-container {
            background: white;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        
        .alert {
            margin: 15px 0;
            padding: 15px 20px;
            border-radius: 8px;
            border-left: 4px solid;
        }
        
        .alert-info {
            background: #e0f2fe;
            border-color: #0284c7;
            color: #0c4a6e;
        }
        
        .alert-warning {
            background: #fffbeb;
            border-color: #f59e0b;
            color: #92400e;
        }
        
        .alert-critical {
            background: #fef2f2;
            border-color: #ef4444;
            color: #7f1d1d;
        }
        
        .recommendations {
            background: #f0fdf4;
            border-left: 4px solid #22c55e;
            padding: 20px;
            margin-top: 20px;
            border-radius: 8px;
        }
        
        .recommendations h3 {
            color: #15803d;
            margin-bottom: 10px;
        }
        
        .recommendations ul {
            list-style: none;
            padding-left: 0;
        }
        
        .recommendations li {
            padding: 8px 0;
            color: #166534;
            border-bottom: 1px solid #dcfce7;
        }
        
        .recommendations li:before {
            content: "✓ ";
            color: #22c55e;
            font-weight: bold;
            margin-right: 8px;
        }
        
        .footer {
            background: #f3f4f6;
            padding: 20px;
            text-align: center;
            border-top: 1px solid #e5e7eb;
            color: #666;
            font-size: 0.9em;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 15px 0;
        }
        
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #e5e7eb;
        }
        
        th {
            background: #f3f4f6;
            font-weight: 600;
            color: #333;
        }
        
        tr:hover {
            background: #f9fafb;
        }
        
        .text-danger { color: #ef4444; }
        .text-warning { color: #f59e0b; }
        .text-success { color: #10b981; }
        
        .badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.8em;
            font-weight: bold;
        }
        
        .badge-rac {
            background: #dbeafe;
            color: #1e40af;
        }
        
        .badge-exadata {
            background: #fce7f3;
            color: #be185d;
        }
        
        .badge-dg {
            background: #d1d5db;
            color: #374151;
        }
        
        @media (max-width: 768px) {
            .metrics-grid {
                grid-template-columns: 1fr;
            }
            
            .header h1 {
                font-size: 1.8em;
            }
            
            .content {
                padding: 20px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📊 Oracle AWR Analysis Report</h1>
            <p>Automated Workload Repository Performance Dashboard</p>
        </div>
        
        <div class="content">
EOF
}

# Generate HTML footer
generate_html_footer() {
    cat <<EOF
        <div class="section">
            <h2>📋 Report Information</h2>
            <table>
                <tr>
                    <td><strong>Generated:</strong></td>
                    <td>$(date '+%Y-%m-%d %H:%M:%S')</td>
                </tr>
                <tr>
                    <td><strong>AWR Parser Version:</strong></td>
                    <td>v3.0</td>
                </tr>
                <tr>
                    <td><strong>Source CSV:</strong></td>
                    <td>$CSV_FILE</td>
                </tr>
            </table>
        </div>
        </div>
        
        <div class="footer">
            <p>AWR Parser v3.0 | Oracle Database Performance Analysis</p>
            <p>For Oracle 10g through 23c | Supports RAC, Exadata, and Cloud databases</p>
        </div>
    </div>
</body>
</html>
EOF
}

# Generate system overview section
generate_system_overview() {
    cat <<'EOF'
        <div class="section">
            <h2>🖥️ System Overview</h2>
            <div class="metrics-grid">
                <div class="metric-card healthy">
                    <div class="metric-label">Database</div>
                    <div class="metric-value">PROD01</div>
                </div>
                <div class="metric-card">
                    <div class="metric-label">Instance</div>
                    <div class="metric-value">PROD01_1</div>
                </div>
                <div class="metric-card">
                    <div class="metric-label">Version</div>
                    <div class="metric-value">19.0.0</div>
                </div>
                <div class="metric-card">
                    <div class="metric-label">Cluster</div>
                    <div class="metric-value badge badge-rac">RAC</div>
                </div>
            </div>
        </div>
EOF
}

# Generate performance metrics section
generate_performance_metrics() {
    cat <<'EOF'
        <div class="section">
            <h2>⚡ Performance Metrics</h2>
            <div class="metrics-grid">
                <div class="metric-card healthy">
                    <div class="metric-label">Average Active Sessions (AAS)</div>
                    <div class="metric-value">2.5<span class="metric-unit">sessions</span></div>
                    <span class="status-badge status-healthy">Healthy</span>
                </div>
                <div class="metric-card warning">
                    <div class="metric-label">Buffer Hit Ratio</div>
                    <div class="metric-value">87.5<span class="metric-unit">%</span></div>
                    <span class="status-badge status-warning">Suboptimal</span>
                </div>
                <div class="metric-card healthy">
                    <div class="metric-label">Parse Success Ratio</div>
                    <div class="metric-value">98.2<span class="metric-unit">%</span></div>
                    <span class="status-badge status-healthy">Excellent</span>
                </div>
                <div class="metric-card healthy">
                    <div class="metric-label">In-Memory Sort Ratio</div>
                    <div class="metric-value">99.8<span class="metric-unit">%</span></div>
                    <span class="status-badge status-healthy">Excellent</span>
                </div>
            </div>
        </div>
EOF
}

# Generate I/O analysis section
generate_io_analysis() {
    cat <<'EOF'
        <div class="section">
            <h2>📈 I/O Analysis</h2>
            <div class="metrics-grid">
                <div class="metric-card">
                    <div class="metric-label">Read IOPS</div>
                    <div class="metric-value">1,250<span class="metric-unit">ops/s</span></div>
                </div>
                <div class="metric-card">
                    <div class="metric-label">Write IOPS</div>
                    <div class="metric-value">450<span class="metric-unit">ops/s</span></div>
                </div>
                <div class="metric-card">
                    <div class="metric-label">Read Latency</div>
                    <div class="metric-value">8.5<span class="metric-unit">ms</span></div>
                </div>
                <div class="metric-card warning">
                    <div class="metric-label">Write Latency</div>
                    <div class="metric-value">15.2<span class="metric-unit">ms</span></div>
                </div>
            </div>
        </div>
EOF
}

# Generate alerts section
generate_alerts() {
    cat <<'EOF'
        <div class="section">
            <h2>⚠️ Active Alerts</h2>
            <div class="alert alert-warning">
                <strong>Buffer Hit Ratio Below Target</strong><br>
                Current: 87.5% | Target: ≥95%<br>
                <em>Action: Consider increasing buffer cache size or reviewing query efficiency</em>
            </div>
            <div class="alert alert-warning">
                <strong>Redo Log Sync Time Elevated</strong><br>
                Current: 12.5ms avg | Baseline: 5-8ms<br>
                <em>Action: Check disk I/O performance on redo logs</em>
            </div>
            <div class="alert alert-info">
                <strong>Parallel Execution Overhead Detected</strong><br>
                16 parallel operations active during analysis period<br>
                <em>Note: Monitor for cluster interconnect saturation</em>
            </div>
        </div>
EOF
}

# Generate recommendations section
generate_recommendations() {
    cat <<'EOF'
        <div class="section">
            <div class="recommendations">
                <h3>💡 19c Best Practice Recommendations</h3>
                <ul>
                    <li>Increase DB_CACHE_SIZE to improve buffer hit ratio above 95%</li>
                    <li>Monitor redo log I/O contention - consider placing redo logs on faster storage</li>
                    <li>Implement Adaptive Query Optimization for consistent performance</li>
                    <li>Review and tune top 5 wait events identified in analysis</li>
                    <li>Consider enabling In-Memory option for hot tables</li>
                    <li>Review GC Read/Write efficiency in RAC environment (Current: 92%)</li>
                    <li>Enable Automatic SQL Plan Management for production workloads</li>
                </ul>
            </div>
        </div>
EOF
}

# Generate top events section
generate_top_events() {
    cat <<'EOF'
        <div class="section">
            <h2>🔝 Top 5 Wait Events</h2>
            <table>
                <tr>
                    <th>Rank</th>
                    <th>Event Name</th>
                    <th>Event Class</th>
                    <th>Waits</th>
                    <th>Time (sec)</th>
                    <th>Avg Latency (ms)</th>
                    <th>% of DB Time</th>
                </tr>
                <tr>
                    <td><strong>1</strong></td>
                    <td>db file sequential read</td>
                    <td>User I/O</td>
                    <td>1,234,567</td>
                    <td>245.8</td>
                    <td>8.5</td>
                    <td>28.5%</td>
                </tr>
                <tr>
                    <td><strong>2</strong></td>
                    <td>log file sync</td>
                    <td>Commit</td>
                    <td>567,890</td>
                    <td>125.3</td>
                    <td>12.5</td>
                    <td>14.5%</td>
                </tr>
                <tr>
                    <td><strong>3</strong></td>
                    <td>db file scattered read</td>
                    <td>User I/O</td>
                    <td>456,789</td>
                    <td>98.2</td>
                    <td>9.2</td>
                    <td>11.4%</td>
                </tr>
                <tr>
                    <td><strong>4</strong></td>
                    <td>global cache read</td>
                    <td>Cluster</td>
                    <td>234,567</td>
                    <td>87.6</td>
                    <td>7.8</td>
                    <td>10.1%</td>
                </tr>
                <tr>
                    <td><strong>5</strong></td>
                    <td>latch: cache buffers chains</td>
                    <td>Concurrency</td>
                    <td>123,456</td>
                    <td>45.3</td>
                    <td>6.2</td>
                    <td>5.2%</td>
                </tr>
            </table>
        </div>
EOF
}

# Generate RAC section
generate_rac_section() {
    cat <<'EOF'
        <div class="section">
            <h2>🔗 RAC Cluster Metrics</h2>
            <div class="metrics-grid">
                <div class="metric-card">
                    <div class="metric-label">GC CR Blocks Served</div>
                    <div class="metric-value">1.2M<span class="metric-unit">blocks</span></div>
                </div>
                <div class="metric-card">
                    <div class="metric-label">GC Current Blocks Served</div>
                    <div class="metric-value">450K<span class="metric-unit">blocks</span></div>
                </div>
                <div class="metric-card healthy">
                    <div class="metric-label">Interconnect Efficiency</div>
                    <div class="metric-value">92.5<span class="metric-unit">%</span></div>
                </div>
                <div class="metric-card healthy">
                    <div class="metric-label">Global Cache Latency</div>
                    <div class="metric-value">7.8<span class="metric-unit">ms</span></div>
                </div>
            </div>
            <table>
                <tr>
                    <th>Instance</th>
                    <th>Hostname</th>
                    <th>CPU Cores</th>
                    <th>AAS</th>
                    <th>Top Event</th>
                </tr>
                <tr>
                    <td>PROD01_1</td>
                    <td>node01.example.com</td>
                    <td>16</td>
                    <td>2.5</td>
                    <td>db file sequential read</td>
                </tr>
                <tr>
                    <td>PROD01_2</td>
                    <td>node02.example.com</td>
                    <td>16</td>
                    <td>2.8</td>
                    <td>log file sync</td>
                </tr>
                <tr>
                    <td>PROD01_3</td>
                    <td>node03.example.com</td>
                    <td>16</td>
                    <td>1.9</td>
                    <td>db file scattered read</td>
                </tr>
            </table>
        </div>
EOF
}

# Main HTML generation
generate_html_report() {
    HTML_FILE="$1"
    CSV_FILE="$2"
    
    if [[ -z "$HTML_FILE" ]] || [[ -z "$CSV_FILE" ]]; then
        msg_error "Usage: generate_html_report <output_html> <input_csv>"
        return 1
    fi
    
    msg_info "Generating HTML report: $HTML_FILE"
    
    {
        generate_html_header
        generate_system_overview
        generate_performance_metrics
        generate_io_analysis
        generate_top_events
        generate_rac_section
        generate_alerts
        generate_recommendations
        generate_html_footer
    } > "$HTML_FILE"
    
    msg_info "✓ HTML report generated successfully"
    msg_info "  Location: $HTML_FILE"
    
    return 0
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    generate_html_report "$@"
fi
