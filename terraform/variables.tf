variable "aws_region" {
  description = "Región AWS (cloud primario)"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Perfil de credenciales AWS"
  type        = string
  default     = "hvillavicencio"
}

variable "project_name" {
  description = "Prefijo de nombres de recursos"
  type        = string
  default     = "never-down"
}

variable "domain_name" {
  description = "Dominio público del demo (Café Quetzal)"
  type        = string
  default     = "never-down.hvillavicencio.com"
}

variable "hosted_zone_id" {
  description = "Hosted zone de Route 53 para tu dominio. Sin default a propósito: provéelo vía terraform.tfvars (ver terraform.tfvars.example). Obtenlo con: aws route53 list-hosted-zones-by-name --dns-name <tu-dominio>"
  type        = string
}

variable "front_domain" {
  description = "Subdominio del frontend"
  type        = string
  default     = "cafequetzal.hvillavicencio.com"
}

variable "api_domain" {
  description = "Subdominio de la API"
  type        = string
  default     = "apicafequetzal.hvillavicencio.com"
}

variable "cloud_run_url" {
  description = "URL del servicio Cloud Run (standby GCP)"
  type        = string
  default     = "cafe-quetzal-<GCP_PROJECT_NUMBER>.us-central1.run.app"
}

variable "gcp_project" {
  description = "Proyecto GCP (warm standby). Sin default a propósito: provéelo vía terraform.tfvars (ver terraform.tfvars.example). Obtenlo con: gcloud config get-value project"
  type        = string
}

variable "gcp_region" {
  description = "Región GCP"
  type        = string
  default     = "us-central1"
}

variable "cloud_run_service" {
  description = "Nombre del servicio Cloud Run"
  type        = string
  default     = "cafe-quetzal"
}

# Pesos del failover. Normal: AWS=100, GCP=0. Failover: AWS=0, GCP=100.
# El AI Monitor (Fase 5) los cambia vía API en vivo; aquí sirven para pruebas.
variable "aws_weight" {
  description = "Peso del routing hacia AWS"
  type        = number
  default     = 100
}

variable "gcp_weight" {
  description = "Peso del routing hacia GCP"
  type        = number
  default     = 0
}

variable "alert_email" {
  description = "Email para alertas SNS de failover (opcional; vacío = sin suscripción)"
  type        = string
  default     = ""
}

# Amazon Nova (modelo nativo de AWS, sin Marketplace/tarjeta). Para volver a
# Claude (requiere método de pago en la cuenta): us.anthropic.claude-haiku-4-5-20251001-v1:0
variable "bedrock_model_id" {
  description = "Modelo de Bedrock para el AI Monitor"
  type        = string
  default     = "amazon.nova-lite-v1:0"
}
