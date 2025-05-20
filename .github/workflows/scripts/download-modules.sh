#!/bin/bash

# Function to download Terraform modules from S3 bucket
# Usage: download_tf_modules "bucket-name" "destination-dir"
download_tf_modules() {
  local s3_bucket="$1"
  local dest_dir="${2:-S3_modules}"
  
  echo "Creating destination directory: $dest_dir"
  mkdir -p "$dest_dir"
  
  echo "Listing modules in s3://$s3_bucket/modules/"
  modules=$(aws s3 ls "s3://$s3_bucket/modules/" | grep ".zip" | awk '{print $4}')
  
  if [ -z "$modules" ]; then
    echo "No modules found in s3://$s3_bucket/modules/"
    return 1
  fi
  
  echo "Found the following modules:"
  echo "$modules"
  
  # Create a temp directory for extraction
  local temp_dir="$dest_dir/temp"
  mkdir -p "$temp_dir"
  
  # Download and extract each module
  for module_zip in $modules; do
    echo "Downloading $module_zip..."
    aws s3 cp "s3://$s3_bucket/modules/$module_zip" "$temp_dir/"
    
    # Get module name from zip filename (preserve the version)
    module_name=$(echo "$module_zip" | sed 's/\.zip$//')
    
    # Create directory for the module with version
    mkdir -p "$dest_dir/$module_name"
    
    echo "Extracting $module_zip to $dest_dir/$module_name"
    unzip -q -o "$temp_dir/$module_zip" -d "$dest_dir/$module_name"
    
    echo "Module $module_name installed successfully"
  done
  
  # Clean up temp directory
  rm -rf "$temp_dir"
  
  echo "All Terraform modules have been downloaded to $dest_dir"
  return 0
}

# If the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Check if bucket name is provided
  if [ -z "$1" ]; then
    echo "Error: S3 bucket name is required"
    echo "Usage: $0 <s3-bucket-name> [destination-directory]"
    exit 1
  fi
  
  # Execute the function with provided arguments
  download_tf_modules "$1" "$2"
fi