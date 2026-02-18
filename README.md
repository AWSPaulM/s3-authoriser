# CloudFront Folder Password Protection

This solution adds password protection to specific folders in your S3 bucket served through CloudFront. When a user navigates to a protected folder, their browser will display a login prompt. Only the correct password grants access — the username field can be anything.

## Prerequisites

- AWS CLI v2 installed and configured with credentials
- Python 3 (used internally by the deploy script)
- Bash shell (macOS, Linux, or WSL on Windows)
- Your AWS account must have permissions to:
  - Create CloudFormation stacks
  - Create Lambda functions and IAM roles
  - Update CloudFront distributions

## What's Included

| File | Purpose |
|------|---------|
| `cloudformation/lambda-edge.yaml` | CloudFormation template for the Lambda@Edge function |
| `scripts/deploy-lambda.sh` | Deploy script that sets everything up |

## Deployment

Run the deploy script with your CloudFront distribution ID and the folders you want to protect:

```bash
./scripts/deploy-lambda.sh \
  --stack-name my-password-protection \
  --distribution-id E1234567890ABC \
  FOLDER_confidential-docs=mypassword \
  FOLDER_finance-reports=budget2026
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--stack-name` | Yes | A name for the CloudFormation stack (your choice) |
| `--distribution-id` | Yes | Your existing CloudFront distribution ID |
| `FOLDER_<name>=<password>` | Yes (at least one) | Folder-to-password mappings |

### Folder Mapping Format

Each `FOLDER_` argument maps a top-level S3 folder to a password:

- `FOLDER_secret-docs=pass123` protects everything under `/secret-docs/`
- `FOLDER_finance=budget2026` protects everything under `/finance/`

Folders not listed are publicly accessible through CloudFront as normal.

## How It Works

- A Lambda@Edge function is deployed to `us-east-1` (required by AWS for Lambda@Edge, regardless of your region)
- The function intercepts every viewer request to your CloudFront distribution
- If the request path matches a protected folder, the browser is prompted for a password via HTTP Basic Auth
- Unprotected folders and root-level files are served normally without any prompt

## Updating Passwords or Folders

To change passwords, add new protected folders, or remove protection from a folder, re-run the deploy script with the updated `FOLDER_` arguments:

```bash
./scripts/deploy-lambda.sh \
  --stack-name my-password-protection \
  --distribution-id E1234567890ABC \
  FOLDER_confidential-docs=newpassword \
  FOLDER_finance-reports=budget2026 \
  FOLDER_hr-documents=hrpass2026
```

The script updates the Lambda function with the new configuration. Allow a few minutes for CloudFront to propagate the changes.

## Removing Password Protection

To remove the solution entirely, delete the CloudFormation stack:

```bash
aws cloudformation delete-stack --stack-name my-password-protection --region us-east-1
```

Then manually remove the Lambda@Edge association from your CloudFront distribution's default cache behavior in the AWS Console, or wait for the Lambda function replicas to expire (this can take several hours).

## Notes

- The username field in the browser's login prompt is ignored — only the password matters
- Protection applies to the top-level folder only (e.g., `FOLDER_docs=pass` protects `/docs/`, `/docs/sub/file.pdf`, etc.)
- If the Lambda function encounters an unexpected error, it fails open — requests are passed through to avoid blocking access to your content
- The Lambda function is always deployed to `us-east-1` as required by AWS for Lambda@Edge functions
