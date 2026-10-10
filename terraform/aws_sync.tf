###############################################################################
# AWS — Replicación DynamoDB Streams → Lambda → Firestore (GCP) vía WIF
###############################################################################

# La imagen de contenedor se construye y sube con scripts/build-sync.sh
locals {
  sync_image_uri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com/never-down-sync:latest"
}

# Permite que el servicio Lambda haga pull de la imagen del repo ECR
resource "aws_ecr_repository_policy" "sync" {
  repository = "never-down-sync"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaECRImageRetrievalPolicy"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ]
    }]
  })
}

# --- IAM del Lambda de sync ---
# El nombre del rol es fijo porque WIF (GCP) confía en este ARN exacto:
#   arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/never-down-sync-role
resource "aws_iam_role" "sync" {
  name = "never-down-sync-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "sync" {
  name = "${var.project_name}-sync-policy"
  role = aws_iam_role.sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:DescribeStream",
          "dynamodb:ListStreams"
        ]
        Resource = aws_dynamodb_table.orders.stream_arn
      }
    ]
  })
}

# --- Lambda de sync (imagen de contenedor, arm64) ---
resource "aws_lambda_function" "sync" {
  function_name = "${var.project_name}-sync"
  role          = aws_iam_role.sync.arn
  package_type  = "Image"
  image_uri     = local.sync_image_uri
  architectures = ["arm64"]
  timeout       = 30
  memory_size   = 256

  environment {
    variables = {
      GCP_PROJECT = var.gcp_project
      COLLECTION  = "never-down-orders"
    }
  }

  depends_on = [aws_ecr_repository_policy.sync]
}

resource "aws_cloudwatch_log_group" "sync" {
  name              = "/aws/lambda/${aws_lambda_function.sync.function_name}"
  retention_in_days = 7
}

# --- Trigger: DynamoDB Streams → Lambda de sync ---
resource "aws_lambda_event_source_mapping" "sync" {
  event_source_arn  = aws_dynamodb_table.orders.stream_arn
  function_name     = aws_lambda_function.sync.arn
  starting_position = "LATEST"
  batch_size        = 10

  maximum_retry_attempts = 3
}

###############################################################################
# Reconciliación de failback: Firestore → DynamoDB (misma imagen, otro handler)
# Se invoca manualmente (scripts/failback.sh) ANTES de devolver el tráfico a AWS,
# para no perder pedidos que entraron mientras el tráfico estaba en GCP.
###############################################################################

resource "aws_iam_role_policy" "reconcile" {
  name = "${var.project_name}-reconcile-policy"
  role = aws_iam_role.sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:DeleteItem"]
      Resource = aws_dynamodb_table.orders.arn
    }]
  })
}

resource "aws_lambda_function" "reconcile" {
  function_name = "${var.project_name}-reconcile"
  role          = aws_iam_role.sync.arn
  package_type  = "Image"
  image_uri     = local.sync_image_uri
  image_config {
    command = ["reconcile_handler.handler"]
  }
  architectures = ["arm64"]
  timeout       = 30
  memory_size   = 256

  environment {
    variables = {
      GCP_PROJECT = var.gcp_project
      COLLECTION  = "never-down-orders"
      TABLE_NAME  = aws_dynamodb_table.orders.name
    }
  }

  depends_on = [aws_ecr_repository_policy.sync]
}

resource "aws_cloudwatch_log_group" "reconcile" {
  name              = "/aws/lambda/${aws_lambda_function.reconcile.function_name}"
  retention_in_days = 7
}
