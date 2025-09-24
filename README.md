# ArgoCD Deployment Buildkite Plugin

A Buildkite plugin for deploying and rolling back ArgoCD applications with comprehensive health monitoring, log collection, and notification capabilities.

## Features

- 🚀 **Deploy and Rollback**: Support for both deployment and rollback operations
- 🏥 **Health Monitoring**: Real-time application health checks via ArgoCD API
- 📋 **Log Collection**: Automatic collection of ArgoCD application and pod logs
- 📤 **Artifact Upload**: Upload deployment logs and artifacts to Buildkite
- 🔔 **Notifications**: Multi-channel notifications (Slack, Email, Webhook, PagerDuty)
- 🚧 **Manual Rollback Blocks**: Optional manual intervention points
- ⚡ **Auto Rollback**: Automatic rollback on deployment failures
- 🔐 **Secret Management**: Built-in support for Vault, AWS SSM, AWS Secrets Manager, and Buildkite Secrets
- 🔧 **Auto CLI Installation**: Automatically installs ArgoCD CLI if not present

## Prerequisites

Before using this plugin, ensure you have:

1. **ArgoCD Server Access**: Your Buildkite agents must have access to your ArgoCD server
2. **ArgoCD CLI Authentication**: Plugin handles authentication via configuration (see ArgoCD Authentication section)
3. **Kubernetes Access**: For pod log collection, agents need `kubectl` access to your cluster
4. **Required Tools**: `argocd`, `jq`, and optionally `kubectl` installed on agents

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

#### `health_check` (boolean)

Enable health monitoring via ArgoCD API. Defaults to `true`.

**Note**: When enabled, failed health checks trigger automatic rollback in deploy mode. For manual rollback control (useful in development), set `health_check: false` and use explicit rollback mode when needed.

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
- User IDs: `U123ABC456`

##### `notifications.email` (string, optional)

Email address for notifications.

##### `notifications.webhook_url` (string, optional)

Custom webhook URL for notifications.

##### `notifications.pagerduty_integration_key` (string, optional)

PagerDuty integration key for alerts.

### ArgoCD Authentication

#### `argocd_server` (string, required)

ArgoCD server URL. Example: `https://argocd.company.com`

**Authentication Methods** (choose one):

**Option 1: Token Authentication**

#### `argocd_token` (string)

Secret reference toArgoCD authentication token. Example: `vault:secret/argocd/token`

**Option 2: Username/Password Authentication**

#### `argocd_username` (string)

ArgoCD username

#### `argocd_password` (string)

Secret reference to ArgoCD password. Example: `vault:secret/argocd/password`

**Secret Management**: The plugin supports Vault (`vault:`), AWS SSM (`aws-ssm:`), AWS Secrets Manager (`aws-sm:`), and Buildkite Secrets (`bk-secrets:`). Passwords and tokens must use secure secret management - plain text values are not allowed.

## Usage Patterns

### Production: Auto-rollback (Recommended)

Safe deployments with automatic rollback on health check failures:

```yaml
steps:
  - plugins:
      - github.com/Mykematt/argocd-deployment-buildkite-plugin#v1.0.0:
          app: "my-app"
          mode: "deploy"
          # health_check: true (default)
          # Automatic rollback on health failures
```

### Development: Manual Control

Disable auto-rollback for investigation, use explicit rollback when needed:

```yaml
# Deploy without auto-rollback
steps:
  - plugins:
      - github.com/Mykematt/argocd-deployment-buildkite-plugin#v1.0.0:
          app: "my-app"
          mode: "deploy"
          health_check: false  # Disable auto-rollback
```

```yaml
# Later: Manual rollback pipeline
steps:
  - plugins:
      - github.com/Mykematt/argocd-deployment-buildkite-plugin#v1.0.0:
          app: "my-app"
          mode: "rollback"
          rollback_mode: "manual"  # Human oversight
          collect_logs: true
          upload_artifacts: true
```

## Examples

### Deployment with Notifications

Deploy with Slack and email notifications on rollback:

```yaml
steps:
  - label: "🚀 Deploy with Notifications"
    plugins:
      - github.com/Mykematt/argocd-deployment-buildkite-plugin#v1.0.0:
          app: "my-application"
          notifications:
            slack_channel: "#deployments"  # Channel name
            # slack_channel: "@devops-lead"  # Username
            # slack_channel: "U123ABC456"    # User ID
            email: "devops@company.com"
            webhook_url: "https://your-webhook.com/notify"
            pagerduty_integration_key: "YOUR_PAGERDUTY_KEY"
```

## Compatibility

| Elastic Stack | Agent Stack K8s | Hosted (Mac) | Hosted (Linux) | Notes |
| :-----------: | :-------------: | :----: | :----: |:---- |
| ✅ | ✅ | ⚠️ | ✅ | Requires ArgoCD CLI setup |

- ✅ Fully supported (all combinations of attributes have been tested to pass)
- ⚠️ Partially supported (some combinations cause errors/issues)
- ❌ Not supported

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
