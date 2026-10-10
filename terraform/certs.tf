###############################################################################
# Certificados ACM (us-east-1) para el front (CloudFront) y la API (API Gateway)
# Validación por DNS en la zona Route 53 de hvillavicencio.com
###############################################################################

data "aws_caller_identity" "current" {}

# --- Cert del frontend (CloudFront requiere us-east-1) ---
resource "aws_acm_certificate" "front" {
  domain_name       = var.front_domain
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "front_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.front.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "front" {
  certificate_arn         = aws_acm_certificate.front.arn
  validation_record_fqdns = [for r in aws_route53_record.front_cert_validation : r.fqdn]
}

# --- Cert de la API (API Gateway regional, misma región us-east-1) ---
resource "aws_acm_certificate" "api" {
  domain_name       = var.api_domain
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "api_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.api.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.api_cert_validation : r.fqdn]
}
