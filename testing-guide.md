# RMAN Backup Solution - Testing and Validation Guide

## Overview
This document provides comprehensive testing procedures for the RMAN backup solution consisting of `rman_backup.sh` and `rman_backup.conf`.

## Installation and Setup

### 1. File Permissions
```bash
# Make the script executable
chmod +x rman_backup.sh

# Verify permissions
ls -la rman_backup.sh rman_backup.conf
```

### 2. Configuration Setup
```bash
# Edit configuration file for your environment
vi rman_backup.conf

# Key settings to verify:
# - base_dir: Ensure sufficient space and proper permissions
# - oratab_path: Verify correct location of oratab file
# - rman_binary: Check RMAN executable path
# - channels: Adjust based on system resources
```

## Testing Procedures

### Phase 1: Basic Validation Tests

#### Test 1: Help and Usage Display
```bash
# Test help display
./rman_backup.sh -h

# Expected: Usage information and examples displayed
```

#### Test 2: Argument Validation
```bash
# Test missing required arguments
./rman_backup.sh

# Test invalid backup type
./rman_backup.sh -i TEST -t INVALID

# Test invalid compression value
./rman_backup.sh -i TEST -t L0 -c X

# Expected: Appropriate error messages for each invalid case
```

#### Test 3: Configuration File Validation
```bash
# Test missing configuration file
mv rman_backup.conf rman_backup.conf.bak
./rman_backup.sh -i TEST -t L0

# Restore configuration
mv rman_backup.conf.bak rman_backup.conf

# Expected: Error message about missing configuration file
```

### Phase 2: Environment Validation Tests

#### Test 4: Oracle Environment Setup
```bash
# Test with valid Oracle instance (dry run)
./rman_backup.sh -i ORCL -t L0 -d

# Expected: Environment setup messages and dry run output
```

#### Test 5: Instance and Role Validation
```bash
# Test with non-existent instance
./rman_backup.sh -i NONEXIST -t L0 -d

# Test with standby database (if available)
./rman_backup.sh -i STANDBY -t L0 -d

# Expected: Appropriate error messages for invalid instances/roles
```

### Phase 3: Dry Run Testing

#### Test 6: Full Backup Dry Run
```bash
# Level 0 backup with compression
./rman_backup.sh -i ORCL -t L0 -c Y -d

# Expected output should show:
# - Directory creation plans
# - RMAN script contents
# - Channel allocation details
# - Backup format with date substitution
```

#### Test 7: Incremental Backup Dry Run
```bash
# Level 1 backup without compression
./rman_backup.sh -i ORCL -t L1 -c N -d

# Expected: Different backup format and incremental level settings
```

#### Test 8: Archive Log Backup Dry Run
```bash
# Archive log only backup
./rman_backup.sh -i ORCL -t Arch -d

# Expected: Archive log specific RMAN commands
```

### Phase 4: Lock File Testing

#### Test 9: Concurrent Execution Prevention
```bash
# Start long-running dry run in background
./rman_backup.sh -i ORCL -t L0 -d &
FIRST_PID=$!

# Attempt second execution immediately
./rman_backup.sh -i ORCL -t L1

# Clean up
kill $FIRST_PID 2>/dev/null || true

# Expected: Second execution should fail with lock file error
```

### Phase 5: Actual Backup Testing (Non-Production)

#### Test 10: Small Database Backup
```bash
# Create test tablespace for backup testing
sqlplus / as sysdba <<EOF
CREATE TABLESPACE test_backup DATAFILE '/tmp/test_backup01.dbf' SIZE 10M;
EXIT;
EOF

# Execute actual Level 0 backup
./rman_backup.sh -i TESTDB -t L0 -c N

# Verify results
ls -la /backup/rman/L0/
ls -la /backup/rman/logs/

# Expected: Backup files created, log files generated
```

#### Test 11: Error Detection Testing
```bash
# Create scenario to trigger backup error (insufficient space)
# Fill up backup destination to trigger space error
dd if=/dev/zero of=/backup/rman/fillfile bs=1M count=1000 2>/dev/null

# Attempt backup (should fail)
./rman_backup.sh -i TESTDB -t L0

# Clean up
rm -f /backup/rman/fillfile

# Check error log for mapped errors
cat /backup/rman/logs/rman_errors_TESTDB_L0_*.log

# Expected: Error detection and mapping in error log
```

## Validation Checklist

### Configuration Validation
- [ ] All required configuration variables are set
- [ ] Directory paths are absolute and accessible
- [ ] RMAN binary path is correct
- [ ] Oracle environment variables can be determined from oratab

