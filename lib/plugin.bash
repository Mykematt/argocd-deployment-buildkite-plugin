#!/bin/bash
set -e

PLUGIN_PREFIX="ARGOCD_DEPLOYMENT"

# Authentication functions
setup_argocd_auth() {
    local server
    local username
    local password
    
    # Get credentials from plugin config or environment variables
    server=$(plugin_read_config ARGOCD_SERVER "${ARGOCD_SERVER:-}")
    username=$(plugin_read_config ARGOCD_USERNAME "${ARGOCD_USERNAME:-}")
    password="${ARGOCD_PASSWORD:-}"
    
    # Validate required credentials
    if [[ -z "$server" ]]; then
        echo "❌ Error: ARGOCD_SERVER not configured"
        echo "   Set via plugin config or ARGOCD_SERVER environment variable"
        return 1
    fi
    
    if [[ -z "$username" ]]; then
        echo "❌ Error: ARGOCD_USERNAME not configured"
        echo "   Set via plugin config or ARGOCD_USERNAME environment variable"
        return 1
    fi
    
    if [[ -z "$password" ]]; then
        echo "❌ Error: ARGOCD_PASSWORD not available"
        echo "   Must be set as environment variable (use secret management)"
        return 1
    fi
    
    echo "🔐 Authenticating with ArgoCD server: $server"
    
    # Login to ArgoCD
    if ! argocd login "$server" --username "$username" --password "$password" --insecure; then
        echo "❌ Failed to authenticate with ArgoCD"
        return 1
    fi
    
    echo "✅ Successfully authenticated with ArgoCD"
}

validate_requirements() {
    echo "🔍 Validating requirements..."
    
    # Check for required commands
    local required_commands=("argocd" "jq" "curl")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "❌ Required command not found: $cmd"
            if [[ "$cmd" == "argocd" ]]; then
                echo "   Please install ArgoCD CLI on the Buildkite agent"
                echo "   Installation guide: https://argo-cd.readthedocs.io/en/stable/cli_installation/"
            fi
            return 1
        fi
    done
    
    # Show ArgoCD CLI version for debugging
    echo "✅ ArgoCD CLI found: $(argocd version --client --short 2>/dev/null || echo 'version unknown')"
    echo "✅ All requirements validated"
}

validate_config() {
    local app_name="$1"
    local mode="$2"
    local rollback_mode="$3"
    
    echo "🔍 Validating configuration..."
    
    # Validate application name
    if [[ -z "$app_name" ]]; then
        echo "❌ Error: APP is required"
        echo "   Specify the ArgoCD application name"
        return 1
    fi
    
    # Verify application exists in ArgoCD
    if ! argocd app get "$app_name" >/dev/null 2>&1; then
        echo "❌ Error: ArgoCD application '$app_name' not found"
        echo "   Verify the application name and ArgoCD access"
        return 1
    fi
    
    echo "✅ Configuration validated"
    echo "   Application: $app_name"
    echo "   Mode: $mode"
    echo "   Rollback Mode: $rollback_mode"
}

get_previous_stable_deployment() {
    local app_name="$1"
    
    echo "Getting previous stable deployment from ArgoCD history..." >&2
    
    # Get current stable deployment first
    local current_stable_id
    current_stable_id=$(get_current_stable_deployment "$app_name")
    
    if [[ "$current_stable_id" == "unknown" ]]; then
        echo "No current stable deployment found" >&2
        return 1
    fi
    
    echo "Current stable deployment: History ID $current_stable_id" >&2
    
    # Get deployment history and find the entry before current stable
    local previous_history_id=""
    local found_current=false
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^[0-9]+ ]]; then
            local line_id
            line_id=$(echo "$line" | awk '{print $1}')
            
            if [[ "$found_current" == "true" ]]; then
                # This is the entry after current (previous in chronological order)
                previous_history_id="$line_id"
                break
            fi
            
            if [[ "$line_id" == "$current_stable_id" ]]; then
                found_current=true
            fi
        fi
    done < <(argocd app history "$app_name" 2>/dev/null | tail -n +2)
    
    if [[ -n "$previous_history_id" ]]; then
        echo "Found previous stable deployment: History ID $previous_history_id" >&2
        echo "$previous_history_id"
        return 0
    else
        echo "No previous stable deployment found" >&2
        return 1
    fi
}

