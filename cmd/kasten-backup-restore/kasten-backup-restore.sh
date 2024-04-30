#!/bin/bash

# This file is part of the KubeVirt project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Copyright 2024 Red Hat, Inc.

DEFAULT_KASTEN_YAMLS_PATH="$(
    cd "$(dirname "$BASH_SOURCE[0]")"
    echo "$(pwd)"
)"
POLICY_YAML="$DEFAULT_KASTEN_YAMLS_PATH/policy.yaml"
BACKUP_ACTION_YAML="$DEFAULT_KASTEN_YAMLS_PATH/backupAction.yaml"
RESTORE_ACTION_YAML="$DEFAULT_KASTEN_YAMLS_PATH/restoreAction.yaml"

# Function to print usage
usage() {
  echo "Usage:"
  echo "$0 command NAME [command-options]"
  echo "Commands:"
  echo "  backup          Create backup"
  echo "    Options:"
  echo "      -n <namespace>             Namespace in which Kasten should operate"
  echo "      -i <include-namespaces>    Namespaces to include in the backup"
  echo "      -s <selector>              Label selector for resources to back up"
  echo "      -r <include-resources>     Resources to include in the backup"
  echo "      -l <snapshot-location>     Locations where volume snapshots should be stored"
  echo "      -v                         Verify backup completion"
  echo "  delete-backup   Delete backup"
  echo "    Options:"
  echo "      -n <namespace>             Namespace in which Kasten should operate"
  echo "  restore         Restore a backup"
  echo "    Options:"
  echo "      -n <namespace>             Namespace in which the backup resides"
  echo "      -f <from-backup>           Backup to restore from"
  echo "      -v                         Verify restore completion"
  exit 1
}

# Function to create backup
create_backup() {
  local backup_name=$1
  shift
  local namespace=""
  local include_ns=""
  local selector=""
  local include_resources=""
  local snapshot_location=""
  local verify=false

  # Parse command options
  while getopts "n:i:s:r:l:v" opt; do
    case $opt in
      n)
        namespace=$OPTARG
        ;;
      i)
        include_ns=$OPTARG
        ;;
      s)
        selector=$OPTARG
        ;;
      r)
        include_resources=$OPTARG
        ;;
      l)
        snapshot_location=$OPTARG
        ;;
      v)
        verify=true
        ;;
      \?)
        echo "Invalid option: -$OPTARG" >&2
        usage
        ;;
    esac
  done
  shift $((OPTIND -1))

  if [ -z "$backup_name" ]; then
    echo "Error: Backup name is required."
    usage
  fi

  # Check if YAML file exists
  if [ ! -f "$POLICY_YAML" ]; then
    echo "Error: YAML file '$POLICY_YAML' not found" >&2
    exit 1
  fi
  if [ ! -f "$BACKUP_ACTION_YAML" ]; then
    echo "Error: YAML file '$BACKUP_ACTION_YAML' not found" >&2
    exit 1
  fi

  policy=$(sed -e "s/{policy_name}/$backup_name/g" -e "s/{policy_ns}/$namespace/g" -e "s/{include-namespaces}/$include_ns/g" $POLICY_YAML)

  if [[ -n "$selector" || -n "$include_resources" ]]; then
    local backupParameters="\ \ \ \ backupParameters:\n\
      filters:\n\
        includeResources:"
    policy=$(echo "$policy" | sed "/action:\ backup/a $backupParameters")
  fi
  if [ -n "$selector" ]; then
    IFS='=' read -r key value <<< "$selector"
    selector_yaml="\ \ \ \ \ \ \ \ - matchExpressions:\n\
          - key: $key\n\
            operator: In\n\
            values:\n\
            - $value"
    policy=$(echo "$policy" | sed "/includeResources:/a $selector_yaml")
  fi
  if [ -n "$include_resources" ]; then
    resources=()
    IFS=',' read -ra resources <<< "$include_resources"
    for resource in "${resources[@]}"; do
      resource_yaml="\ \ \ \ \ \ \ \ - resource: $resource"
      policy=$(echo "$policy" | sed "/includeResources:/a $resource_yaml")
    done
  fi
  # Currently not supporting snapshot_location
  # if [ -n "$snapshot_location" ]; then
  #     # currenly
  # fi

  # Apply the modified YAML content using kubectl
  printf "Creating policy:\n%s\n" "$policy"
  echo "$policy" | kubectl apply -f -

  verify_policy_completion "$backup_name" "$namespace"

  local backup=$(sed -e "s/{backup_name}/$backup_name/g" -e "s/{policy_name}/$backup_name/g" -e "s/{backup_ns}/$namespace/g" -e "s/{include_ns}/$include_ns/g" $BACKUP_ACTION_YAML)
  printf "Creating backup:\n%s\n" "$backup"
  echo "$backup" | kubectl apply -f -

  if $verify; then
    verify_backup_completion "$backup_name" "$include_ns"
  fi
}

# Function to verify policy completion
verify_policy_completion() {
  local policy_name=$1
  local namespace=$2
  local timeout=60
  local elapsed_time=0
  echo "Verifying creation of policy $policy_name in namespace $namespace..."

  while [ "$elapsed_time" -lt "$timeout" ]; do
    status=$(kubectl get policy "$policy_name" -n "$namespace" -o jsonpath='{.status.validation}' 2>/dev/null)

    if [ "$status" = "Success" ]; then
      echo "Policy $policy_name creation succeeded!"
      return 0
    elif [ "$status" = "Failed" ]; then
      echo "Policy $policy_name creation failed!"
      exit 1
    fi

    echo "Waiting for policy $policy_name to reach 'Success' state..."
    sleep 5
    ((elapsed_time+=5))
  done

  echo "Failed to reach 'Success' state!"
  exit 1
}

