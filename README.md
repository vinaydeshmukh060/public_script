# RMAN Backup Solution - Installation and Usage Guide

## Overview

This production-ready RMAN backup solution consists of two main components:
- `rman_backup.sh` - Main executable shell script (POSIX-compatible)
- `rman_backup.conf` - Configuration file with environment-specific settings

## Quick Start

### 1. Installation

```bash
# Copy files to your Oracle scripts directory
cp rman_backup.sh /opt/oracle/scripts/
cp rman_backup.conf /opt/oracle/scripts/

# Make script executable
chmod 755 /opt/oracle/scripts/rman_backup.sh

# Edit configuration for your environment
vi /opt/oracle/scripts/rman_backup.conf
```

### 2. Configuration

Edit `rman_backup.conf` and update these critical settings:

```bash
# Primary settings to customize
BASE_DIR="/your/backup/filesystem"     # Must have sufficient space
CHANNELS=3                             # Adjust based on I/O capacity
RETENTION_DAYS=7                       # Your backup retention policy
LOG_DIR="/your/log/directory"          # For backup logs
```

### 3. Test Installation

```bash
# Test with dry run (generates RMAN script but doesn't execute)
./rman_backup.sh -i TESTDB -t L0 -d -v

# Verify configuration and environment
./rman_backup.sh -h
```

## Usage Examples

### Basic Usage
```bash
# Level 0 backup with compression
./rman_backup.sh -i PRODDB -t L0 -c Y

# Level 1 incremental backup
./rman_backup.sh -i PRODDB -t L1

# Archive log backup only
./rman_backup.sh -i PRODDB -t Arch

# Dry run to test configuration
./rman_backup.sh -i PRODDB -t L0 -d -v
```

### Production Scheduling (crontab)

```bash
# Edit oracle user's crontab
crontab -e

# Add backup schedule
# Level 0 backup: Sunday 2:00 AM
0 2 * * 0 /opt/oracle/scripts/rman_backup.sh -i PRODDB -t L0 -c Y >/dev/null 2>&1

# Level 1 backup: Monday-Saturday 2:00 AM  
0 2 * * 1-6 /opt/oracle/scripts/rman_backup.sh -i PRODDB -t L1 -c Y >/dev/null 2>&1

# Archive backup: Every 6 hours
0 */6 * * * /opt/oracle/scripts/rman_backup.sh -i PRODDB -t Arch >/dev/null 2>&1

# Multiple instances
0 3 * * 0 /opt/oracle/scripts/rman_backup.sh -i TESTDB -t L0 -c Y >/dev/null 2>&1
0 4 * * 0 /opt/oracle/scripts/rman_backup.sh -i DEVDB -t L0 -c Y >/dev/null 2>&1
```

## Generated Log Files

For each backup run, the following log files are created:

```bash
# Main backup log (RMAN output)
${LOG_DIR}/${INSTANCE}_${TYPE}_${TIMESTAMP}.log
# Example: /backup/logs/PRODDB_L0_20240930_143022.log

# Error analysis log (parsed errors with remediation)
${ERROR_LOG_DIR}/${INSTANCE}_${TYPE}_${TIMESTAMP}.err  
# Example: /backup/logs/errors/PRODDB_L0_20240930_143022.err

# Retention cleanup log
${LOG_DIR}/${INSTANCE}_retention_${TIMESTAMP}.log
# Example: /backup/logs/PRODDB_retention_20240930_143022.log
```

## Directory Structure Created

```
/backup/rman/                    # BASE_DIR
├── L0/                         # Level 0 backups
│   ├── 30-Sep-2024/           # Date-based subdirectories
│   │   ├── L0_PRODDB_*.bkp    # Database backup pieces
│   │   ├── spfile_*.bkp       # SPFILE backup
│   │   └── controlfile_*.bkp  # Control file backup
│   └── 01-Oct-2024/
├── L1/                         # Level 1 incremental backups
│   └── 01-Oct-2024/
└── Arch/                       # Archive log backups
    └── 01-Oct-2024/

/backup/logs/                   # LOG_DIR
├── PRODDB_L0_20240930_143022.log
├── PRODDB_L1_20241001_020015.log
└── errors/                     # ERROR_LOG_DIR
    ├── PRODDB_L0_20240930_143022.err
    └── PRODDB_L1_20241001_020015.err

/tmp/rman/                      # TMP_DIR
└── PRODDB_L0_20240930_143022.rman  # Generated RMAN scripts
```

## Error Handling and Monitoring

### Exit Codes
- `0` = Success
- `1` = Invalid arguments  
- `2` = Instance not running
- `3` = Database role not PRIMARY
- `4` = Backup error
- `5` = Retention cleanup error
- `6` = Configuration error
- `7` = Environment setup error

### Error Mapping
The script includes built-in error mapping for common RMAN and Oracle errors:

```bash
# Examples of mapped errors:
RMAN-03009 → "failure to allocate channel" → "Check disk space/permissions"
ORA-19511  → "error during archiving" → "Check archiver process and destination"
ORA-00257  → "archiver error" → "Check archivelog destination space"
```