# Helper function to get the current stable deployment that's actually running
get_current_stable_deployment() {
    local app_name="$1"
    
    echo "🔍 Getting current stable deployment for $app_name..." >&2
    
    # Get the revision that's actually running in the cluster (from last successful operation)
    local current_revision_sha
    current_revision_sha=$(argocd app get "$app_name" -o json | jq -r '.status.operationState.syncResult.revision // empty' || echo "unknown")
    
    # Fallback to sync revision if operation state is not available
    if [[ -z "$current_revision_sha" || "$current_revision_sha" == "unknown" ]]; then
        current_revision_sha=$(argocd app get "$app_name" -o json | jq -r '.status.sync.revision // "unknown"')
    fi
    
    # Convert SHA to history ID
    if [[ "$current_revision_sha" != "unknown" ]]; then
        local short_sha="${current_revision_sha:0:7}"
        local history_id
        history_id=$(argocd app history "$app_name" | grep "$short_sha" | tail -1 | awk '{print $1}' || echo "unknown")
        echo "📍 Found stable deployment: SHA $short_sha → History ID $history_id" >&2
        echo "$history_id"
    else
        echo "unknown"
    fi
}

set_metadata() {
    local key="$1"
    local value="$2"
    buildkite-agent meta-data set "$key" "$value" || true
}

get_metadata() {
    local key="$1"
    buildkite-agent meta-data get "$key" 2>/dev/null || echo ""
}

