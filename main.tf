resource "aws_s3_bucket" "app_bucket" {
  bucket = "my-learning-app-bucket-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "LearningBucket"
    Environment = "Dev"
  }
}

data "aws_caller_identity" "current" {}

output "bucket_name" {
  value = aws_s3_bucket.app_bucket.id
}
