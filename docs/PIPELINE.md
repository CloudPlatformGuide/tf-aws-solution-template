# GitHub Actions Service Deployment Workflow

This document describes how to use the `service-deployment` workflow from the GitHub Actions scripts to deploy services to AWS environments.

## Overview

The service-deployment workflow provides an automated process for deploying infrastructure to AWS environments using Terraform. It handles:

1. Creating and managing Terraform state in S3 with DynamoDB locking
2. Downloading required Terraform modules from a central repository
3. Planning infrastructure changes
4. Applying or destroying infrastructure based on user input

## Prerequisites

Before using the workflow, ensure you have:

1. AWS account credentials configured as GitHub secrets
2. Environment-specific tfvars files in the `environments/` directory
3. Proper IAM roles with OIDC federation for GitHub Actions
4. Access to the S3 bucket containing Terraform modules

## Workflow Inputs

When triggering the workflow, the following inputs are required:

| Input             | Description                          | Required | Default   |
| ----------------- | ------------------------------------ | -------- | --------- |
| account_code      | Customer Account Code                | Yes      | -         |
| region            | AWS Region to deploy services        | No       | us-east-1 |
| apply_changes     | Whether to deploy changes (yes/no)   | Yes      | -         |
| destroy_resources | Whether to delete resources (yes/no) | Yes      | no        |
| tf_version        | Terraform version to use             | Yes      | 1.5.7     |

## Workflow Steps

The workflow consists of the following main jobs:

### 1. Create State

This job:

- Configures AWS credentials using OIDC authentication
- Creates or verifies the existence of an S3 bucket for Terraform state
- Creates or verifies the existence of a DynamoDB table for state locking
- Generates a KMS key for encrypting state data
- Creates a backend configuration file

### 2. Prepare Modules

This job:

- Downloads Terraform modules from the central S3 bucket
- Extracts and organizes modules for use in the deployment

### 3. Plan

This job:

- Configures AWS credentials
- Initializes Terraform with the backend configuration
- Generates a plan using environment-specific variables

### 4. Apply (Conditional)

If `apply_changes` is set to "yes", this job:

- Configures AWS credentials
- Initializes Terraform
- Applies the Terraform plan using the environment-specific variables

### 5. Destroy (Conditional)

If `destroy_resources` is set to "yes", this job:

- Configures AWS credentials
- Initializes Terraform
- Destroys the infrastructure using the environment-specific variables

## How to Use the Workflow

1. **Trigger the workflow manually**:

   - Go to GitHub Actions in your repository
   - Select the "Terraform Deploy Service" workflow
   - Click "Run workflow"
   - Fill in the required inputs

2. **Configure environment-specific variables**:

   - Create a tfvars file in the `environments/` directory with the naming convention `<account_code>.tfvars` (lowercase)
   - Define all required variables for your infrastructure

3. **Monitor the workflow**:
   - The workflow will create the necessary state management resources
   - The plan job will show what changes will be made
   - If approved (apply_changes=yes), the changes will be applied

## AWS Authentication

The workflow uses OIDC (OpenID Connect) authentication to AWS, which eliminates the need for long-lived credentials. This requires:

1. AWS IAM OIDC provider configuration for GitHub
2. IAM roles with appropriate permissions
3. GitHub repository permissions to request the OIDC tokens

## Module Management

Terraform modules are downloaded from a central S3 bucket using the `download-modules.sh` script. This ensures consistent versions of modules across deployments.

The module download process:

1. Lists available modules in the S3 bucket
2. Downloads each module as a zip file
3. Extracts the modules to the specified destination directory
4. Makes the modules available for Terraform to use during deployment

## State Management

Terraform state is managed in S3 with:

- Versioning enabled
- KMS encryption
- DynamoDB table for state locking
- Random suffix for bucket and table names to avoid conflicts

The `terraform-state.sh` script handles:

1. Creating an S3 bucket with the appropriate encryption and permissions
2. Creating a DynamoDB table for state locking
3. Generating a backend configuration file for Terraform

## Secrets Management

The workflow expects the following Github action secrets to be configured on the repository:

1. Customer account IDs with naming convention matching the account_code input (MYACCOUNT=<account_code>)
2. `AWS_ROLE_NAME` for the IAM role to assume
3. `AWS_MODULE_ACCOUNT_ID` for accessing the module repository

## Examples

### Basic Deployment

To deploy infrastructure to a test environment:

1. Trigger the workflow
2. Enter:
   - account_code: TEST
   - region: us-east-1
   - apply_changes: yes
   - destroy_resources: no
   - tf_version: 1.5.7

### Cleanup/Destruction

To remove all resources from an environment:

1. Trigger the workflow
2. Enter:
   - account_code: TEST
   - region: us-east-1
   - apply_changes: no
   - destroy_resources: yes
   - tf_version: 1.5.7

## Troubleshooting

Common issues:

1. **Missing environment file**: Ensure a tfvars file exists for the account_code in lowercase in the environments directory
2. **AWS authentication failures**: Verify IAM roles and OIDC trust relationships
3. **Module download failures**: Check S3 bucket permissions and module paths
4. **State management errors**: Inspect the logs for the create_state job for details
