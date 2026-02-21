# Note: Backend bucket names must be unique. 
# Update the bucket name after deploying the CloudFormation template.

terraform {
  backend "s3" {
    # Replace <AWS_ACCOUNT_ID> with your actual AWS Account ID after running CloudFormation
    # bucket         = "basic-iac-pipeline-terraform-state-<AWS_ACCOUNT_ID>"
    # key            = "state/terraform.tfstate"
    # region         = "us-east-1"
    # dynamodb_table = "basic-iac-pipeline-terraform-locks"
    # encrypt        = true
  }
}
