#!/bin/bash
# notifications.bash - Notification and annotation functions for ArgoCD operations

# Create standardized notification message template
create_notification_template() {
    local app_name="$1"
    local status="$2"
    local from_label="$3"
    local from_value="$4"
    local to_label="$5"
    local to_value="$6"
    local footer="$7"
    
    local message="*Application:* \`$app_name\`
*Status:* $status
*$from_label Revision:* \`$from_value\`
*$to_label Revision:* \`$to_value\`
*Build:* <${BUILDKITE_BUILD_URL:-#}|#${BUILDKITE_BUILD_NUMBER:-unknown}>
*Pipeline:* \`${BUILDKITE_PIPELINE_SLUG:-unknown}\`
*Branch:* \`${BUILDKITE_BRANCH:-unknown}\`"
    
    if [[ -n "$footer" ]]; then
        message="$message

$footer"
    fi
    
    echo "$message"
}

# Unified notification system for all ArgoCD operations
send_notification() {
    local app_name="$1"
    local notification_type="$2"
    local from_revision="$3"
    local to_revision="$4"
    
    log_info "Preparing $notification_type notification for $app_name"
    log_debug "Notification details: type=$notification_type, from=$from_revision, to=$to_revision"
    
    local slack_channel
    slack_channel=$(plugin_read_config NOTIFICATIONS_SLACK_CHANNEL "")
    
    # Send Slack notification using Buildkite's native integration
    if [[ -n "$slack_channel" ]]; then
        log_info "Sending Slack notification to $slack_channel..."
        
        # Create notification message and determine header
        local notification_message
        local notification_label
        local status
        local from_label
        local to_label
        local footer
        
        case "$notification_type" in
            "deployment_success")
                notification_label=":rocket: ArgoCD Deployment Passed"
                status="Deployment successful"
                from_label="Previous"
                to_label="Current"
                footer="Deployment completed successfully and application is healthy."
                ;;
            "deployment_failed_auto")
                notification_label=":x: ArgoCD Deployment Failed"
                status="Deployment failed - Auto rollback in progress"
                from_label="Current"
                to_label="Target"
                footer="Automatic rollback initiated..."
                ;;
            "deployment_failed_manual")
                notification_label=":x: ArgoCD Deployment Failed"
                status="Deployment failed - Manual decision required"
                from_label="Current"
                to_label="Target"
                footer="Manual rollback decision required on pipeline."
                ;;
            "rollback_success_auto")
                notification_label=":arrows_counterclockwise: ArgoCD Rollback Passed"
                status="Auto rollback successful"
                from_label="From"
                to_label="To"
                footer=""
                ;;
            "rollback_success_manual")
                notification_label=":arrows_counterclockwise: ArgoCD Rollback Passed"
                status="Manual rollback successful"
                from_label="From"
                to_label="To"
                footer=""
                ;;
            "rollback_failed_auto")
                notification_label=":x: ArgoCD Rollback Failed"
                status="Auto rollback failed"
                from_label="From"
                to_label="Target"
                footer="Manual investigation required. Check logs for details."
                ;;
            "rollback_failed_manual")
                notification_label=":x: ArgoCD Rollback Failed"
                status="Manual rollback failed"
                from_label="From"
                to_label="Target"
                footer="Manual investigation required. Check logs for details."
                ;;
        esac
        
        notification_message=$(create_notification_template "$app_name" "$status" "$from_label" "$from_revision" "$to_label" "$to_revision" "$footer")
        
        # Escape the message for YAML (replace newlines with \n)
        local escaped_message
        escaped_message=$(echo "$notification_message" | sed ':a;N;$!ba;s/\n/\\n/g')
        
        # Inject notification step using Buildkite's native Slack integration
        local notification_pipeline
        notification_pipeline=$(cat <<-EOF
steps:
  - label: "$notification_label"
    command: "echo 'Sending notification to Slack...'"
    notify:
      - slack:
          channels:
            - "$slack_channel"
          message: "$escaped_message"
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

# Legacy wrapper for deployment success notifications (for backward compatibility)
send_deployment_success_notification() {
    local app_name="$1"
    local previous_version="$2"
    local current_version="$3"
    
    send_notification "$app_name" "deployment_success" "$previous_version" "$current_version"
}

# Legacy wrapper for rollback notifications (for backward compatibility)
send_rollback_notification() {
    local app_name="$1"
    local from_revision="$2"
    local to_revision="$3"
    local reason="$4"
    
    # Map old reason codes to new notification types
    case "$reason" in
        "deployment_failed_auto_rollback")
            send_notification "$app_name" "deployment_failed_auto" "$from_revision" "$to_revision"
            ;;
        "auto_rollback_success")
            send_notification "$app_name" "rollback_success_auto" "$from_revision" "$to_revision"
            ;;
        "deployment_failed_manual")
            send_notification "$app_name" "deployment_failed_manual" "$from_revision" "$to_revision"
            ;;
        "manual_rollback_success")
            send_notification "$app_name" "rollback_success_manual" "$from_revision" "$to_revision"
            ;;
        *)
            log_warning "Unknown notification reason: $reason"
            ;;
    esac
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
