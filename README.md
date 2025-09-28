# ArgoCD Deployment Buildkite Plugin

A Buildkite plugin for deploying and rolling back ArgoCD applications with comprehensive health monitoring, log collection, and notification capabilities.

## Prerequisites

### Required CLI Tools

The plugin requires the following tools to be pre-installed on your Buildkite agents:

- **ArgoCD CLI** (`argocd`) - [Installation Guide](https://argo-cd.readthedocs.io/en/stable/cli_installation/)
- **jq** - JSON processor

> **Note**: The plugin does not automatically install these tools to support air-gapped/isolated network environments. Please ensure they are available on your Buildkite agents before using this plugin.

## Authentication

The plugin requires ArgoCD authentication via environment variables. You must set these before your ArgoCD plugin steps:

### Required Environment Variables

- `ARGOCD_SERVER` - ArgoCD server URL (can be set in the plugin step)
- `ARGOCD_USERNAME` - ArgoCD username (can be set in the plugin step)
- `ARGOCD_PASSWORD` - ArgoCD password (use your desired 3rd party secret management solution and fetched before the ArgoCD plugin steps)

```yaml
steps:
  # Fetch secrets once for entire pipeline
  - label: "🔐 Fetch ArgoCD Credentials"
    key: "fetch-argocd-secrets"
    plugins:
      # Choose your secret management solution:
      - secrets#v1.0.0:                    # Buildkite Secrets
          env:
            ARGOCD_PASSWORD: your-secret-key
      # OR
      - vault-secrets#v2.2.1:              # HashiCorp Vault
          server: ${VAULT_ADDR}
          secrets:
            - path: secret/argocd/password
              field: ARGOCD_PASSWORD
      # OR  
      - aws-sm#v1.0.0:                     # AWS Secrets Manager
          secrets:
            - name: ARGOCD_PASSWORD
              key: argocd/password
      # OR
      - aws-ssm#v1.0.0:                    # AWS SSM Parameter Store
          parameters:
            ARGOCD_PASSWORD: /argocd/password
            
  # All ArgoCD steps use the fetched credentials
  - label: "🚀 Deploy Application"
    depends_on: "fetch-argocd-secrets"
    plugins:
      - argocd_deployment#v1.0.0:
          app: "my-app"
          argocd_server: "https://argocd.example.com" # if not set in environment variables
          argocd_username: "admin" # if not set in environment variables
```

## Features

- 🚀 **Deploy and Rollback**: Support for both deployment and rollback operations
- 🏥 **Health Monitoring**: Real-time application health checks via ArgoCD API
- 📋 **Log Collection**: Automatic collection of ArgoCD application and pod logs
- 📤 **Artifact Upload**: Upload deployment logs and artifacts to Buildkite
- 🔔 **Notifications**: Slack notifications via Buildkite integration
- 🚧 **Manual Rollback Workflow**: Interactive block steps for manual rollback decisions
- ⚡ **Auto Rollback**: Automatic rollback on deployment failures
- 🎯 **Smart Rollback Logic**: Temporarily disables auto-sync during rollbacks to prevent conflicts
- 📊 **Comprehensive Annotations**: Beautiful success/failure annotations with detailed information

## Configuration Options

### Required

#### `app` (string)

The name of the ArgoCD application to deploy or rollback.

### Optional

#### `mode` (string)

Operation mode. Defaults to `"deploy"`.

- `deploy`: Deploy the application
- `rollback`: Rollback the application

#### `rollback_mode` (string)

Rollback mode for handling deployment failures.

- **For `mode: "deploy"`**: Defaults to `"auto"`
  - `auto`: Automatic rollback to previous version on health check failure
  - `manual`: Manual rollback with interactive block step for user decision
- **For `mode: "rollback"`**: Required, no default
  - `auto`: Rollback to previous version
  - `manual`: Rollback to specific revision with user confirmation

#### `timeout` (number)

Timeout in seconds for ArgoCD operations. Defaults to `300`. Must be between 30 and 3600 seconds.

#### `argocd_server` (string)

ArgoCD server URL. Can also be set via `ARGOCD_SERVER` environment variable.

#### `argocd_username` (string)

ArgoCD username. Can also be set via `ARGOCD_USERNAME` environment variable.

#### `target_revision` (string)

Target revision for rollback operations. Accepts ArgoCD History IDs or Git commit SHAs.

#### `health_check` (boolean)

Enable health monitoring after deployment. Defaults to `false`.

#### `health_check_interval` (number)

Health check interval in seconds. Defaults to `30`. Must be between 10 and 300 seconds.

#### `health_check_timeout` (number)

Health check timeout in seconds. Defaults to `300`. Must be between 60 and 1800 seconds.

#### `collect_logs` (boolean)

Collect application logs on deployment. Defaults to `false`.

#### `log_lines` (number)

Number of log lines to collect. Defaults to `1000`. Must be between 100 and 10000.

#### `upload_artifacts` (boolean)

Upload logs and deployment artifacts. Defaults to `false`.

#### `notifications` (object)

Notification settings for rollback events.

##### `notifications.slack_channel` (string, optional)

Slack channel, username, or user ID for notifications using Buildkite's native Slack integration. Supports:

- Channel names: `#deployments`, `#alerts`
- Usernames: `@username`, `@devops-team`
- User IDs: `U123ABC456` (found via User > More options > Copy member ID)

## Usage Patterns

### Production: Auto-rollback (Recommended)

Safe deployments with automatic rollback on health check failures:

```yaml
steps:
  - label: "🚀 Deploy Application"
    plugins:
      - secrets#v1.0.0:
          variables:
            ARGOCD_PASSWORD: argocd_password
      - argocd_deployment#v1.0.0:
          app: "my-app"
          argocd_server: "https://argocd.example.com"
          argocd_username: "admin"
          mode: "deploy"
          rollback_mode: "auto"  # Automatic rollback on failure
          health_check: true
          collect_logs: true
          upload_artifacts: true
```

### Development: Manual Rollback Control

Manual rollback workflow with interactive block steps for user decision:

```yaml
steps:
  - label: "🚫 Deploy with Manual Rollback"
    plugins:
      - secrets#v1.0.0:
          variables:
            ARGOCD_PASSWORD: argocd_password
      - argocd_deployment#v1.0.0:
          app: "my-app"
          argocd_server: "https://argocd.example.com"
          argocd_username: "admin"
          mode: "deploy"
          rollback_mode: "manual"  # Interactive rollback decision
          health_check: true
          collect_logs: true
          upload_artifacts: true
          notifications:
            slack_channel: "#deployments"
```

### Manual Rollback Operation

Explicit rollback to a specific revision:

```yaml
steps:
  - label: "🔄 Manual Rollback"
    plugins:
      - secrets#v1.0.0:
          variables:
            ARGOCD_PASSWORD: argocd_password
      - argocd_deployment#v1.0.0:
          app: "my-app"
          argocd_server: "https://argocd.example.com"
          argocd_username: "admin"
          mode: "rollback"
          target_revision: "123"  # ArgoCD History ID or Git SHA
          collect_logs: true
          upload_artifacts: true
```

## Compatibility

| Elastic Stack | Agent Stack K8s | Hosted (Mac) | Hosted (Linux) | Notes |
| :-----------: | :-------------: | :----: | :----: |:---- |
| ✅ | ✅ | ⚠️ | ✅ | Requires ArgoCD CLI setup |

- ✅ Fully supported (all combinations of attributes have been tested to pass)
- ⚠️ Partially supported (some combinations cause errors/issues)
- ❌ Not supported

## Workflow

### Deploy Mode

1. **Validation**: Plugin validates ArgoCD connectivity and application existence
2. **Pre-deployment**: Captures current application state and revision for rollback
3. **Deployment**: Executes ArgoCD sync operation
4. **Health Monitoring**: Monitors application health via ArgoCD API (always enabled)
   - **Auto mode**: Completes full health check cycle, then automatic rollback on failure
   - **Manual mode**: Fails immediately on first failure to save time, then interactive block step
5. **Failure Handling**:
   - **Auto mode**: Automatic rollback to previous stable version with smart rollback logic (auto-sync management)
   - **Manual mode**: Interactive block step for user decision
6. **Log Collection**: Collects ArgoCD app logs and pod logs (if enabled)
7. **Artifact Upload**: Uploads logs and deployment artifacts to Buildkite
8. **Notifications**: Sends Slack notifications on rollback events
9. **Annotations**: Creates beautiful success/failure annotations with detailed information

### Rollback Mode

1. **Validation**: Plugin validates ArgoCD connectivity and target revision
2. **Rollback Execution**: Executes ArgoCD rollback to specified revision
3. **Log Collection**: Collects ArgoCD app logs and pod logs (if enabled)
4. **Artifact Upload**: Uploads logs and deployment artifacts to Buildkite
5. **Notifications**: Sends Slack notifications on rollback events
6. **Annotations**: Creates beautiful success/failure annotations with detailed information

## 👩‍💻 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Developing

To run linting and shellchecks, use `bk run` with the [Buildkite CLI](https://github.com/buildkite/cli):

```bash
bk run
```

## 📜 License

The package is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
