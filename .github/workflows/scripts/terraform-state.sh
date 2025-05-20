#!/bin/bash
set -x
set -e
trap 'echo "Error on line $LINENO"; exit 1' ERR  # set up error handler


# Generate random suffix
function random_suffix() {
  local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  local suffix=""
  for i in {1..8}; do
    suffix+="${chars:RANDOM%${#chars}:1}"
  done
  echo "$suffix"
}

# Terrafom drift detection
function terraform::drift_detection() {
    local varfile=$1
    # Run Terraform plan with detailed exit codes
    terraform plan -var-file=${varfile} -detailed-exitcode -out tf.plan > /dev/null 2>&1
    PLAN_EXIT_CODE=$?

    # Debugging: Print the exit code and check if the plan file was created
    #echo "Terraform plan exit code: $PLAN_EXIT_CODE"
     
    terraform show -json tf.plan > tfplan.json

    CHANGES=$(jq '[.resource_changes[] | select(.change.actions | index("create") or index("update") or index("delete"))] | length' tfplan.json)

    # Interpret the exit code
    if [[ "$CHANGES" -gt 0 ]]; then
        cat tfplan.json | jq '.resource_changes[] | select(.change.actions | index("create") or index("update") or index("delete")) | {address, change: {before: (if .change.before != null then .change.before | with_entries(if (.value | type) == "string" and ((.value | startswith("{")) or (.value | startswith("["))) then .value |= fromjson else . end) else null end), after: (if .change.after != null then .change.after | with_entries(if (.value | type) == "string" and ((.value | startswith("{")) or (.value | startswith("["))) then .value |= fromjson else . end) else null end)}}' > tf_changes.json

        echo "Drift found"

    elif [[ "$CHANGES" -eq 0 ]]; then
        echo "No changes"
    else
        echo "Terraform plan failed with exit code $PLAN_EXIT_CODE."
    fi
}

# Generate S3 policy
function terraform::generate_s3_policy() {
  local bucket_name=$1
  shift 1 
  local roles=("$@")
  account_id=$(aws sts get-caller-identity --query 'Account' --output text)
  local principal=""
  for role in "${roles[@]}"
  do
    if [[ $role == ${roles[-1]} ]]; then
        principal+="\"arn:aws:iam::$account_id:role/$role\""
    else
        principal+="\"arn:aws:iam::$account_id:role/$role\","
    fi
  done
  echo "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
        {
            \"Effect\": \"Allow\",
            \"Principal\": {
                \"AWS\": [
                    \"arn:aws:iam::${account_id}:root\",
                    $principal
                ]
            },
            \"Action\": \"s3:*\",
            \"Resource\":  [
                \"arn:aws:s3:::${bucket_name}\",
                \"arn:aws:s3:::${bucket_name}/*\"
            ]
        }
    ]
  }"
}

#account_id=$(terraform::generate_kms_policy | grep -oP '(?<=\"AWS\": \[\n\s+\"arn:aws:iam::)\d+(?=:root\")')

# Generate KMS policy
function terraform::generate_kms_policy() {
  local roles=("$@")
  account_id=$(aws sts get-caller-identity --query 'Account' --output text)
  local principal=""
  for role in "${roles[@]}"
  do
    if [[ $role == ${roles[-1]} ]]; then
        principal+="\"arn:aws:iam::$account_id:role/$role\""
    else
        principal+="\"arn:aws:iam::$account_id:role/$role\","
    fi
  done

  #principal="${principal::-1}"
  echo "{
           \"Id\": \"key-policy\",
            \"Version\": \"2012-10-17\",
            \"Statement\": [
                {
                \"Sid\": \"AllowRoot\",
                \"Effect\": \"Allow\",
                \"Principal\": {
                    \"AWS\":\"arn:aws:iam::$account_id:root\"
                },
                \"Action\": \"kms:*\",
                \"Resource\": \"*\"
                },
                {
                \"Sid\": \"AllowTerraformRoles\",
                \"Effect\": \"Allow\",
                \"Principal\": {
                    \"AWS\": [
                    \"arn:aws:iam::$account_id:root\",
                    $principal
                    ]
                },
                \"Action\": [
                    \"kms:Encrypt\",
                    \"kms:Decrypt\",
                    \"kms:ReEncrypt*\",
                    \"kms:GenerateDataKey*\"
                ],
                \"Resource\": \"*\"
                }
            ]
        }"
 }


