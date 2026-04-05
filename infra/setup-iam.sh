#!/bin/bash
set -euo pipefail

# Create IAM user and policy for GitHub Actions deployment

USER_NAME="github-deploy-xiaoyong-org"
POLICY_NAME="xiaoyong-org-deploy"
POLICY_FILE="$(dirname "$0")/github-deploy-policy.json"

echo "Creating IAM user: $USER_NAME..."
aws iam create-user --user-name "$USER_NAME" 2>/dev/null || echo "User already exists"

echo "Creating IAM policy..."
POLICY_ARN=$(aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://$POLICY_FILE" \
  --query "Policy.Arn" \
  --output text 2>/dev/null || \
  aws iam list-policies \
    --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" \
    --output text)

echo "Attaching policy to user..."
aws iam attach-user-policy \
  --user-name "$USER_NAME" \
  --policy-arn "$POLICY_ARN"

echo "Creating access key..."
aws iam create-access-key \
  --user-name "$USER_NAME" \
  --output json

echo ""
echo "IMPORTANT: Save the AccessKeyId and SecretAccessKey above!"
echo "Add these as GitHub repo secrets:"
echo "  AWS_ACCESS_KEY_ID"
echo "  AWS_SECRET_ACCESS_KEY"
echo ""
echo "Also add these secrets (get values from CloudFormation stack outputs):"
echo "  S3_BUCKET_NAME"
echo "  CLOUDFRONT_DISTRIBUTION_ID"
