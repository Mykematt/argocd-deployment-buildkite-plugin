#!/bin/bash
set -euo pipefail

PLUGIN_PREFIX="ARGOCD_DEPLOYMENT"

# Installation functions
install_argocd_cli() {
    echo "📦 Installing ArgoCD CLI..."
    
    # Detect OS and architecture
    local os
    local arch
    
    case "$(uname -s)" in
        Linux*)     os="linux" ;;
        Darwin*)    os="darwin" ;;
        *)          echo "❌ Error: Unsupported OS $(uname -s)"; exit 1 ;;
    esac
    
    case "$(uname -m)" in
        x86_64)     arch="amd64" ;;
        arm64)      arch="arm64" ;;
        aarch64)    arch="arm64" ;;
        *)          echo "❌ Error: Unsupported architecture $(uname -m)"; exit 1 ;;
    esac
    
    local binary_name="argocd-${os}-${arch}"
    local download_url="https://github.com/argoproj/argo-cd/releases/latest/download/${binary_name}"
    local install_path="/usr/local/bin/argocd"
    
    echo "🔽 Downloading ArgoCD CLI from ${download_url}..."
    
    # Try to install to /usr/local/bin first, fallback to local directory
    if curl -sSL -o "${install_path}" "${download_url}" 2>/dev/null && chmod +x "${install_path}" 2>/dev/null; then
        echo "✅ ArgoCD CLI installed to ${install_path}"
    elif curl -sSL -o "./argocd" "${download_url}" && chmod +x "./argocd"; then
        local current_dir
        current_dir="$(pwd)"
        export PATH="${current_dir}:$PATH"
        echo "✅ ArgoCD CLI installed to ${current_dir}/argocd (added to PATH)"
    else
        echo "❌ Error: Failed to install ArgoCD CLI"
        exit 1
    fi
    
    # Verify installation
    if command -v argocd &> /dev/null; then
        echo "🎉 ArgoCD CLI successfully installed: $(argocd version --client --short 2>/dev/null || echo 'version check failed')"
    else
        echo "❌ Error: ArgoCD CLI installation verification failed"
        exit 1
    fi
}

# Validation functions
validate_requirements() {
    # Check if argocd CLI is available
    if ! command -v argocd &> /dev/null; then
        echo "⚠️  ArgoCD CLI not found. Installing automatically..."
        install_argocd_cli
    fi
    
    # Check if buildkite-agent is available
    if ! command -v buildkite-agent &> /dev/null; then
        echo "❌ Error: buildkite-agent not found. This plugin requires Buildkite agent."
        exit 1
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        echo "❌ Error: jq not found. Please install jq for JSON parsing."
        exit 1
    fi
}

validate_config() {
    local app_name="$1"
    local mode="$2"
    local rollback_mode="$3"
    
    if [[ -z "$app_name" ]]; then
        echo "❌ Error: app parameter is required"
        exit 1
    fi
    
    if [[ "$mode" != "deploy" && "$mode" != "rollback" ]]; then
        echo "❌ Error: Invalid mode '$mode'. Must be 'deploy' or 'rollback'"
        exit 1
    fi
    
    # Validate rollback_mode only for rollback operations
    if [[ "$mode" == "rollback" ]]; then
        if [[ "$rollback_mode" != "auto" && "$rollback_mode" != "manual" ]]; then
            echo "❌ Error: Invalid rollback_mode '$rollback_mode'. Must be 'auto' or 'manual'"
            exit 1
        fi
    fi
    
    echo "✅ Configuration validated"
}

check_argocd_connectivity() {
    echo "🔗 Checking ArgoCD connectivity..."
    
    # Check if already authenticated
    if argocd context &> /dev/null && argocd account get-user-info &> /dev/null; then
        echo "✅ Using existing ArgoCD authentication"
        return 0
    fi
    
    # Get authentication configuration from environment variables (populated by pre-command hook)
    local server="${ARGOCD_SERVER:-}"
    local username="${ARGOCD_USERNAME:-}"
    local password="${ARGOCD_PASSWORD:-}"
    local token="${ARGOCD_TOKEN:-}"
    
    # Validate authentication parameters
    if [[ -z "$server" ]]; then
        echo "❌ Error: ArgoCD server not configured"
        echo "   Please set argocd_server parameter or ARGOCD_SERVER environment variable"
        exit 1
    fi
    
    # Check authentication method: token OR username+password
    if [[ -n "$token" ]]; then
        echo "🎫 Authenticating with ArgoCD token..."
        if ! argocd login "$server" --auth-token "$token" --insecure; then
            echo "❌ Error: Failed to authenticate with ArgoCD token"
            exit 1
        fi
    elif [[ -n "$username" && -n "$password" ]]; then
        echo "👤 Authenticating with ArgoCD username/password..."
        if ! argocd login "$server" --username "$username" --password "$password" --insecure; then
            echo "❌ Error: Failed to authenticate with ArgoCD username/password"
            exit 1
        fi
    else
        echo "❌ Error: ArgoCD authentication not configured"
        echo "   Please provide either:"
        echo "   - argocd_token (authentication token), OR"
        echo "   - argocd_username AND argocd_password (username and password)"
        echo "   - These can be plain text or secret references (vault:, aws-ssm:, etc.)"
        exit 1
    fi
    
    # Verify authentication worked
    if ! argocd account get-user-info &> /dev/null; then
        echo "❌ Error: ArgoCD authentication verification failed"
        exit 1
    fi
    
    echo "✅ ArgoCD authentication successful"
}