### Script Logic Validation
- [ ] Argument parsing works correctly for all combinations
- [ ] Configuration loading handles missing/invalid values
- [ ] Oracle environment setup succeeds
- [ ] Database role checking works (PRIMARY vs STANDBY)
- [ ] RMAN script generation includes correct commands
- [ ] Channel allocation matches configuration
- [ ] Backup format includes proper date substitution
- [ ] Error mapping table includes all documented codes
- [ ] Lock file prevents concurrent execution
- [ ] Cleanup function removes temporary files

### Backup Operation Validation
- [ ] Level 0 backup creates full backup files
- [ ] Level 1 backup creates incremental backup files
- [ ] Archive log backup processes only unbacked up logs
- [ ] Control file and spfile backups are included for L0/L1
- [ ] Compression setting is honored
- [ ] Channel configuration is applied correctly
- [ ] Backup files use configured naming format

### Error Handling Validation
- [ ] RMAN errors are detected in backup log
- [ ] Error codes are mapped to human-readable messages
- [ ] Suggested actions are provided for each error
- [ ] Unknown errors are flagged appropriately
- [ ] Exit codes match documented values
- [ ] Error log contains all relevant information

### Retention Policy Validation
- [ ] REPORT OBSOLETE shows correct obsolete backups
- [ ] DELETE OBSOLETE removes only obsolete backups
- [ ] Retention period matches configuration
- [ ] Retention errors are captured and logged

## Performance Testing

### Backup Performance Test
```bash
# Time a full backup
time ./rman_backup.sh -i PRODDB -t L0 -c Y

# Monitor system resources during backup
# - CPU usage
# - I/O wait
# - Disk space utilization
# - Memory usage
```

### Parallel Channel Testing
```bash
# Test with different channel counts
# Edit rman_backup.conf: channels=2
./rman_backup.sh -i TESTDB -t L0 -d | grep "ALLOCATE CHANNEL"

# Edit rman_backup.conf: channels=4  
./rman_backup.sh -i TESTDB -t L0 -d | grep "ALLOCATE CHANNEL"

# Verify correct number of channels allocated
```

## Error Scenario Testing

### Test Error Mapping
Create a test file with sample RMAN errors:
```bash
cat > /tmp/test_rman.log <<EOF
RMAN-03009: failure of backup command on ch1 channel at 10/03/2025 10:30:15
ORA-19505: failed to identify file "/backup/rman/test.bkp"
ORA-27037: unable to obtain file status
RMAN-06002: command completed at 10/03/2025 10:30:16
ORA-00257: archiver error. Connect internal only, until freed.
RMAN-99999: unknown error code for testing
EOF

# Test error parsing logic manually
grep -E "(ORA-[0-9]+|RMAN-[0-9]+)" /tmp/test_rman.log

# Expected: All error codes should be detected
```

## Production Readiness Checklist

### Security
- [ ] Script runs with appropriate user privileges
- [ ] Backup files have proper permissions
- [ ] No passwords or sensitive data in logs
- [ ] Configuration file has restricted permissions (600)

### Monitoring
- [ ] Log files are created in expected locations
- [ ] Error conditions are properly logged
- [ ] Backup completion can be verified from logs
- [ ] Performance metrics are available in logs

### Maintenance
- [ ] Old log files cleanup process defined
- [ ] Backup file cleanup follows retention policy
- [ ] Configuration changes are documented
- [ ] Recovery procedures are tested

### Integration
- [ ] Script can be called from cron or scheduler
- [ ] Exit codes enable proper error handling in automation
- [ ] Log format supports parsing by monitoring tools
- [ ] Backup verification procedures are defined

## Troubleshooting Guide

### Common Issues

1. **"Instance not found in oratab"**
   - Verify instance name spelling
   - Check oratab_path configuration
   - Ensure oratab file is readable

2. **"Database role is not PRIMARY"**
   - Verify database role: `SELECT DATABASE_ROLE FROM V$DATABASE;`
   - Use standby-specific backup procedures if needed

3. **"RMAN binary not found"**
   - Check rman_binary path in configuration
   - Verify Oracle environment setup
   - Ensure RMAN is installed and accessible

4. **"Failed to create directory"**
   - Check filesystem permissions
   - Verify available disk space
   - Ensure parent directories exist

5. **"Lock file conflict"**
   - Check for running backup processes
   - Remove stale lock files if necessary
   - Verify PID in lock file is active

### Log Analysis
```bash
# Check backup completion
grep "completed successfully" /backup/rman/logs/rman_backup_*.log

# Check for errors
grep "ERROR" /backup/rman/logs/rman_errors_*.log

# Review retention actions
grep "DELETE" /backup/rman/logs/rman_retention_*.log
```

This testing guide ensures comprehensive validation of the RMAN backup solution before production deployment.