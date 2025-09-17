#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  # Mock argocd CLI for tests
  export PATH="$PWD/tests/mocks:$PATH"
  
  # Create mock argocd command
  mkdir -p tests/mocks
  cat > tests/mocks/argocd << 'EOF'
#!/bin/bash
case "$1" in
  "version") echo "argocd: v2.8.0" ;;
  "context") echo "current" ;;
  "account") echo "admin" ;;
  "app") 
    case "$2" in
      "get") echo '{"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}' ;;
      "sync") echo "Operation initiated" ;;
      "rollback") echo "Rollback initiated" ;;
    esac
    ;;
  *) echo "Unknown command" ;;
esac
EOF
  chmod +x tests/mocks/argocd
  
  # Create mock buildkite-agent command
  cat > tests/mocks/buildkite-agent << 'EOF'
#!/bin/bash
case "$1" in
  "meta-data")
    case "$2" in
      "set") echo "Setting metadata: $3 = $4" ;;
      "get") echo "test-value" ;;
    esac
    ;;
  "annotate") echo "Creating annotation: $2" ;;
  "artifact")
    case "$2" in
      "upload") echo "Uploading artifact: $3" ;;
    esac
    ;;
  "pipeline")
    case "$2" in
      "upload") echo "Uploading pipeline step" ;;
    esac
    ;;
  *) echo "buildkite-agent: $*" ;;
esac
EOF
  chmod +x tests/mocks/buildkite-agent
}

@test "Missing app name fails" {
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

@test "Rollback mode with app name succeeds" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MODE='rollback'

  run "$PWD"/hooks/command

  assert_success
  assert_output --partial 'Starting rollback for ArgoCD application: test-app'
}

@test "Invalid mode fails" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MODE='invalid'

  run "$PWD"/hooks/command

  assert_failure
  assert_output --partial "Error: Invalid mode 'invalid'. Must be 'deploy' or 'rollback'"
}

@test "Timeout validation succeeds" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_TIMEOUT='300'

  run "$PWD"/hooks/command

  assert_success
}

@test "Health monitoring can be enabled" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_HEALTH_CHECK='true'

  run "$PWD"/hooks/command

  assert_success
}

@test "Log collection can be enabled" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_COLLECT_LOGS='true'

  run "$PWD"/hooks/command

  assert_success
}

@test "Artifact upload can be enabled" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_UPLOAD_ARTIFACTS='true'

  run "$PWD"/hooks/command

  assert_success
}

@test "Manual rollback block can be enabled" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_MANUAL_ROLLBACK_BLOCK='true'

  run "$PWD"/hooks/command

  assert_success
}

@test "Notifications can be configured" {
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_APP='test-app'
  export BUILDKITE_PLUGIN_ARGOCD_DEPLOYMENT_NOTIFICATIONS_SLACK_WEBHOOK='https://hooks.slack.com/test'

  run "$PWD"/hooks/command

  assert_success
}
