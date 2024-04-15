terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.44.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

variable "github_repo" {
  type    = string
  default = "realtime_dashboard"
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "aws-profile" {
  type    = string
  default = "jarrod-sso"
}

# Configure the AWS Provider with SSO profile
provider "aws" {
  region = var.region
  profile = var.aws-profile
}

# Configure the GitHub Provider for React frontend CI/CD
provider "github" {}

#Create s3 bucket for uploading an object
resource "aws_s3_bucket" "upload_bucket_logs" {
 bucket = join("-", ["object-upload-bucket", uuid()])
}

resource "aws_s3_bucket_cors_configuration" "upload_bucket_logs" {
  bucket = aws_s3_bucket.upload_bucket_logs.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }

  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
  }
}


#Create sns topic for the s3 object upload
resource "aws_sns_topic" "s3_object_upload_topic" {
  name = "s3_object_upload_topic"
}


#Create dynamodb table to store object metadata
resource "aws_dynamodb_table" "logs" {
  name         = "logs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "Id"

  attribute {
    name = "Id"
    type = "S"
  }
}


#Create lambda s3 CreateObject event trigger
resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_upload_function.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.upload_bucket_logs.arn
}


#Create lambda execution assume role policy
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}


#Create lambda execution role
resource "aws_iam_role" "iam_for_lambda" {
  name               = "upload-notification-lambda-role-policy"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  inline_policy {
    name = "LambdaUploadNotificationPolicy"

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action   = ["sns:Publish"]
          Effect   = "Allow"
          Resource = aws_sns_topic.s3_object_upload_topic.arn
        },
        {
          Action   = ["dynamodb:PutItem"]
          Effect   = "Allow"
          Resource = aws_dynamodb_table.logs.arn
        },
        {
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ],
          Effect   = "Allow",
          Resource = "*"
        }
      ]
    })
  }
}


#Create the lambda function
resource "aws_lambda_function" "s3_upload_function" {
  function_name = "s3_upload_lambda"
  filename      = "index.zip"
  role          = aws_iam_role.iam_for_lambda.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"

  environment {
    variables = {
      "dynamo_db_table" = aws_dynamodb_table.logs.arn
    }
  }
}

resource "aws_lambda_function_event_invoke_config" "s3_upload_function" {
  function_name =aws_lambda_function.s3_upload_function.function_name

  destination_config {
    on_success {
      destination = aws_sns_topic.s3_object_upload_topic.arn
    }
  }
}

#Create bucket notification
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.upload_bucket_logs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_upload_function.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_bucket]
}


#Create action secrets for the frontend github repo to build and upload to s3 and invalidate cloudfront distribution

resource "github_actions_secret" "aws_access_key_id" {
  repository       = var.github_repo
  secret_name      = "AWS_ACCESS_KEY_ID"
  plaintext_value  = aws_iam_access_key.github_access_key.id
}

resource "github_actions_secret" "aws_secret_access_key" {
  repository       = var.github_repo
  secret_name      = "AWS_SECRET_ACCESS_KEY"
  plaintext_value  = aws_iam_access_key.github_access_key.secret
}

resource "github_actions_secret" "aws_default_region" {
  repository       = var.github_repo
  secret_name      = "AWS_DEFAULT_REGION"
  plaintext_value  = var.region
}

resource "github_actions_secret" "aws_cloudfront_dist_id" {
  repository       = var.github_repo
  secret_name      = "AWS_CLOUDFRONT_DIST_ID"
  plaintext_value  = aws_cloudfront_distribution.s3_distribution.id
}

resource "github_actions_secret" "aws_s3_bucket" {
  repository       = var.github_repo
  secret_name      = "AWS_S3_BUCKET"
  plaintext_value  = aws_s3_bucket.upload_website_bucket.bucket
}


#Creat IAM user for github
resource "aws_iam_user" "github" {
  name = "github"
}

resource "aws_iam_access_key" "github_access_key" {
  user    = aws_iam_user.github.name
}

data "aws_iam_policy_document" "github_user_policy" {
  statement {
    effect    = "Allow"
    actions   = ["s3:*Object", "s3:ListBucket", "cloudfront:CreateInvalidation"]
    resources = [aws_s3_bucket.upload_website_bucket.arn, "${aws_s3_bucket.upload_website_bucket.arn}/*", aws_cloudfront_distribution.s3_distribution.arn]
  }
}

resource "aws_iam_user_policy" "github_user_policy" {
  name   = "github-user-policy"
  user   = aws_iam_user.github.name
  policy = data.aws_iam_policy_document.github_user_policy.json
}

#Create s3 bucket for hosting the react frontend
resource "aws_s3_bucket" "upload_website_bucket" {
 bucket = join("-", ["upload-frontend-bucket", uuid()])
}

#Bucket policy to allow cloudfront access to s3 bucket
resource "aws_s3_bucket_policy" "allow_access_from_cloudfront" {
  bucket = aws_s3_bucket.upload_website_bucket.id
  policy = data.aws_iam_policy_document.allow_access_from_cloudfront.json
}

data "aws_iam_policy_document" "allow_access_from_cloudfront" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions = [
      "s3:GetObject"
    ]

    resources = [
      "${aws_s3_bucket.upload_website_bucket.arn}/*",
    ]

    condition {
      values = [ aws_cloudfront_distribution.s3_distribution.arn ]
      test = "StringEquals"
      variable = "AWS:SourceArn"
    }
  }
}


#Create cloudfront distribution for react frontend hosted on s3
locals {
  s3_origin_id = "s3-upload-frontend-origin"
}

resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "s3_upload_frontend_oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = aws_s3_bucket.upload_website_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
    origin_id                = local.s3_origin_id
  }

  enabled             = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 300
    max_ttl                = 300
  }

  price_class = "PriceClass_All"

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}