# Create Terraform backend file
function terraform::create_backend_file() {
  echo "Attempting to create backend file"s
  local bucket_name=$1
  local dynamo_table=$2
  local kms_key=$3
  local region=$4

  cat > state.config <<EOL
  bucket         = "$bucket_name"
  key            = "terraform.tfstate"
  region         = "$region"
  dynamodb_table = "$dynamo_table"
  encrypt        = true
  kms_key_id     = "$kms_key"
EOL
echo "created backend state.config"
}

# Check if S3 bucket and DynamoDB table exist
function terraform::check_state() {
    echo "Attempting to check state"

  if aws s3api head-bucket --bucket $1 2>/dev/null; then
    echo "Bucket exists"
  else
    echo "Bucket does not exist"
  fi
  
  if aws dynamodb describe-table --table-name $2 2>/dev/null; then
    echo "Table exists"
  else
    echo "Table does not exist"
  fi
}

# Create KMS Key
function terraform::create_state_kms_key() {
  local roles=("$@")
  policy=$(terraform::generate_kms_policy "${roles[@]}")
  kms_key=$(aws kms create-key --policy "$policy" --query 'KeyMetadata.KeyId' --output text)
  echo $kms_key
}

# Create S3 bucket
function terraform::create_bucket() {
  local bucket_name=$1
  echo "Bucket Name: $bucket_name"  # Debug print
  local region=$2
  echo "Region: $region"  # Debug print
  shift 2
  local roles=("$@")

  if aws s3api head-bucket --bucket $1 2>/dev/null; then
    echo "Bucket exists"
    exit 0
  fi

  account_id=$(aws sts get-caller-identity --query 'Account' --output text)
  kms_key=$(terraform::create_state_kms_key "${roles[@]}")
  policy=$(terraform::generate_s3_policy "${bucket_name}" "${roles[@]}")

  if [[ "$region" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$bucket_name"
  else
    aws s3api create-bucket --bucket "$bucket_name" --create-bucket-configuration   LocationConstraint="$region"
  fi

  aws s3api put-bucket-policy --bucket "$bucket_name" --policy "$policy"
  aws s3api put-bucket-encryption --bucket "$bucket_name" --server-side-encryption-configuration "{
    \"Rules\": [
        {
            \"ApplyServerSideEncryptionByDefault\": {
                \"SSEAlgorithm\": \"aws:kms\",
                \"KMSMasterKeyID\": \"arn:aws:kms:$region:$account_id:key/$kms_key\"
            }
        }
    ]
}"
  echo $kms_key
}

# Create DynamoDB table
function terraform::create_table() {
  aws dynamodb create-table --table-name $1 --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --provisioned-throughput ReadCapacityUnits=2,WriteCapacityUnits=2
}

# Main function
function terraform::create_state() {
  local add_suffix=$1
  local bucket_name=$2
  local table_name=$3
  local region=$4
 
  shift 4
  local roles=("$@")

  if [ "$add_suffix" = true ]; then
    bucket_name="${bucket_name}-$(random_suffix)"
    table_name="${table_name}-$(random_suffix)"
  fi
  
  echo "::notice:: bucket=${bucket_name} region=${region} roles=${roles[@]}"

  if aws s3api head-bucket --bucket $bucket_name 2>/dev/null; then
    echo "::notice::Bucket exists"
    #Need to get the KMS key used by the bucket
    kms_key=$(aws s3api get-bucket-encryption --bucket "$bucket_name" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' --output text)
  else
    kms_key=$(terraform::create_bucket "${bucket_name}" "${region}" "${roles[@]}")
  fi
  
  if aws dynamodb describe-table --table-name $table_name 2>/dev/null; then
    echo "::notice::Table exists"
  else
    terraform::create_table "$table_name"
  fi

  terraform::create_backend_file "$bucket_name" "$table_name" "$kms_key" "$region"
}


# **Ensure function execution when script is called**
if [[ "$#" -gt 0 ]]; then
  "$@"
else
  echo "No function specified! Usage: ./terraform-state.sh function_name [args...]"
  exit 1
fi

# Execute main function
# terraform::create_state [true/false for random suffix] [bucket_name] [table_name] [roles...]
# terraform::create_state true "exampleBucket" "exampleTable" "role1" "role2"

