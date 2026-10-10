###############################################################################
# GCP — Load Balancer HTTPS externo → Cloud Run (warm standby)
# TLS válido por adelantado vía Certificate Manager + DNS authorization,
# para que el failover por DNS a GCP funcione sin errores de certificado.
###############################################################################

# IP estática global → registro A weighted junto a CloudFront
resource "google_compute_global_address" "lb" {
  name = "${var.project_name}-ip"
}

# Serverless NEG apuntando al servicio Cloud Run existente
resource "google_compute_region_network_endpoint_group" "neg" {
  name                  = "${var.project_name}-neg"
  region                = var.gcp_region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = var.cloud_run_service
  }
}

resource "google_compute_backend_service" "lb" {
  name                  = "${var.project_name}-bs"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  backend {
    group = google_compute_region_network_endpoint_group.neg.id
  }
}

resource "google_compute_url_map" "lb" {
  name            = "${var.project_name}-um"
  default_service = google_compute_backend_service.lb.id
}

# --- Certificate Manager: cert gestionado con DNS authorization ---
resource "google_certificate_manager_dns_authorization" "front" {
  name   = "${var.project_name}-dnsauth-front"
  domain = var.front_domain
}

resource "google_certificate_manager_dns_authorization" "api" {
  name   = "${var.project_name}-dnsauth-api"
  domain = var.api_domain
}

resource "google_certificate_manager_certificate" "lb" {
  name = "${var.project_name}-cert"
  managed {
    domains = [var.front_domain, var.api_domain]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.front.id,
      google_certificate_manager_dns_authorization.api.id,
    ]
  }
}

resource "google_certificate_manager_certificate_map" "lb" {
  name = "${var.project_name}-certmap"
}

resource "google_certificate_manager_certificate_map_entry" "front" {
  name         = "${var.project_name}-cme-front"
  map          = google_certificate_manager_certificate_map.lb.name
  certificates = [google_certificate_manager_certificate.lb.id]
  hostname     = var.front_domain
}

resource "google_certificate_manager_certificate_map_entry" "api" {
  name         = "${var.project_name}-cme-api"
  map          = google_certificate_manager_certificate_map.lb.name
  certificates = [google_certificate_manager_certificate.lb.id]
  hostname     = var.api_domain
}

resource "google_compute_target_https_proxy" "lb" {
  name            = "${var.project_name}-proxy"
  url_map         = google_compute_url_map.lb.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.lb.id}"
}

resource "google_compute_global_forwarding_rule" "lb" {
  name                  = "${var.project_name}-fr"
  target                = google_compute_target_https_proxy.lb.id
  port_range            = "443"
  ip_address            = google_compute_global_address.lb.address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
