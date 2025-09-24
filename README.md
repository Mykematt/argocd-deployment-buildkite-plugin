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

## Requirements

- ArgoCD CLI (`argocd`)
- Buildkite Agent
- `jq` for JSON parsing
- `kubectl` (optional, for pod log collection)

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
- User IDs: `U123ABC456` (found via User > More options > Copy member ID)

##### `notifications.email` (string, optional)

Email address for notifications.

##### `notifications.webhook_url` (string, optional)

Custom webhook URL for notifications.

##### `notifications.pagerduty_integration_key` (string, optional)

PagerDuty integration key for alerts.

## Usage Patterns

### Production: Auto-rollback (Recommended)

Safe deployments with automatic rollback on health check failures:

```yaml
steps:
  - plugins:
      - argocd_deployment#v1.0.0:
          app: "my-app"
          # health_check: true (default)
          # Automatic rollback on health failures
```

### Development: Manual Control

Disable auto-rollback for investigation, use explicit rollback when needed:

```yaml
# Deploy without auto-rollback
steps:
  - plugins:
      - argocd_deployment#v1.0.0:
          app: "my-app"
          health_check: false  # Disable auto-rollback
```

```yaml
# Later: Manual rollback pipeline
steps:
  - plugins:
      - argocd_deployment#v1.0.0:
          app: "my-app"
          mode: "rollback"
          rollback_mode: "manual"  # Human oversight
```

## Examples

### Basic Deployment

Deploy an ArgoCD application with default settings:

```yaml
steps:
  - label: "🚀 Deploy Application"
    plugins:
      - github.com/Mykematt/argocd-deployment-buildkite-plugin#v1.0.0:
          app: "my-application"
```

### Deployment with Custom Timeout

Deploy with a custom timeout and health monitoring:

```yaml
steps:
  - label: "🚀 Deploy with Custom Settings"
    plugins:
      - github.com/Mykematt/argocd-deployment-buildkite-plugin#v1.0.0:
          app: "my-application"
          timeout: 600
          health_check_timeout: 900
```

### Deployment with Manual Rollback Block

Deploy with a manual rollback decision point:

```yaml
steps:
  - label: "🚀 Deploy with Manual Rollback Option"
    plugins:
      - github.com/Mykematt/argocd-deployment-buildkite-plugin#v1.0.0:
          app: "my-application"
          manual_rollback_block: true
          block_timeout: 30
```

### Rollback Operation

Rollback an application to the previous version:

```yaml
steps:
  - label: "🔄 Rollback Application"
    plugins:
      - github.com/Mykematt/argocd-deployment-buildkite-plugin#v1.0.0:
          app: "my-application"
          mode: "rollback"
          rollback_mode: "auto"
```

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
            slack_channel: "#deployments"
            email: "devops@company.com"
            webhook_url: "https://your-webhook.com/notify"
            pagerduty_integration_key: "YOUR_PAGERDUTY_KEY"
```

## Prerequisites

Before using this plugin, ensure you have:

1. **ArgoCD Server Access**: Your Buildkite agents must have access to your ArgoCD server
2. **ArgoCD CLI Authentication**: Agents must be authenticated with ArgoCD (`argocd login`)
3. **Kubernetes Access**: For pod log collection, agents need `kubectl` access to your cluster
4. **Required Tools**: `argocd`, `jq`, and optionally `kubectl` installed on agents

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
