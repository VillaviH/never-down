###############################################################################
# AI Health Monitor — Lambda + Bedrock + EventBridge (cada 60s)
# Decide OK/DEGRADED/FAILOVER y, si aplica, cambia los pesos de Route 53.
###############################################################################

# --- Tabla de auditoría de decisiones (y estado) ---
resource "aws_dynamodb_table" "monitor" {
  name         = "${var.project_name}-monitor"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "ts"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "ts"
    type = "N"
  }

  ttl {
    attribute_name = "expires"
    enabled        = true
  }
}

# --- SNS para alertas de failover ---
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Empaquetado del monitor ---
data "archive_file" "monitor" {
  type        = "zip"
  source_file = "${path.module}/../app/monitor/health_monitor.py"
  output_path = "${path.module}/build/monitor.zip"
}

# --- IAM del monitor ---
resource "aws_iam_role" "monitor" {
  name = "${var.project_name}-monitor-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "monitor" {
  name = "${var.project_name}-monitor-policy"
  role = aws_iam_role.monitor.id
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
        Action = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/amazon.nova-*",
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-*",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/${var.hosted_zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.monitor.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

# --- Lambda del monitor ---
resource "aws_lambda_function" "monitor" {
  function_name    = "${var.project_name}-monitor"
  role             = aws_iam_role.monitor.arn
  handler          = "health_monitor.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.monitor.output_path
  source_code_hash = data.archive_file.monitor.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      BEDROCK_MODEL_ID    = var.bedrock_model_id
      HOSTED_ZONE_ID      = var.hosted_zone_id
      FRONT_DOMAIN        = var.front_domain
      API_DOMAIN          = var.api_domain
      AWS_HEALTH_URL      = "${aws_apigatewayv2_api.app.api_endpoint}/health"
      GCP_HEALTH_URL      = "https://${var.cloud_run_url}/health"
      MONITOR_TABLE       = aws_dynamodb_table.monitor.name
      SNS_TOPIC_ARN       = aws_sns_topic.alerts.arn
      APP_FUNCTION_NAME   = aws_lambda_function.app.function_name
      AUTO_FAILOVER       = "true"
      CONFIDENCE_MIN      = "0.8"
      SUSTAINED_CYCLES    = "2"
    }
  }
}

resource "aws_cloudwatch_log_group" "monitor" {
  name              = "/aws/lambda/${aws_lambda_function.monitor.function_name}"
  retention_in_days = 7
}

# --- Schedule: cada 1 minuto ---
resource "aws_cloudwatch_event_rule" "tick" {
  name                = "${var.project_name}-monitor-tick"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "tick" {
  rule = aws_cloudwatch_event_rule.tick.name
  arn  = aws_lambda_function.monitor.arn
}

resource "aws_lambda_permission" "tick" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.tick.arn
}
