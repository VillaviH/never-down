###############################################################################
# Route 53 — registros weighted. AWS = 100 (primario). GCP = 0 (se añade luego).
# El AI Monitor voltea los pesos en el failover.
###############################################################################

# --- Frontend: cafequetzal → CloudFront (AWS, peso 100) ---
resource "aws_route53_record" "front_aws" {
  zone_id        = var.hosted_zone_id
  name           = var.front_domain
  type           = "A"
  set_identifier = "aws"

  weighted_routing_policy {
    weight = var.aws_weight
  }

  alias {
    name                   = aws_cloudfront_distribution.front.domain_name
    zone_id                = aws_cloudfront_distribution.front.hosted_zone_id
    evaluate_target_health = false
  }
}

# --- API: apicafequetzal → API Gateway (AWS, peso 100) ---
resource "aws_route53_record" "api_aws" {
  zone_id        = var.hosted_zone_id
  name           = var.api_domain
  type           = "A"
  set_identifier = "aws"

  weighted_routing_policy {
    weight = var.aws_weight
  }

  alias {
    name                   = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

###############################################################################
# GCP — validación del cert (DNS auth) + registros weighted a la IP del LB (peso 0)
###############################################################################

# CNAMEs de DNS authorization (emiten el cert de GCP por adelantado, sin tráfico)
resource "aws_route53_record" "gcp_dnsauth_front" {
  zone_id = var.hosted_zone_id
  name    = google_certificate_manager_dns_authorization.front.dns_resource_record[0].name
  type    = google_certificate_manager_dns_authorization.front.dns_resource_record[0].type
  records = [google_certificate_manager_dns_authorization.front.dns_resource_record[0].data]
  ttl     = 300
}

resource "aws_route53_record" "gcp_dnsauth_api" {
  zone_id = var.hosted_zone_id
  name    = google_certificate_manager_dns_authorization.api.dns_resource_record[0].name
  type    = google_certificate_manager_dns_authorization.api.dns_resource_record[0].type
  records = [google_certificate_manager_dns_authorization.api.dns_resource_record[0].data]
  ttl     = 300
}

# Frontend: cafequetzal → IP del LB de GCP (peso 0, standby)
resource "aws_route53_record" "front_gcp" {
  zone_id        = var.hosted_zone_id
  name           = var.front_domain
  type           = "A"
  set_identifier = "gcp"
  ttl            = 60

  weighted_routing_policy {
    weight = var.gcp_weight
  }

  records = [google_compute_global_address.lb.address]
}

# API: apicafequetzal → IP del LB de GCP (peso 0, standby)
resource "aws_route53_record" "api_gcp" {
  zone_id        = var.hosted_zone_id
  name           = var.api_domain
  type           = "A"
  set_identifier = "gcp"
  ttl            = 60

  weighted_routing_policy {
    weight = var.gcp_weight
  }

  records = [google_compute_global_address.lb.address]
}