### Monitoring Backup Status
```bash
# Check last backup status
echo $?  # After running script

# Monitor real-time backup progress
tail -f /backup/logs/PRODDB_L0_$(date +%Y%m%d)*.log

# Check for errors in last backup
cat /backup/logs/errors/PRODDB_L0_$(date +%Y%m%d)*.err

# List recent backups
ls -la /backup/rman/L0/$(date +%d-%b-%Y)/
```

## Validation and Testing

### Pre-Production Testing

1. **Dry Run Test**
   ```bash
   ./rman_backup.sh -i TESTDB -t L0 -d -v
   ```

2. **Small Database Test**
   ```bash
   # Run actual backup on test instance
   ./rman_backup.sh -i TESTDB -t L0 -c Y
   
   # Verify backup integrity
   rman target / << EOF
   VALIDATE BACKUPSET tag='LEVEL0_$(date +%Y%m%d)%';
   EOF
   ```

3. **Error Simulation Test**
   ```bash
   # Simulate disk full error
   dd if=/dev/zero of=/backup/rman/fillspace bs=1M count=1000
   ./rman_backup.sh -i TESTDB -t L0
   rm /backup/rman/fillspace
   
   # Check error detection worked
   cat /backup/logs/errors/TESTDB_L0_*.err
   ```

### Performance Validation

```bash
# Monitor backup duration
time ./rman_backup.sh -i PRODDB -t L0 -c Y

# Check I/O patterns during backup
iostat -x 5

# Verify parallel channel utilization
grep -i "channel" /backup/logs/PRODDB_L0_*.log
```

## Troubleshooting

### Common Issues

1. **Permission Errors**
   ```bash
   # Ensure Oracle user owns script and directories
   chown -R oracle:oinstall /opt/oracle/scripts/
   chown -R oracle:oinstall /backup/
   ```

2. **Environment Issues**
   ```bash
   # Verify oratab entry
   grep PRODDB /etc/oratab
   
   # Test Oracle environment
   su - oracle -c "export ORACLE_SID=PRODDB; sqlplus / as sysdba"
   ```

3. **Space Issues**
   ```bash
   # Check backup filesystem space
   df -h /backup/
   
   # Clean up old backups manually if needed
   rman target / << EOF
   DELETE NOPROMPT OBSOLETE;
   EOF
   ```

### Log Analysis

```bash
# Find all errors in backup logs
grep -r "RMAN-\|ORA-" /backup/logs/

# Check backup completion status
grep -i "recover\|complet\|error" /backup/logs/PRODDB_L0_*.log

# Analyze backup performance
grep -i "elapsed\|rate" /backup/logs/PRODDB_L0_*.log
```

## Maintenance

### Regular Tasks

1. **Monitor Disk Space**
   ```bash
   df -h /backup/
   ```

2. **Review Error Logs Weekly**
   ```bash
   find /backup/logs/errors -name "*.err" -mtime -7 -exec cat {} \;
   ```

3. **Validate Backup Integrity Monthly**
   ```bash
   rman target / << EOF
   VALIDATE DATABASE;
   EOF
   ```

4. **Update Error Mapping**
   - Review Oracle documentation for new error codes
   - Add mappings to the ERROR_MAP section in the script
   - Test error detection with new codes

### Expansion and Customization

1. **Adding New Error Codes**
   ```bash
   # Edit the load_error_map() function in rman_backup.sh
   # Add new lines in format: ERROR_CODE|SHORT_MESSAGE|REMEDY
   ORA-19999|new error description|recommended remedy action
   ```

2. **Multiple Database Support**
   ```bash
   # Create wrapper script for multiple databases
   for db in PROD1 PROD2 PROD3; do
       /opt/oracle/scripts/rman_backup.sh -i $db -t L1 -c Y
   done
   ```

3. **Integration with Monitoring Systems**
   ```bash
   # Example Nagios check
   if [ $? -eq 0 ]; then
       echo "OK - RMAN backup completed successfully"
       exit 0
   else
       echo "CRITICAL - RMAN backup failed"
       exit 2
   fi
   ```

## Security Considerations

1. **File Permissions**
   ```bash
   chmod 750 /opt/oracle/scripts/rman_backup.sh
   chmod 640 /opt/oracle/scripts/rman_backup.conf
   ```

2. **Oracle Wallet Configuration** (optional)
   ```bash
   # Create wallet for secure connections
   mkstore -wrl /opt/oracle/admin/wallet -create
   mkstore -wrl /opt/oracle/admin/wallet -createCredential target sys password
   ```

3. **Backup Encryption**
   ```bash
   # Add to rman_backup.conf for encrypted backups
   ENCRYPTION_ALGORITHM="AES256"
   ENCRYPTION_MODE="TRANSPARENT"
   ```

## Support and Documentation

- Oracle RMAN Documentation: https://docs.oracle.com/database/121/BRADV/
- Oracle Error Messages: https://docs.oracle.com/error-help/
- Script Version: Check header of rman_backup.sh
- Configuration Reference: See comments in rman_backup.conf

For additional error codes and mappings, refer to:
- Oracle Database Error Messages Reference
- Oracle Database Backup and Recovery User's Guide
- My Oracle Support (MOS) knowledge base