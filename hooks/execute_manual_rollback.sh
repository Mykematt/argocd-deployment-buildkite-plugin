#!/bin/bash

set -euo pipefail

# Manual rollback execution script
# Called from injected block step when user chooses to rollback

app_name="$1"
rollback_revision="$2"

DIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"

# shellcheck source=lib/plugin.bash
. "$DIR/../lib/plugin.bash"

echo "🔄 Executing manual rollback for $app_name to $rollback_revision"

# Create rollback log
log_file=$(create_deployment_log "$app_name" "manual_rollback" "in_progress")

# Get current (failed) revision
current_revision=$(get_current_revision "$app_name")

# Store rollback metadata
set_metadata "deployment:argocd:${app_name}:rollback_from" "$current_revision"
set_metadata "deployment:argocd:${app_name}:rollback_to" "$rollback_revision"
set_metadata "deployment:argocd:${app_name}:status" "rolling_back"

# Execute rollback
timeout=$(plugin_read_config TIMEOUT "300")

echo "⏪ Rolling back ArgoCD application..."
{
    echo "=== Manual Rollback Command Output ==="
    argocd app rollback "$app_name" "$rollback_revision" --timeout "$timeout" 2>&1
    echo "Exit code: $?"
} >> "$log_file"

if argocd app rollback "$app_name" "$rollback_revision" --timeout "$timeout"; then
    # Update metadata with success
    set_metadata "deployment:argocd:${app_name}:current_version" "$rollback_revision"
    set_metadata "deployment:argocd:${app_name}:result" "manual_rollback_success"
    set_metadata "deployment:argocd:${app_name}:status" "rolled_back"
    
    # Update log with success
    echo "=== Manual Rollback Result: SUCCESS ===" >> "$log_file"
    echo "Rolled back to revision: $rollback_revision" >> "$log_file"
    
    # Create rollback annotation
    create_rollback_annotation "$app_name" "$current_revision" "$rollback_revision"
    
    # Collect logs and upload artifacts
    handle_log_collection_and_artifacts "$app_name" "$log_file"
    
    # Send success notification
    send_rollback_notification "$app_name" "$current_revision" "$rollback_revision" "manual_rollback_success"
    
    echo "✅ Manual rollback successful"
    echo "   Failed:     $current_revision"
    echo "   Rolled to:  $rollback_revision"
else
    # Update metadata with failure
    set_metadata "deployment:argocd:${app_name}:result" "manual_rollback_failed"
    set_metadata "deployment:argocd:${app_name}:status" "rollback_failed"
    
    # Update log with failure
    echo "=== Manual Rollback Result: FAILED ===" >> "$log_file"
    
    # Collect logs and upload artifacts even on failure
    handle_log_collection_and_artifacts "$app_name" "$log_file"
    
    # Send failure notification
    send_rollback_notification "$app_name" "$current_revision" "$rollback_revision" "manual_rollback_failed"
    
    echo "❌ Manual rollback failed"
    exit 1
fi
