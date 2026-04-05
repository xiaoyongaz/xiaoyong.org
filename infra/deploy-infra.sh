#!/bin/bash
set -euo pipefail

# Deploy the CloudFormation stack for xiaoyong.org
# This must be run in us-east-1 because ACM certs for CloudFront must be in us-east-1

STACK_NAME="xiaoyong-org-site"
TEMPLATE_FILE="$(dirname "$0")/cloudformation.yaml"
REGION="us-east-1"
PROFILE="${AWS_PROFILE:-xiaoyong-personal}"
export AWS_PROFILE="$PROFILE"

# Get the hosted zone ID for xiaoyong.org
echo "Looking up hosted zone for xiaoyong.org..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name xiaoyong.org \
  --query "HostedZones[0].Id" \
  --output text | sed 's|/hostedzone/||')

if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
  echo "ERROR: Could not find hosted zone for xiaoyong.org"
  exit 1
fi

echo "Found hosted zone: $HOSTED_ZONE_ID"
echo "Deploying CloudFormation stack: $STACK_NAME in $REGION..."

aws cloudformation deploy \
  --template-file "$TEMPLATE_FILE" \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --parameter-overrides \
    DomainName=xiaoyong.org \
    HostedZoneId="$HOSTED_ZONE_ID" \
  --no-fail-on-empty-changeset

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output table

echo ""
echo "Done! Note: ACM certificate validation and CloudFront distribution"
echo "propagation may take 5-15 minutes."