# Utility functions
get_current_revision() {
    local app_name="$1"
    argocd app get "$app_name" --output json 2>/dev/null | jq -r '.status.sync.revision // "unknown"'
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

# Log collection and artifact functions
collect_app_logs() {
    local app_name="$1"
    local log_lines="$2"
    
    # Use Buildkite build directory if available, otherwise temp directory
    local log_dir
    if [[ -n "${BUILDKITE_BUILD_PATH:-}" ]]; then
        log_dir="${BUILDKITE_BUILD_PATH}/argocd-logs"
    else
        log_dir="${TMPDIR:-/tmp}/argocd-logs-$$"
    fi
    
    mkdir -p "$log_dir"
    
    echo "📋 Collecting ArgoCD application logs..." >&2
    
    # Get application resources
    if argocd app get "$app_name" --output json > "$log_dir/${app_name}-app-details.json" 2>/dev/null; then
        echo "✅ Collected application details" >&2
    fi
    
    # Get application manifests
    if argocd app manifests "$app_name" > "$log_dir/${app_name}-manifests.yaml" 2>/dev/null; then
        echo "✅ Collected application manifests" >&2
    fi
    
    # Get application events
    if argocd app get "$app_name" --show-events > "$log_dir/${app_name}-events.txt" 2>/dev/null; then
        echo "✅ Collected application events" >&2
    fi
    
    # Try to get pod logs if kubectl is available
    if command -v kubectl &> /dev/null; then
        echo "🔍 Attempting to collect pod logs..." >&2
        
        # Get namespace from ArgoCD app
        local namespace
        namespace=$(argocd app get "$app_name" --output json 2>/dev/null | jq -r '.spec.destination.namespace // "default"')
        
        # Get pods for the application
        local app_label
        app_label=$(argocd app get "$app_name" --output json 2>/dev/null | jq -r '.metadata.labels."app.kubernetes.io/instance" // .metadata.name')
        
        # Collect pod logs without hanging on empty results
        local pods_found=false
        while IFS= read -r pod_line; do
            if [[ -n "$pod_line" ]]; then
                pods_found=true
                local pod_name
                pod_name=$(echo "$pod_line" | awk '{print $1}')
                
                if [[ -n "$pod_name" ]]; then
                    echo "📋 Collecting logs for pod: $pod_name" >&2
                    kubectl logs -n "$namespace" "$pod_name" --tail="$log_lines" > "$log_dir/${app_name}-${pod_name}.log" 2>/dev/null || true
                    
                    # Get previous logs if pod restarted
                    kubectl logs -n "$namespace" "$pod_name" --previous --tail="$log_lines" > "$log_dir/${app_name}-${pod_name}-previous.log" 2>/dev/null || true
                fi
            fi
        done < <(kubectl get pods -n "$namespace" -l "app.kubernetes.io/instance=$app_label" --no-headers 2>/dev/null || true)
        
        if [[ "$pods_found" == "true" ]]; then
            echo "✅ Pod logs collected" >&2
        else
            echo "⚠️  Could not collect pod logs (kubectl not available or no pods found)" >&2
        fi
    else
        echo "⚠️  kubectl not available, skipping pod log collection" >&2
    fi
    
    echo "$log_dir"
}

upload_artifacts() {
    local log_dir="$1"
    local app_name="$2"
    
    echo "📤 Uploading artifacts for $app_name..."
    
    if [[ -d "$log_dir" ]]; then
        # Upload all files in the log directory
        buildkite-agent artifact upload "$log_dir/*" || echo "⚠️  Failed to upload some artifacts"
        echo "✅ Artifacts uploaded successfully"
    else
        echo "⚠️  Log directory not found: $log_dir"
    fi
}

create_deployment_log() {
    local app_name="$1"
    local operation="$2"
    local result="$3"
    local log_file
    log_file="deployment-${app_name}-$(date +%Y%m%d-%H%M%S).log"
    
    {
        echo "=== ArgoCD Deployment Log ==="
        echo "Application: $app_name"
        echo "Operation: $operation"
        echo "Result: $result"
        echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "Build: ${BUILDKITE_BUILD_NUMBER:-unknown}"
        echo "Pipeline: ${BUILDKITE_PIPELINE_SLUG:-unknown}"
        echo "Branch: ${BUILDKITE_BRANCH:-unknown}"
        echo "Commit: ${BUILDKITE_COMMIT:-unknown}"
        echo ""
        
        if [[ "$operation" == "deploy" ]]; then
            echo "=== Pre-Deployment State ==="
            argocd app get "$app_name" --output json 2>/dev/null || echo "Failed to get pre-deployment state"
            echo ""
        fi
        
        echo "=== Operation Output ==="
        # This will be populated by the calling function
    } > "$log_file"
    
    echo "$log_file"
}

# Reads either a value or a list from the given env prefix
function prefix_read_list() {
  local prefix="$1"
  local parameter="${prefix}_0"

  if [ -n "${!parameter:-}" ]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [ -n "${!parameter:-}" ]; do
      echo "${!parameter}"
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [ -n "${!prefix:-}" ]; then
    echo "${!prefix}"
  fi
}

# Reads either a value or a list from plugin config
function plugin_read_list() {
  prefix_read_list "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}

# Reads either a value or a list from plugin config into a global result array
# Returns success if values were read
function prefix_read_list_into_result() {
  local prefix="$1"
  local parameter="${prefix}_0"
  result=()

  if [ -n "${!parameter:-}" ]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [ -n "${!parameter:-}" ]; do
      result+=("${!parameter}")
      i=$((i+1))
      parameter="${prefix}_${i}"
    done
  elif [ -n "${!prefix:-}" ]; then
    result+=("${!prefix}")
  fi

  [ ${#result[@]} -gt 0 ] || return 1
}

# Reads either a value or a list from plugin config
function plugin_read_list_into_result() {
  prefix_read_list_into_result "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}

# Reads a single value
function plugin_read_config() {
  local var="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
  local default="${2:-}"
  echo "${!var:-$default}"
}
