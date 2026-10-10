###############################################################################
# Frontend en AWS: S3 (privado) + CloudFront (OAC) para cafequetzal
###############################################################################

resource "aws_s3_bucket" "front" {
  bucket = "${var.project_name}-cafequetzal-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "front" {
  bucket                  = aws_s3_bucket.front.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Sube el storefront al bucket
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.front.id
  key          = "index.html"
  source       = "${path.module}/../web/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/../web/index.html")
}

# Origin Access Control (forma moderna de que CloudFront lea S3 privado)
resource "aws_cloudfront_origin_access_control" "front" {
  name                              = "${var.project_name}-front-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "front" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = [var.front_domain]
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.front.bucket_regional_domain_name
    origin_id                = "s3-front"
    origin_access_control_id = aws_cloudfront_origin_access_control.front.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-front"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 60
    max_ttl     = 300
  }

  # SPA: cualquier 403/404 devuelve index.html
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.front.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Política del bucket: solo esta distribución de CloudFront puede leer
resource "aws_s3_bucket_policy" "front" {
  bucket = aws_s3_bucket.front.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.front.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.front.arn
        }
      }
    }]
  })
}
