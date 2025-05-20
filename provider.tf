terraform {
  backend "s3" {
    bucket         = ""
    key            = ""
    region         = ""
    dynamodb_table = ""
    encrypt        = ""
    kms_key_id     = ""
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.84.0"
    }
  }
}

provider "aws" {
  default_tags {
    tags = {
      automation = "true"
    }
  }
}

# provider "awscc" {
# }

