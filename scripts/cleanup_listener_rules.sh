#!/usr/bin/env bash
# Cleanup all non-default listener rules from the shared ALB of an Elastic Beanstalk environment.
#
# Usage:
#   cleanup_listener_rules.sh <environment-name> <application-name>
#
# Notes:
# - Designed to be run from a Terraform destroy-time local-exec provisioner.
# - Requires AWS CLI configured/available in PATH.

set -euo pipefail

ENV_NAME="${1:-}"
APP_NAME="${2:-}"

if [[ -z "$ENV_NAME" || -z "$APP_NAME" ]]; then
  echo "Usage: $0 <environment-name> <application-name>" >&2
  exit 2
fi

echo "Starting cleanup for environment: $ENV_NAME (application: $APP_NAME)"

IS_SHARED=$(aws elasticbeanstalk describe-configuration-settings \
  --application-name "$APP_NAME" \
  --environment-name "$ENV_NAME" \
  --query 'ConfigurationSettings[0].OptionSettings[?Namespace==`aws:elasticbeanstalk:environment` && OptionName==`LoadBalancerIsShared`].Value | [0]' \
  --output text 2>&1)

if [[ "$IS_SHARED" != "true" ]]; then
  echo "Skipping cleanup - not using shared load balancer (IS_SHARED=$IS_SHARED)"
  exit 1
fi

echo "Environment uses shared load balancer, proceeding with cleanup"

ALB_ARN=$(aws elasticbeanstalk describe-configuration-settings \
  --application-name "$APP_NAME" \
  --environment-name "$ENV_NAME" \
  --query 'ConfigurationSettings[0].OptionSettings[?Namespace==`aws:elbv2:loadbalancer` && OptionName==`SharedLoadBalancer`].Value | [0]' \
  --output text 2>&1 )

if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
  echo "Warning: Could not determine ALB ARN from environment settings (ALB_ARN=$ALB_ARN), skipping cleanup"
  exit 2
fi

echo "Found ALB ARN: $ALB_ARN"

echo "Cleaning up listener rules for ALB: $ALB_ARN"
LISTENER_ARNS=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].ListenerArn' \
  --output text 2>&1 )

if [[ -z "$LISTENER_ARNS" || "$LISTENER_ARNS" == "None" ]]; then
  echo "No listeners found for ALB, continue...."
  exit 0 #terraform will continue here
fi

echo "Found listeners: $LISTENER_ARNS"

for LISTENER_ARN in $LISTENER_ARNS; do

  RULE_ARNS=$(aws elbv2 describe-rules \
    --listener-arn "$LISTENER_ARN" \
    --query "Rules[?Priority!='default'].RuleArn" \
    --output text 2>&1 )

  if [[ -z "$RULE_ARNS" || "$RULE_ARNS" == "None" ]]; then
    echo "  No rules to delete for this listener"
    continue
  fi

  echo "  Found rules to delete: $RULE_ARNS"

  for RULE_ARN in $RULE_ARNS; do
    PRIORITY=$(aws elbv2 describe-rules \
      --rule-arns "$RULE_ARN" \
      --query 'Rules[0].Priority' \
      --output text 2>&1 )

    echo "  Attempting to delete rule at priority $PRIORITY (ARN: $RULE_ARN)"

    if OUT=$(aws elbv2 delete-rule --rule-arn "$RULE_ARN" 2>&1); then
      echo "    ✓ Successfully deleted rule at priority $PRIORITY"
    else
      echo "    ✗ Failed to delete rule at priority $PRIORITY: $OUT"
    fi
  done

done

echo "Cleanup complete"
