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

# Installation functions
install_argocd_cli() {
    echo "📦 Installing ArgoCD CLI..."
    
    # Check if ArgoCD CLI is already installed
    if command -v argocd >/dev/null 2>&1; then
        echo "✅ ArgoCD CLI is already installed: $(argocd version --client --short)"
        return 0
    fi
    
    # Determine OS and architecture
    local os
    local arch
    
    case "$(uname -s)" in
        Linux*)  os="linux";;
        Darwin*) os="darwin";;
        *)       echo "❌ Unsupported OS: $(uname -s)"; return 1;;
    esac
    
    case "$(uname -m)" in
        x86_64) arch="amd64";;
        arm64)  arch="arm64";;
        *)      echo "❌ Unsupported architecture: $(uname -m)"; return 1;;
    esac
    
    # Get latest version and download
    local version
    version=$(plugin_read_config ARGOCD_VERSION "stable")
    
    if [[ "$version" == "stable" ]]; then
        version=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name)
    fi
    
    echo "📥 Downloading ArgoCD CLI version: $version"
    
    local download_url="https://github.com/argoproj/argo-cd/releases/download/$version/argocd-$os-$arch"
    local install_path="/usr/local/bin/argocd"
    
    if ! curl -sSL "$download_url" -o "$install_path"; then
        echo "❌ Failed to download ArgoCD CLI"
        return 1
    fi
    
    chmod +x "$install_path"
    echo "✅ ArgoCD CLI installed successfully: $(argocd version --client --short)"
}

validate_requirements() {
    echo "🔍 Validating requirements..."
    
    # Check for required commands
    local required_commands=("jq" "curl")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "❌ Required command not found: $cmd"
            return 1
        fi
    done
    
    # Install ArgoCD CLI if not present
    if ! command -v argocd >/dev/null 2>&1; then
        install_argocd_cli
    fi
    
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

# Utility functions
get_current_revision() {
    local app_name="$1"
    argocd app get "$app_name" --output json 2>/dev/null | jq -r '.status.sync.revision // "unknown"'
}

get_previous_deployment_revision() {
    local app_name="$1"
    
    echo "🔍 Getting previous deployment revision from ArgoCD history..."
    
    # Get the current deployment first
    local current_revision_sha
    current_revision_sha=$(argocd app get "$app_name" -o json | jq -r '.status.sync.revision // "unknown"')
    
    if [[ "$current_revision_sha" == "unknown" ]]; then
        echo "No previous version available for rollback"
        return 1
    fi
    
    # Get deployment history and find the revision before current
    local previous_history_id=""
    local current_short_sha="${current_revision_sha:0:7}"
    
    # Look for the deployment history entry that comes before the current one
    while IFS= read -r line; do
        # Skip empty lines and headers
        if [[ -n "$line" && "$line" != "ID"* && "$line" != *"----"* ]]; then
            local line_id=""
            local line_hash=""
            
            line_id=$(echo "$line" | awk '{print $1}' 2>/dev/null || echo "")
            line_hash=$(echo "$line" | awk '{if (NF >= 7) print $7}' 2>/dev/null | tr -d '()' || echo "")
            
            if [[ -n "$line_id" && -n "$line_hash" && "$line_hash" != "unknown" ]]; then
                local line_short_hash="${line_hash:0:7}"
                
                # If we find the current revision, the previous one we stored is what we want
                if [[ "$line_short_hash" == "$current_short_sha" ]]; then
                    break
                fi
                
                # Store this as potential previous revision
                previous_history_id="$line_id"
            fi
        fi
    done < <(argocd app history "$app_name" 2>/dev/null)
    
    if [[ -n "$previous_history_id" ]]; then
        echo "📍 Found previous deployment history ID: $previous_history_id"
        echo "$previous_history_id"
    else
        echo "No previous version available for rollback"
        return 1
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

# Helper function to lookup deployment history ID from git revision
lookup_deployment_history_id() {
    local app_name="$1"
    local git_revision="$2"
    
    echo "🔍 Looking up deployment history ID for revision: $git_revision" >&2
    
    local short_hash="${git_revision:0:7}"
    local history_id
    history_id=$(argocd app history "$app_name" | grep "$short_hash" | tail -1 | awk '{print $1}' || echo "")
    
    if [[ -z "$history_id" ]]; then
        echo "❌ Could not find deployment history ID for revision: $git_revision (short: $short_hash)" >&2
        return 1
    fi
    
    echo "📍 Found deployment history ID: $history_id for revision: $git_revision" >&2
    echo "$history_id"
}

# Log collection and artifact functions
collect_app_logs() {
    local app_name="$1"
    local log_dir
    log_dir=$(mktemp -d)
    
    echo "📋 Collecting logs for ArgoCD application: $app_name"
    echo "📍 Log directory: $log_dir"
    
    # Collect ArgoCD application logs
    {
        echo "=== ArgoCD Application Status ==="
        argocd app get "$app_name" --output yaml || echo "Failed to get app status"
        echo ""
        
        echo "=== ArgoCD Application Events ==="
        argocd app get "$app_name" --output json | jq -r '.status.conditions[]? | "[\(.lastTransitionTime)] \(.type): \(.message)"' || echo "No events found"
        echo ""
        
        echo "=== ArgoCD Deployment History ==="
        argocd app history "$app_name" | head -20 || echo "Failed to get history"
    } > "$log_dir/argocd-$app_name.log"
    
    # Collect ArgoCD managed resources and events (no kubectl needed)
echo "🔍 Collecting ArgoCD managed resources and events..."

{
    echo "=== ArgoCD Managed Resources ==="
    if argocd app resources "$app_name" 2>/dev/null; then
        echo "✅ Successfully retrieved managed resources"
    else
        echo "❌ Failed to get managed resources"
    fi
    echo ""
    
    echo "=== ArgoCD Resource Tree ==="
    if argocd app get "$app_name" --output json | jq -r '.status.resources[]? | "[\(.kind)] \(.name) - \(.status // "Unknown")"' 2>/dev/null; then
        echo "✅ Successfully retrieved resource tree"  
    else
        echo "❌ Failed to get resource tree"
    fi
    echo ""
    
    echo "=== ArgoCD Application Details ==="
    if argocd app get "$app_name" --output json | jq -r '
        "Sync Status: \(.status.sync.status // "Unknown")",
        "Health Status: \(.status.health.status // "Unknown")",
        "Sync Revision: \(.status.sync.revision // "Unknown")",
        "Target Revision: \(.spec.source.targetRevision // "Unknown")",
        "Repository: \(.spec.source.repoURL // "Unknown")",
        "Path: \(.spec.source.path // ".")",
        "Namespace: \(.spec.destination.namespace // "Unknown")"
    ' 2>/dev/null; then
        echo "✅ Successfully retrieved application details"
    else
        echo "❌ Failed to get application details" 
    fi
    echo ""
    
    echo "=== ArgoCD Operation State ==="
    if argocd app get "$app_name" --output json | jq -r '
        if .status.operationState then
            "Phase: \(.status.operationState.phase // "Unknown")",
            "Message: \(.status.operationState.message // "No message")",
            "Started: \(.status.operationState.startedAt // "Unknown")",
            "Finished: \(.status.operationState.finishedAt // "Unknown")"
        else
            "No operation state available"
        end
    ' 2>/dev/null; then
        echo "✅ Successfully retrieved operation state"
    else
        echo "❌ Failed to get operation state"
    fi
} > "$log_dir/argocd-resources-$app_name.log" 2>&1
    
    echo "$log_dir"
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