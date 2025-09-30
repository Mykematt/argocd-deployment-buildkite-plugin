#!/bin/bash
# notifications.bash - Notification functions for Slack and other integrations


# Send rollback notification (fixed: removed recursive call to prevent infinite loops)
send_rollback_notification() {
    local app_name="$1"
    local from_revision="$2"
    local to_revision="$3"
    local reason="$4"
    
    log_info "Preparing rollback notification for $app_name"
    log_debug "Notification details: from=$from_revision, to=$to_revision, reason=$reason"
    
    local slack_channel
    slack_channel=$(plugin_read_config NOTIFICATIONS_SLACK_CHANNEL "")
    
    # Send Slack notification using Buildkite's native integration
    if [[ -n "$slack_channel" ]]; then
        log_info "Sending Slack notification to $slack_channel..."
        
        # Create notification message based on reason
        local notification_message
        case "$reason" in
            "rollback_success")
                notification_message="✅ *ArgoCD Rollback Successful*

*Application:* \`$app_name\`
*From Revision:* \`$from_revision\`
*To Revision:* \`$to_revision\`
*Status:* Rollback completed successfully
*Build:* <${BUILDKITE_BUILD_URL:-#}|#${BUILDKITE_BUILD_NUMBER:-unknown}>
*Pipeline:* \`${BUILDKITE_PIPELINE_SLUG:-unknown}\`
*Branch:* \`${BUILDKITE_BRANCH:-unknown}\`"
                ;;
            "rollback_failed")
                notification_message="❌ *ArgoCD Rollback Failed*

*Application:* \`$app_name\`
*From Revision:* \`$from_revision\`
*Target Revision:* \`$to_revision\`
*Status:* Rollback operation failed
*Build:* <${BUILDKITE_BUILD_URL:-#}|#${BUILDKITE_BUILD_NUMBER:-unknown}>
*Pipeline:* \`${BUILDKITE_PIPELINE_SLUG:-unknown}\`
*Branch:* \`${BUILDKITE_BRANCH:-unknown}\`

Manual investigation may be required."
                ;;
            "health_check_failed")
                notification_message="🚨 *ArgoCD Deployment Health Check Failed*

*Application:* \`$app_name\`
*Reason:* Health check failed after deployment
*Current Revision:* \`$from_revision\`
*Available Rollback Target:* \`$to_revision\`
*Build:* <${BUILDKITE_BUILD_URL:-#}|#${BUILDKITE_BUILD_NUMBER:-unknown}>
*Pipeline:* \`${BUILDKITE_PIPELINE_SLUG:-unknown}\`
*Branch:* \`${BUILDKITE_BRANCH:-unknown}\`

Manual rollback decision required."
                ;;
            "deployment_failed")
                notification_message="🚨 *ArgoCD Deployment Failed*

*Application:* \`$app_name\`
*Reason:* Deployment sync operation failed
*Current Revision:* \`$from_revision\`
*Available Rollback Target:* \`$to_revision\`
*Build:* <${BUILDKITE_BUILD_URL:-#}|#${BUILDKITE_BUILD_NUMBER:-unknown}>
*Pipeline:* \`${BUILDKITE_PIPELINE_SLUG:-unknown}\`
*Branch:* \`${BUILDKITE_BRANCH:-unknown}\`

Manual rollback decision required."
                ;;
            *)
                notification_message="🚨 *ArgoCD Rollback Alert*

*Application:* \`$app_name\`
*Reason:* $reason
*From Revision:* \`$from_revision\`
*To Revision:* \`$to_revision\`
*Build:* <${BUILDKITE_BUILD_URL:-#}|#${BUILDKITE_BUILD_NUMBER:-unknown}>
*Pipeline:* \`${BUILDKITE_PIPELINE_SLUG:-unknown}\`
*Branch:* \`${BUILDKITE_BRANCH:-unknown}\`"
                ;;
        esac
        
        # Inject notification step using Buildkite's native Slack integration
        local notification_pipeline
        notification_pipeline=$(cat <<-EOF
steps:
  - label: ":slack: ArgoCD Notification"
    command: "echo 'Sending notification to Slack...'"
    notify:
      - slack:
          channels:
            - "$slack_channel"
          message: |
            $notification_message
EOF
        )
        
        # Create temporary file for pipeline
        local pipeline_file
        pipeline_file=$(create_temp_file "notification-pipeline")
        echo "$notification_pipeline" > "$pipeline_file"
        
        # Upload notification pipeline
        if buildkite-agent pipeline upload "$pipeline_file" >/dev/null 2>&1; then
            log_success "Slack notification step injected for $slack_channel"
        else
            log_warning "Failed to inject Slack notification step"
        fi
        
        # Clean up temporary file
        rm -f "$pipeline_file"
    else
        log_info "No Slack channel configured - skipping notification"
    fi
}

# Create deployment annotation with consistent formatting
create_deployment_annotation() {
    local app_name="$1"
    local previous_version="$2"
    local current_version="$3"
    local deployment_result="$4"
    
    log_debug "Creating deployment annotation for $app_name: result=$deployment_result"
    
    local annotation
    local style
    
    case "$deployment_result" in
        "success")
            annotation="✅ **ArgoCD Deployment Successful**

**Application:** \`$app_name\`  
**Previous Version:** \`$previous_version\`  
**Current Version:** \`$current_version\`  
**Status:** \`$deployment_result\`  
**Timestamp:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')

The application has been successfully deployed and is healthy."
            style="success"
            ;;
        "failed")
            annotation="❌ **ArgoCD Deployment Failed**

**Application:** \`$app_name\`  
**Status:** \`$deployment_result\`  
**Timestamp:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')

The deployment operation failed. Check the logs for more details."
            style="error"
            ;;
        *)
            annotation="ℹ️ **ArgoCD Deployment Update**

**Application:** \`$app_name\`  
**Status:** \`$deployment_result\`  
**Timestamp:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
            style="info"
            ;;
    esac
    
    if buildkite-agent annotate "$annotation" --style "$style" --context "argocd-deployment-$app_name"; then
        log_debug "Deployment annotation created successfully"
    else
        log_warning "Failed to create deployment annotation"
    fi
}

# Create rollback annotation with detailed information
create_rollback_annotation() {
    local app_name="$1"
    local from_revision="$2"
    local to_revision="$3"
    
    log_debug "Creating rollback annotation for $app_name"
    
    local annotation
    annotation="🔄 **ArgoCD Rollback Completed**

**Application:** \`$app_name\`  
**Failed Revision:** \`$from_revision\`  
**Rolled Back To:** \`$to_revision\`  
**Build:** [${BUILDKITE_BUILD_NUMBER:-unknown}](${BUILDKITE_BUILD_URL:-#})  
**Pipeline:** \`${BUILDKITE_PIPELINE_SLUG:-unknown}\`  
**Branch:** \`${BUILDKITE_BRANCH:-unknown}\`  
**Timestamp:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')

The application has been successfully rolled back to the previous stable version."
    
    if buildkite-agent annotate "$annotation" --style "warning" --context "argocd-rollback-$app_name"; then
        log_debug "Rollback annotation created successfully"
    else
        log_warning "Failed to create rollback annotation"
    fi
}

# Send deployment success notification
send_deployment_success_notification() {
    local app_name="$1"
    local previous_version="$2"
    local current_version="$3"
    
    log_info "Sending deployment success notification for $app_name"
    
    local slack_channel
    slack_channel=$(plugin_read_config NOTIFICATIONS_SLACK_CHANNEL "")
    
    if [[ -n "$slack_channel" ]]; then
        local notification_message="🚀 *ArgoCD Deployment*\n\n*Application:* \`$app_name\`\n*Previous Version:* \`$previous_version\`\n*Current Version:* \`$current_version\`\n*Build:* <${BUILDKITE_BUILD_URL:-#}|#${BUILDKITE_BUILD_NUMBER:-unknown}>\n*Pipeline:* \`${BUILDKITE_PIPELINE_SLUG:-unknown}\`\n*Branch:* \`${BUILDKITE_BRANCH:-unknown}\`\n\nDeployment completed successfully and application is healthy."
        
        # Create and upload notification pipeline  
        local notification_pipeline
        notification_pipeline=$(cat <<EOF
steps:
  - label: ":slack: ArgoCD Deployment"
    command: "echo 'Sending success notification to Slack...'"
    notify:
      - slack:
          channels:
            - "$slack_channel"
          message: "$notification_message"
EOF
        )
        
        local pipeline_file
        pipeline_file=$(create_temp_file "success-notification")
        echo "$notification_pipeline" > "$pipeline_file"
        
        if buildkite-agent pipeline upload "$pipeline_file" >/dev/null 2>&1; then
            log_success "Success notification sent to $slack_channel"
        else
            log_warning "Failed to send success notification"
        fi
        
        rm -f "$pipeline_file"
    else
        log_debug "No Slack channel configured for success notifications"
    fi
}

# Validate notification configuration
validate_notification_config() {
    local slack_channel
    slack_channel=$(plugin_read_config NOTIFICATIONS_SLACK_CHANNEL "")
    
    if [[ -n "$slack_channel" ]]; then
        log_info "Notifications enabled for Slack channel: $slack_channel"
        
        # Validate channel format
        if [[ "$slack_channel" =~ ^[#@] ]] || [[ "$slack_channel" =~ ^[A-Z0-9]{9,11}$ ]]; then
            log_debug "Slack channel format is valid"
            return 0
        else
            log_warning "Slack channel format may be invalid: $slack_channel"
            log_info "Expected formats: #channel, @username, or User ID (U123ABC456)"
            return 1
        fi
    else
        log_debug "No Slack notifications configured"
        return 0
    fi
}
