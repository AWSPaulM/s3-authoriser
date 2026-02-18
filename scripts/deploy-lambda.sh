#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PATH="${SCRIPT_DIR}/../cloudformation/lambda-edge.yaml"

usage() {
  cat <<EOF
Usage: $(basename "$0") --stack-name <name> --distribution-id <id> FOLDER_<name>=<password> [FOLDER_<name>=<password> ...]

Required parameters:
  --stack-name       CloudFormation stack name for the Lambda@Edge stack
  --distribution-id  Existing CloudFront distribution ID

Positional arguments:
  FOLDER_<name>=<password>  One or more folder-password mappings

Example:
  $(basename "$0") --stack-name my-lambda-stack --distribution-id E1234567890 \\
    FOLDER_secret-docs=mypassword FOLDER_finance=budget2026
EOF
  exit 1
}

STACK_NAME=""
DISTRIBUTION_ID=""
FOLDER_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --distribution-id)
      DISTRIBUTION_ID="$2"
      shift 2
      ;;
    FOLDER_*)
      FOLDER_ARGS+=("$1")
      shift
      ;;
    *)
      echo "Error: Unknown parameter '$1'"
      usage
      ;;
  esac
done

if [[ -z "$STACK_NAME" || -z "$DISTRIBUTION_ID" || ${#FOLDER_ARGS[@]} -eq 0 ]]; then
  echo "Error: Missing required parameters."
  usage
fi

# Convert FOLDER_<name>=<password> arguments into a JSON string
build_password_map_json() {
  local json="{"
  local first=true
  for arg in "${FOLDER_ARGS[@]}"; do
    local stripped="${arg#FOLDER_}"
    local folder_name="${stripped%%=*}"
    local password="${stripped#*=}"
    if [[ "$first" == true ]]; then
      first=false
    else
      json+=","
    fi
    json+="\"${folder_name}\":\"${password}\""
  done
  json+="}"
  echo "$json"
}

PASSWORD_MAP_JSON=$(build_password_map_json)

echo "Deploying Lambda@Edge stack '${STACK_NAME}' in us-east-1..."
echo "Distribution ID: ${DISTRIBUTION_ID}"
echo "Password map: ${PASSWORD_MAP_JSON}"
echo ""

if ! aws cloudformation deploy \
  --template-file "${TEMPLATE_PATH}" \
  --stack-name "${STACK_NAME}" \
  --parameter-overrides \
    DistributionId="${DISTRIBUTION_ID}" \
    PasswordMapJson="${PASSWORD_MAP_JSON}" \
  --capabilities CAPABILITY_IAM \
  --region us-east-1 \
  --no-fail-on-empty-changeset; then
  echo "Error: CloudFormation deployment failed."
  echo "Check the AWS CloudFormation console for details on stack '${STACK_NAME}' in us-east-1."
  exit 1
fi

echo ""
echo "Stack deployed successfully. Retrieving Lambda version ARN..."

LAMBDA_VERSION_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='LambdaVersionArn'].OutputValue" \
  --output text)

if [[ -z "$LAMBDA_VERSION_ARN" || "$LAMBDA_VERSION_ARN" == "None" ]]; then
  echo "Error: Could not retrieve Lambda version ARN from stack outputs."
  exit 1
fi

echo "Lambda Version ARN: ${LAMBDA_VERSION_ARN}"
echo ""

echo "Attaching Lambda@Edge to CloudFront distribution '${DISTRIBUTION_ID}'..."

# Get current distribution config and ETag
DIST_CONFIG_OUTPUT=$(aws cloudfront get-distribution-config --id "${DISTRIBUTION_ID}")
ETAG=$(echo "$DIST_CONFIG_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['ETag'])")
DIST_CONFIG=$(echo "$DIST_CONFIG_OUTPUT" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['DistributionConfig']))")

# Update the distribution config to add Lambda@Edge viewer-request association
UPDATED_CONFIG=$(echo "$DIST_CONFIG" | python3 -c "
import sys, json

config = json.load(sys.stdin)
lambda_arn = '${LAMBDA_VERSION_ARN}'

# Build the Lambda function association for viewer-request
lambda_association = {
    'LambdaFunctionARN': lambda_arn,
    'EventType': 'viewer-request',
    'IncludeBody': False
}

# Get or create the LambdaFunctionAssociations in default cache behavior
cache_behavior = config['DefaultCacheBehavior']
associations = cache_behavior.get('LambdaFunctionAssociations', {'Quantity': 0, 'Items': []})

# Ensure Items list exists
if 'Items' not in associations:
    associations['Items'] = []

# Remove any existing viewer-request association
associations['Items'] = [a for a in associations['Items'] if a.get('EventType') != 'viewer-request']

# Add the new viewer-request association
associations['Items'].append(lambda_association)
associations['Quantity'] = len(associations['Items'])

cache_behavior['LambdaFunctionAssociations'] = associations
config['DefaultCacheBehavior'] = cache_behavior

print(json.dumps(config))
")

# Update the distribution
if ! aws cloudfront update-distribution \
  --id "${DISTRIBUTION_ID}" \
  --distribution-config "${UPDATED_CONFIG}" \
  --if-match "${ETAG}"; then
  echo "Error: Failed to update CloudFront distribution."
  exit 1
fi

echo ""
echo "Waiting for CloudFront distribution deployment..."
aws cloudfront wait distribution-deployed --id "${DISTRIBUTION_ID}"

echo ""
echo "=== Deployment Complete ==="
echo "Lambda@Edge function attached to distribution '${DISTRIBUTION_ID}'."
echo ""
echo "Protected folders:"
for arg in "${FOLDER_ARGS[@]}"; do
  local_stripped="${arg#FOLDER_}"
  local_folder="${local_stripped%%=*}"
  echo "  - ${local_folder}"
done
