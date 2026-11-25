# Serverless data lake — Terraform scaffold
# SCAFFOLD — not applied. Reviewed, planned and costed in the
# implementation session before any apply. Region: us-east-1.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region for the lake"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used as the prefix for resource names"
  type        = string
  default     = "serverless-data-lake"
}

variable "feed_url" {
  description = "Public JSON feed the Lambda pulls on schedule"
  type        = string
  default     = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson"
}

# --- S3 raw zone ----------------------------------------------------------

resource "aws_s3_bucket" "lake" {
  bucket = "${var.project_name}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}

# --- Lambda fetcher --------------------------------------------------------

resource "aws_iam_role" "fetcher" {
  name = "${var.project_name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "fetcher" {
  name = "${var.project_name}-lambda"
  role = aws_iam_role.fetcher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Effect   = "Allow"
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Action   = ["s3:PutObject"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.lake.arn}/raw/*"
      }
    ]
  })
}

data "archive_file" "fetcher" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/fetcher.zip"
}

resource "aws_lambda_function" "fetcher" {
  function_name = "${var.project_name}-fetch"
  role          = aws_iam_role.fetcher.arn
  handler       = "fetch_feed.handler"
  runtime       = "python3.12"
  timeout       = 60

  filename         = data.archive_file.fetcher.output_path
  source_code_hash = data.archive_file.fetcher.output_base64sha256

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.lake.id
      FEED_URL    = var.feed_url
    }
  }
}

# --- Hourly schedule -------------------------------------------------------

resource "aws_cloudwatch_event_rule" "hourly" {
  name                = "${var.project_name}-hourly"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "fetcher" {
  rule      = aws_cloudwatch_event_rule.hourly.name
  target_id = "fetcher"
  arn       = aws_lambda_function.fetcher.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fetcher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.hourly.arn
}

# --- Glue catalogue + Athena ----------------------------------------------

resource "aws_glue_catalog_database" "lake" {
  name = replace(var.project_name, "-", "_")
}

resource "aws_glue_crawler" "raw" {
  name          = "${var.project_name}-raw"
  database_name = aws_glue_catalog_database.lake.name
  role          = aws_iam_role.crawler.arn

  s3_target {
    path = "s3://${aws_s3_bucket.lake.id}/raw/"
  }

  # Runs on demand in the implementation session; schedule added only if
  # Steven wants it crawling hourly on its own.
}

resource "aws_iam_role" "crawler" {
  name = "${var.project_name}-crawler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })

  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"]
}

resource "aws_athena_workgroup" "lake" {
  name = var.project_name

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.lake.id}/athena-results/"
    }
  }
}

output "bucket_name" {
  value = aws_s3_bucket.lake.id
}

output "lambda_name" {
  value = aws_lambda_function.fetcher.function_name
}

output "glue_database" {
  value = aws_glue_catalog_database.lake.name
}