# Function to verify backup completion
verify_backup_completion() {
  local backup_name=$1
  local namespace=$2
  local timeout=120
  local elapsed_time=0
  echo "Verifying creation of backup $backup_name in namespace $namespace..."

  while [ "$elapsed_time" -lt "$timeout" ]; do
    status=$(kubectl get backupaction "$backup_name" -n "$namespace" -o jsonpath='{.status.state}' 2>/dev/null)

    if [ "$status" = "Complete" ]; then
      echo "Backup $backup_name creation succeeded!"
      return 0
    elif [ "$status" = "Failed" ]; then
      error_cause=$(kubectl get backupaction "$backup_name" -n "$namespace" -o jsonpath='{.status.error.cause}' 2>/dev/null)
      echo "Backup $backup_name creation failed, error:\n $error_cause!"
      exit 1
    fi

    echo "Waiting for backup $backup_name to reach 'Complete' state, current state: $status..."
    sleep 5
    ((elapsed_time+=5))
  done

  echo "Failed to reach 'Complete' state!"
  exit 1
}

# Function to delete backup
delete_backup() {
  local backup_name=$1
  shift
  local namespace=""

  # Parse command options
  while getopts "n:" opt; do
    case $opt in
      n)
        namespace=$OPTARG
        ;;
      \?)
        echo "Invalid option: -$OPTARG" >&2
        usage
        ;;
    esac
  done
  shift $((OPTIND -1))

  if [ -z "$backup_name" ]; then
    echo "Error: Backup name is required."
    usage
  fi

  include_ns=$(kubectl get policy "$backup_name" -n "$namespace" -o jsonpath='{.spec.selector.matchExpressions[0].values[0]}' 2>/dev/null)
  restore_point_content=$(kubectl get restorepoint "$backup_name" -n "$include_ns" -o jsonpath='{.spec.restorePointContentRef.name}' 2>/dev/null)
  # Deleteing the restorepoint deletes the backupaction and restorpoint too
  kubectl delete RestorePointContent $restore_point_content
  kubectl delete policy $backup_name -n $namespace
}

# Function to restore backup
restore_backup() {
  local restore_name=$1
  shift
  local namespace=""
  local from_backup=""
  local verify=false

  # Parse command options
  while getopts "n:f:v" opt; do
    case $opt in
      n)
        namespace=$OPTARG
        ;;
      f)
        from_backup=$OPTARG
        ;;
      v)
        verify=true
        ;;
      \?)
        echo "Invalid option: -$OPTARG" >&2
        usage
        ;;
    esac
  done
  shift $((OPTIND -1))

  if [ -z "$restore_name" ]; then
    echo "Error: Restore name is required."
    usage
  fi

  if [ -z "$from_backup" ]; then
    echo "Error: Backup name to restore from is required."
    usage
  fi
  if [ ! -f "$RESTORE_ACTION_YAML" ]; then
    echo "Error: YAML file '$RESTORE_ACTION_YAML' not found" >&2
    exit 1
  fi

  include_ns=$(kubectl get policy "$from_backup" -n "$namespace" -o jsonpath='{.spec.selector.matchExpressions[0].values[0]}' 2>/dev/null)
  local restore=$(sed -e "s/{restore_name}/$restore_name/g" -e "s/{restore_ns}/$include_ns/g" -e "s/{restore_point}/$from_backup/g" $RESTORE_ACTION_YAML)
  printf "Creating restore:\n%s\n" "$restore"
  echo "$restore" | kubectl apply -f -

  if $verify; then
    verify_restore_completion "$restore_name" "$include_ns"
  fi
}

# Function to verify restore completion
verify_restore_completion() {
  local restore_name=$1
  local namespace=$2
  local timeout=120
  local elapsed_time=0
  echo "Verifying restore $restore_name in namespace $namespace..."

  while [ "$elapsed_time" -lt "$timeout" ]; do
    status=$(kubectl get restoreaction "$restore_name" -n "$namespace" -o jsonpath='{.status.state}' 2>/dev/null)

    if [ "$status" = "Complete" ]; then
      echo "Restore $restore_name succeeded!"
      return 0
    elif [ "$status" = "Failed" ]; then
      error_cause=$(kubectl get restoreaction "$restore_name" -n "$namespace" -o jsonpath='{.status.error.cause}' 2>/dev/null)
      echo "Restore $restore_name failed, error:\n $error_cause!"
      exit 1
    fi

    echo "Waiting for restore $restore_name to reach 'Complete' state, current state: $status..."
    sleep 5
    ((elapsed_time+=5))
  done

  echo "Failed to reach 'Complete' state!"
  exit 1
}

# Parse command
command=$1
shift

# Check if command is provided
if [ -z "$command" ]; then
  echo "Error: Command is required."
  usage
fi

# Switch on the command
case $command in
  "backup")
    create_backup "$@"
    ;;
  "delete-backup")
    delete_backup "$@"
    ;;
  "restore")
    restore_backup "$@"
    ;;
  "verify-backup")
    verify_backup_completion "$@"
    ;;
  "verify-restore")
    verify_backup_completion "$@"
    ;;
  *)
    echo "Invalid command: $command"
    usage
    ;;
esac

echo "Exiting..."
