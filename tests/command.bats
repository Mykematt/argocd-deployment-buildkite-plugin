#!/usr/bin/env bats

# Load bats helpers
if [[ -f /usr/local/lib/bats/load.bash ]]; then
  load '/usr/local/lib/bats/load.bash'
elif [[ -f /usr/lib/bats/bats-assert/load.bash ]]; then
  load '/usr/lib/bats/bats-assert/load.bash'
else
  # Fallback - define basic assert functions
  assert_success() { [[ $status -eq 0 ]]; }
  assert_failure() { [[ $status -ne 0 ]]; }
  assert_output() {
    if [[ "$1" == "--partial" ]]; then
      [[ "$output" == *"$2"* ]]
    else
      [[ "$output" == "$1" ]]
    fi
  }
fi

setup() {
  # Mock argocd CLI for tests
  export PATH="$PWD/tests/mocks:$PATH"
  
  # Create mock argocd command
  mkdir -p tests/mocks
  cat > tests/mocks/argocd << 'EOF'
#!/bin/bash
case "$1" in
  "version") echo "argocd: v2.8.0" ;;
  "context") echo "current" ;;
  "app")
    case "$2" in
      "get") 
        # Always return healthy status for tests
        echo '{"metadata":{"name":"test-app"},"status":{"sync":{"revision":"abc123"},"health":{"status":"Healthy"},"operationState":{"phase":"Succeeded"}}}'
        ;;
      "sync") 
        echo "Synced successfully"
        exit 0
        ;;
      "rollback") 
        echo "Rolled back successfully"
        exit 0
        ;;
      *) echo "app: $*" ;;
    esac
    ;;
  *) echo "argocd: $*" ;;
esac
EOF
  chmod +x tests/mocks/argocd
  
  # Create mock buildkite-agent command
  cat > tests/mocks/buildkite-agent << 'EOF'
#!/bin/bash
case "$1" in
  "meta-data")
    case "$2" in
      "get") 
        # Return empty for metadata that doesn't exist
        echo ""
        exit 1
        ;;
      "set") 
        echo "Metadata set"
        exit 0
        ;;
      *) echo "meta-data: $*" ;;
    esac
    ;;
  "annotate") 
    echo "Annotation created"
    exit 0
    ;;
  "artifact") 
    echo "Artifact uploaded"
    exit 0
    ;;
  "pipeline") 
    echo "Pipeline uploaded"
    exit 0
    ;;
  *) echo "buildkite-agent: $*" ;;
esac
EOF
  chmod +x tests/mocks/buildkite-agent
}

@test "Missing app name fails" {
  unset BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP
  run "$PWD"/hooks/command

  assert_failure
  assert_output --partial 'Error: app parameter is required'
}

@test "Deploy mode with app name succeeds" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MODE='deploy'

  run "$PWD"/hooks/command

  assert_success
  assert_output --partial 'Starting deployment for ArgoCD application: test-app'
}

@test "Rollback mode with auto rollback_mode succeeds" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MODE='rollback'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_ROLLBACK_MODE='auto'

  run "$PWD"/hooks/command

  # Test should fail gracefully when no previous version exists
  assert_failure
  assert_output --partial 'No previous version available for rollback'
}

@test "Invalid mode fails" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MODE='invalid'

  run "$PWD"/hooks/command

  assert_failure
  assert_output --partial "Error: Invalid mode 'invalid'. Must be 'deploy' or 'rollback'"
}

@test "Rollback mode with manual rollback_mode succeeds" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MODE='rollback'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_ROLLBACK_MODE='manual'

  run "$PWD"/hooks/command

  # Test should fail gracefully when no previous version exists
  assert_failure
  assert_output --partial 'No previous version available for rollback'
}

@test "Invalid rollback_mode for rollback mode fails" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MODE='rollback'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_ROLLBACK_MODE='invalid'

  run "$PWD"/hooks/command

  assert_failure
  assert_output --partial "Error: Invalid rollback_mode 'invalid'. Must be 'auto' or 'manual'"
}

@test "Health monitoring can be enabled" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_HEALTH_CHECK='true'

  run "$PWD"/hooks/command

  assert_success
  assert_output --partial 'Starting deployment for ArgoCD application: test-app'
}

@test "Log collection can be enabled" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_COLLECT_LOGS='true'

  run "$PWD"/hooks/command

  assert_success
  assert_output --partial 'Starting deployment for ArgoCD application: test-app'
}

@test "Artifact upload can be enabled" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_UPLOAD_ARTIFACTS='true'

  run "$PWD"/hooks/command

  assert_success
  assert_output --partial 'Starting deployment for ArgoCD application: test-app'
}

@test "Manual rollback block can be enabled" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MANUAL_ROLLBACK_BLOCK='true'

  run "$PWD"/hooks/command

  assert_success
  assert_output --partial 'Starting deployment for ArgoCD application: test-app'
}

@test "Notifications can be configured" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_NOTIFICATIONS_SLACK_CHANNEL='#deployments'

  run "$PWD"/hooks/command

  assert_success
  assert_output --partial 'Starting deployment for ArgoCD application: test-app'
}
