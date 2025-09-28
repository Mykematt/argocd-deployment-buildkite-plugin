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
      - github.com/your-org/argocd-deployment-buildkite-plugin:
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
- 🚧 **Manual Rollback Blocks**: Optional manual intervention points
- ⚡ **Auto Rollback**: Automatic rollback on deployment failures

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

Rollback mode when `mode` is `"rollback"`. Defaults to `"auto"`.

- `auto`: Automatic rollback to previous version
- `manual`: Manual rollback (requires user intervention)

#### `timeout` (number)

Timeout in seconds for ArgoCD operations. Defaults to `300`. Must be between 30 and 3600 seconds.

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

#### `manual_rollback_block` (boolean)

Add manual rollback block step after successful deployment. Defaults to `false`.

#### `block_timeout` (number)

Manual block timeout in minutes. Defaults to `60`. Must be between 5 and 1440 minutes.

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
  - plugins:
      - argocd_deployment#v1.0.0:
          app: "my-app"
          # rollback_mode: auto (default)
```

### Development: Manual Control

Disable auto-rollback for investigation, use explicit rollback when needed:

```yaml
# Later: Manual rollback pipeline
steps:
  - plugins:
      - argocd_deployment#v1.0.0:
          app: "my-app"
          mode: "rollback"
          rollback_mode: "manual"  # Human oversight
```

### Advanced Configuration

Full configuration with all options:

```yaml
steps:
  - plugins:
      - argocd_deployment#v1.0.0:
          app: "my-application"
          mode: "deploy"
          timeout: 300
          health_check: true
          collect_logs: true
          upload_artifacts: true
          notifications:
            slack_channel: "#deployments"  # Channel name
            # slack_channel: "@devops-lead"  # Username
            # slack_channel: "U123ABC456"    # User ID
```

## Compatibility

| Elastic Stack | Agent Stack K8s | Hosted (Mac) | Hosted (Linux) | Notes |
| :-----------: | :-------------: | :----: | :----: |:---- |
| ✅ | ✅ | ⚠️ | ✅ | Requires ArgoCD CLI setup |

- ✅ Fully supported (all combinations of attributes have been tested to pass)
- ⚠️ Partially supported (some combinations cause errors/issues)
- ❌ Not supported

## Workflow

1. **Validation**: Plugin validates ArgoCD connectivity and configuration
2. **Pre-deployment**: Captures current application state and revision
3. **Deployment/Rollback**: Executes ArgoCD sync or rollback operation
4. **Health Monitoring**: Monitors application health via ArgoCD API (if enabled)
5. **Log Collection**: Collects ArgoCD and pod logs (if enabled)
6. **Artifact Upload**: Uploads logs and deployment artifacts to Buildkite
7. **Notifications**: Sends notifications on rollback events
8. **Manual Blocks**: Optionally injects manual rollback decision points

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
