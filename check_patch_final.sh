#!/bin/bash

PATCH_NUMBER="29585399"

usage() {
  echo "Usage: $0 <DB_NAME>"
  echo "Check if patch $PATCH_NUMBER is applied for the given Oracle DB instance."
  echo
  echo "Options:"
  echo "  -h, --help    Show this help message and exit"
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  exit 0
fi

DB_NAME="$1"

if [ -z "$DB_NAME" ]; then
  usage
  exit 1
fi

# Check if instance is running
if ! ps -ef | grep -v grep | grep -q "ora_pmon_${DB_NAME}"; then
  echo "Instance $DB_NAME is NOT running. Exiting."
  exit 2
fi

# Determine OS type
OS_TYPE=$(uname)

# Set ORATAB location based on OS
if [ "$OS_TYPE" = "Linux" ]; then
  ORATAB_FILE="/etc/oratab"
elif [ "$OS_TYPE" = "SunOS" ]; then
  ORATAB_FILE="/var/opt/oracle/oratab"
else
  echo "Unsupported OS type: $OS_TYPE"
  exit 3
fi

# Check if instance is in oratab and get oracle_home
ORACLE_HOME=$(grep "^${DB_NAME}:" $ORATAB_FILE | head -1 | cut -d: -f2)

if [ -z "$ORACLE_HOME" ]; then
  echo "Instance $DB_NAME NOT found in $ORATAB_FILE. Exiting."
  exit 4
fi

echo "Oracle Home sourced for $DB_NAME: $ORACLE_HOME"

OPATCH="$ORACLE_HOME/OPatch/opatch"

if [ ! -x "$OPATCH" ]; then
  echo "opatch utility not found or not executable at $OPATCH"
  exit 5
fi

# Colors for output
GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

# Check for the patch number
PATCH_INFO=$($OPATCH lsinv | grep -i "$PATCH_NUMBER")

if [ -z "$PATCH_INFO" ]; then
  echo -e "${RED}Patch $PATCH_NUMBER NOT found in Oracle home: $ORACLE_HOME${RESET}"
  exit 6
else
  echo -e "${GREEN}Patch $PATCH_NUMBER FOUND in Oracle home: $ORACLE_HOME${RESET}"
  echo "$PATCH_INFO"
fi
