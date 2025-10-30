#!/bin/bash

PATCH_NUMBER="29585399"

usage() {
  echo "Usage: $0 <DB_NAME>"
  echo "Check if patch $PATCH_NUMBER is applied for given DB on all cluster nodes where it's running."
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

# Determine OS type for oratab location
OS_TYPE=$(uname)
if [ "$OS_TYPE" = "Linux" ]; then
  ORATAB_FILE="/etc/oratab"
elif [ "$OS_TYPE" = "SunOS" ]; then
  ORATAB_FILE="/var/opt/oracle/oratab"
else
  echo "Unsupported OS: $OS_TYPE"
  exit 2
fi

# Find ASM instance running locally
ASM_INSTANCE=$(ps -ef | grep -v grep | grep ora_pmon_+ASM | awk '{print $NF}' | sed 's/ora_pmon_//')
if [ -z "$ASM_INSTANCE" ]; then
  echo "No ASM instance running on this node."
  exit 3
fi

# Get Oracle Home from oratab using ASM instance or +ASM entry
ORACLE_HOME=$(grep "^+ASM:" $ORATAB_FILE | head -1 | cut -d: -f2)
if [ -z "$ORACLE_HOME" ]; then
  ORACLE_HOME=$(grep "^${ASM_INSTANCE}:" $ORATAB_FILE | head -1 | cut -d: -f2)
fi

if [ -z "$ORACLE_HOME" ]; then
  echo "Oracle Home not found in oratab for ASM instance $ASM_INSTANCE"
  exit 4
fi

echo "ASM instance: $ASM_INSTANCE"
echo "Oracle Home for ASM: $ORACLE_HOME"

# Update PATH so olsnodes can run
export PATH=$ORACLE_HOME/bin:$PATH

# Get cluster nodes using olsnodes -n
NODES=$(olsnodes -n 2>/dev/null)
if [ -z "$NODES" ]; then
  echo "Cannot get cluster node list from olsnodes. Is Oracle Grid Infrastructure running and environment correct?"
  exit 5
fi

CURRENT_NODE=$(hostname -s)

# Function to run commands locally or remotely
run_cmd() {
  local NODE="$1"
  local CMD="$2"
  if [ "$NODE" = "$CURRENT_NODE" ]; then
    eval "$CMD"
  else
    ssh "$NODE" "$CMD"
  fi
}

# Check if instance is running on a given node
is_instance_running() {
  local NODE="$1"
  local INSTANCE="$2"
  run_cmd "$NODE" "ps -ef | grep -v grep | grep -q ora_pmon_${INSTANCE}"
}

# Get Oracle Home for DB from oratab on given node
get_oracle_home() {
  local NODE="$1"
  local DB="$2"
  run_cmd "$NODE" "grep ^${DB}: $ORATAB_FILE | head -1 | cut -d: -f2"
}

# Check patch status on a node for the DB instance
check_patch_on_node() {
  local NODE="$1"
  local DB="$2"

  echo "Checking node: $NODE for DB instance: $DB"

  if ! is_instance_running "$NODE" "$DB"; then
    echo "Instance $DB NOT running on node $NODE"
    return 1
  fi

  ORACLE_HOME=$(get_oracle_home "$NODE" "$DB")

  if [ -z "$ORACLE_HOME" ]; then
    echo "Oracle Home not found for $DB in oratab on node $NODE"
    return 1
  fi

  echo "Oracle Home sourced for DB $DB on node $NODE: $ORACLE_HOME"

  OPATCH="$ORACLE_HOME/OPatch/opatch"

  if ! run_cmd "$NODE" "[ -x $OPATCH ]"; then
    echo "opatch utility not found or not executable at $OPATCH on node $NODE"
    return 1
  fi

  PATCH_INFO=$(run_cmd "$NODE" "$OPATCH lsinv | grep -i $PATCH_NUMBER")

  GREEN="\e[32m"
  RED="\e[31m"
  RESET="\e[0m"

  if [ -z "$PATCH_INFO" ]; then
    echo -e "${RED}Patch $PATCH_NUMBER NOT found in Oracle home: $ORACLE_HOME on node $NODE${RESET}"
    return 1
  else
    echo -e "${GREEN}Patch $PATCH_NUMBER FOUND in Oracle home: $ORACLE_HOME on node $NODE${RESET}"
    echo "$PATCH_INFO"
  fi
}

# Find cluster nodes where DB instance is running
RUNNING_NODES=()

for node in $NODES; do
  if is_instance_running "$node" "$DB_NAME"; then
    RUNNING_NODES+=("$node")
  fi
done

if [ ${#RUNNING_NODES[@]} -eq 0 ]; then
  echo "Instance $DB_NAME is NOT running on any cluster node"
  exit 6
fi

# Check patch on all nodes where DB instance is running
for node in "${RUNNING_NODES[@]}"; do
  check_patch_on_node "$node" "$DB_NAME"
done

exit 0
