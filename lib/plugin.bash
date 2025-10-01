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

set_metadata() {
    local key="$1"
    local value="$2"
    buildkite-agent meta-data set "$key" "$value" || true
}

get_metadata() {
    local key="$1"
    buildkite-agent meta-data get "$key" 2>/dev/null || echo ""
}

# Buildkite Plugin helper functions (from Buildkite's plugin-helpers)
# https://github.com/buildkite-plugins/plugin-helpers

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
