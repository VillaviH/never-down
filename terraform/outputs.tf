output "aws_api_endpoint" {
  description = "Endpoint directo del API Gateway (AWS primario)"
  value       = aws_apigatewayv2_api.app.api_endpoint
}

output "dynamodb_table" {
  description = "Tabla DynamoDB de pedidos"
  value       = aws_dynamodb_table.orders.name
}

output "front_url" {
  description = "Frontend público (Café Quetzal)"
  value       = "https://${var.front_domain}"
}

output "api_url" {
  description = "API pública (Café Quetzal)"
  value       = "https://${var.api_domain}"
}

output "cloudfront_domain" {
  description = "Dominio de CloudFront (front)"
  value       = aws_cloudfront_distribution.front.domain_name
}
