terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws",
      version = "5.46.0"
    }
  }
}

provider "aws" {}

resource "aws_s3_bucket" "tfstate" {}

output "bucket" {
  value = aws_s3_bucket.tfstate.bucket
}