# Smart helper function to lookup deployment history ID from git revision or validate history ID
lookup_deployment_history_id() {
    local app_name="$1"
    local target_revision="$2"
    
    echo "🔍 Processing target revision: $target_revision" >&2
    
    # Check if input looks like a History ID (numeric, typically 1-3 digits)
    if [[ "$target_revision" =~ ^[0-9]+$ ]] && [[ ${#target_revision} -le 4 ]]; then
        echo "📋 Input appears to be a History ID: $target_revision" >&2
        
        # Validate that this History ID exists in the deployment history
        local history_output
        if ! history_output=$(argocd app history "$app_name" 2>/dev/null); then
            echo "❌ Failed to get deployment history for app: $app_name" >&2
            return 1
        fi
        
        # Check if the History ID exists (look for exact match in first column)
        if echo "$history_output" | awk -v id="$target_revision" 'NR > 1 && $1 == id {found=1} END {exit !found}'; then
            echo "✅ History ID $target_revision found in deployment history" >&2
            echo "$target_revision"
            return 0
        else
            echo "❌ History ID $target_revision not found in deployment history" >&2
            echo "Available History IDs:" >&2
            echo "$history_output" | awk 'NR > 1 {print "  - " $1}' >&2
            return 1
        fi
    else
        echo "🔍 Input appears to be a commit SHA: $target_revision" >&2
        
        # Original logic for commit SHA lookup
        local short_hash="${target_revision:0:7}"
        local history_id
        history_id=$(argocd app history "$app_name" | grep "$short_hash" | tail -1 | awk '{print $1}' || echo "")
        
        if [[ -z "$history_id" ]]; then
            echo "❌ Could not find deployment history ID for commit SHA: $target_revision (short: $short_hash)" >&2
            echo "Available deployments:" >&2
            argocd app history "$app_name" | head -10 >&2 || true
            return 1
        fi
        
        echo "📍 Found deployment history ID: $history_id for commit SHA: $target_revision" >&2
        echo "$history_id"
        return 0
    fi
}

# Log collection and artifact functions
collect_app_logs() {
    local app_name="$1"
    
    # Create temp directory and output its path to stdout
    local log_dir
    log_dir=$(mktemp -d)
    echo "$log_dir"  # This is the only output to stdout
    
    # All status messages go to stderr
    echo "📍 Log directory: $log_dir" >&2
    
    # Create logs directory
    mkdir -p "$log_dir/pod_logs"
    
    # Collect ArgoCD application logs
    {
        echo "=== ArgoCD Application Status ==="
        argocd app get "$app_name" --output yaml 2>&1 || echo "Failed to get app status"
        echo ""
        
        echo "=== ArgoCD Application Events ==="
        argocd app get "$app_name" --output json 2>/dev/null | \
            jq -r '.status.conditions[]? | "[\(.lastTransitionTime)] \(.type): \(.message)"' 2>&1 || \
            echo "No events found"
        echo ""
        
        echo "=== ArgoCD Deployment History ==="
        argocd app history "$app_name" 2>/dev/null | head -20 || echo "Failed to get history"
    } > "$log_dir/argocd-$app_name.log" 2>&1
    
    # Get detailed application resources with status
    echo "🔍 Collecting detailed application resources..." >&2
    if ! argocd app get "$app_name" --output json > "$log_dir/application-details.json" 2>/dev/null; then
        echo "   ⚠️  Failed to get application details" >&2
    else
        # Extract resource status information
        jq -r '.status.resources[]? | "\(.kind)/\(.namespace)/\(.name): \(.status) - \(.health.status // "unknown")"' "$log_dir/application-details.json" \
            > "$log_dir/resource-status.log" 2>/dev/null || true
    fi

    # Get pod logs and container status
    echo "📡 Collecting pod and container information..." >&2
    if [ -f "$log_dir/application-details.json" ]; then
        # Extract all pod resources
        jq -r '.status.resources[]? | select(.kind == "Pod") | "\(.namespace)/\(.name)"' "$log_dir/application-details.json" 2>/dev/null | \
        while read -r pod; do
            local namespace="${pod%%/*}"
            local pod_name="${pod#*/}"
            
            if [[ -z "$namespace" || -z "$pod_name" ]]; then
                continue
            fi
            
            echo "   📦 Pod: $namespace/$pod_name" >&2
            
            # Get pod logs
            echo "      📄 Getting logs for pod $pod_name" >&2
            argocd app logs "$app_name" --kind "Pod" --namespace "$namespace" --resource-name "$pod_name" --tail 100 \
                > "$log_dir/pod_logs/pod-${namespace}-${pod_name//\//-}.log" 2>&1 || \
                echo "      ⚠️  Failed to get logs for pod $pod_name" >&2
            
            # Get container status
            echo "      📦 Container status:" >&2
            jq -r --arg ns "$namespace" --arg pn "$pod_name" \
                '.status.resources[]? | select(.kind == "Pod" and .namespace == $ns and .name == $pn) | "\(.name) - Status: \(.status) - Health: \(.health.status // "unknown")"' \
                "$log_dir/application-details.json" 2>/dev/null | while read -r status; do
                echo "         $status" >&2
            done
            
            # Get pod events
            echo "      ⚡ Pod events:" >&2
            argocd app events "$app_name" --resource-kind "Pod" --resource-namespace "$namespace" --resource-name "$pod_name" 2>/dev/null | \
                head -20 2>&1 | while read -r event; do
                echo "         $event" >&2
            done || echo "         No events found" >&2
            
            echo "" >&2
            
        done
    else
        echo "   ⚠️  Could not collect pod details - application details not available" >&2
    fi
    
    # Get application events
    echo "📋 Application-level events:" >&2
    argocd app events "$app_name" 2>&1 | head -50 | tee "$log_dir/application-events.log" | while read -r event; do
        echo "   $event" >&2
    done || true
    
    echo "" >&2
    echo "✅ Log and diagnostic information collected" >&2
    
    echo "✅ Log collection complete" >&2
}

upload_artifacts() {
    local log_dir="$1"
    local app_name="$2"
    
    echo "📤 Uploading artifacts for application: $app_name"
    
    # Create artifact archive
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local archive_name="argocd-logs-${app_name}-${timestamp}.tar.gz"
    
    cd "$(dirname "$log_dir")" || return 1
    tar -czf "$archive_name" "$(basename "$log_dir")"
    
    # Upload to Buildkite artifacts
    if buildkite-agent artifact upload "$archive_name"; then
        echo "✅ Artifacts uploaded successfully: $archive_name"
    else
        echo "⚠️  Failed to upload artifacts"
    fi
    
    # Clean up
    rm -f "$archive_name"
    rm -rf "$log_dir"
}

create_deployment_log() {
    local app_name="$1"
    local operation="$2"
    local status="$3"
    
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="/tmp/argocd-${operation}-${app_name}-${timestamp}.log"
    
    {
        echo "=== ArgoCD Deployment Plugin Log ==="
        echo "Operation: $operation"
        echo "Application: $app_name"
        echo "Status: $status"
        echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "Build: ${BUILDKITE_BUILD_URL:-unknown}"
        echo "Pipeline: ${BUILDKITE_PIPELINE_SLUG:-unknown}"
        echo "Branch: ${BUILDKITE_BRANCH:-unknown}"
        echo "Commit: ${BUILDKITE_COMMIT:-unknown}"
        echo "================================"
        echo ""
    } > "$log_file"
    
    echo "$log_file"
}

# Buildkite Plugin helper functions (from Buildkite's plugin-helpers)
# https://github.com/buildkite-plugins/plugin-helpers

# Reads either a value or a list from plugin config
function prefix_read_list() {
  local prefix="$1"
  local parameter="${prefix}_0"

  if [[ -n "${!parameter:-}" ]]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [[ -n "${!parameter:-}" ]]; do
      echo "${!parameter}"
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [[ -n "${!prefix:-}" ]]; then
    echo "${!prefix}"
  fi
}

# Reads a list from plugin config into a global result array
# Returns success if values were read
function prefix_read_list_into_result() {
  result=()

  local prefix="$1"
  local parameter="${prefix}_0"

  if [[ -n "${!parameter:-}" ]]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [[ -n "${!parameter:-}" ]]; do
      result+=("${!parameter}")
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [[ -n "${!prefix:-}" ]]; then
    result+=("${!prefix}")
  fi

  [[ ${#result[@]} -gt 0 ]] || return 1
}

function plugin_read_list() {
  prefix_read_list "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}

function plugin_read_list_into_result() {
  prefix_read_list_into_result "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}

# Reads a single value
function plugin_read_config() {
  local var="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
  local default="${2:-}"
  echo "${!var:-$default}"
}

# Metadata helper functions
set_deployment_metadata() {
    local app_name="$1"
    local status="$2"
    local result_value="${3:-}"
    local current_version="${4:-}"
    local previous_version="${5:-}"
    
    set_metadata "deployment:argocd:${app_name}:status" "$status"
    
    if [[ -n "$result_value" ]]; then
        set_metadata "deployment:argocd:${app_name}:result" "$result_value"
    fi
    
    if [[ -n "$current_version" ]]; then
        set_metadata "deployment:argocd:${app_name}:current_version" "$current_version"
    fi
    
    if [[ -n "$previous_version" ]]; then
        set_metadata "deployment:argocd:${app_name}:previous_version" "$previous_version"
    fi
}

set_rollback_metadata() {
    local app_name="$1"
    local status="$2"
    local result_value="${3:-}"
    local rollback_from="${4:-}"
    local rollback_to="${5:-}"
    
    set_metadata "deployment:argocd:${app_name}:status" "$status"
    
    if [[ -n "$result_value" ]]; then
        set_metadata "deployment:argocd:${app_name}:result" "$result_value"
    fi
    
    if [[ -n "$rollback_from" ]]; then
        set_metadata "deployment:argocd:${app_name}:rollback_from" "$rollback_from"
    fi
    
    if [[ -n "$rollback_to" ]]; then
        set_metadata "deployment:argocd:${app_name}:rollback_to" "$rollback_to"
    fi
}