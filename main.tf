locals {
  enabled = module.this.enabled

  # Encapsulate logic here so that it is not lost/scattered among the configuration
  website_enabled                          = local.enabled && var.website_enabled
  website_password_enabled                 = local.website_enabled && var.s3_website_password_enabled
  s3_origin_enabled                        = local.enabled && ! var.website_enabled
  create_s3_bucket                         = local.enabled && var.origin_bucket == null
  create_cloudfront_origin_access_identity = local.enabled && length(compact([var.cloudfront_origin_access_identity_iam_arn])) == 0 # "" or null

  origin_path = coalesce(var.origin_path, "/")
  # Collect the information for whichever S3 bucket we are using as the origin
  origin_bucket_placeholder = {
    arn                         = null
    bucket                      = null
    website_domain              = null
    website_endpoint            = null
    bucket_regional_domain_name = null
  }
  origin_bucket_options = {
    new      = local.create_s3_bucket ? aws_s3_bucket.origin[0] : null
    existing = local.enabled && var.origin_bucket != null ? data.aws_s3_bucket.origin[0] : null
    disabled = local.origin_bucket_placeholder
  }
  # Workaround for requirement that tertiary expression has to have exactly matching objects in both result values
  origin_bucket = local.origin_bucket_options[local.enabled ? (local.create_s3_bucket ? "new" : "existing") : "disabled"]

  # Collect the information for cloudfront_origin_access_identity_iam and shorten the variable names
  cf_access_options = {
    new = local.create_cloudfront_origin_access_identity ? {
      arn  = aws_cloudfront_origin_access_identity.default[0].iam_arn
      path = aws_cloudfront_origin_access_identity.default[0].cloudfront_access_identity_path
    } : null
    existing = {
      arn  = var.cloudfront_origin_access_identity_iam_arn
      path = var.cloudfront_origin_access_identity_path
    }
  }
  cf_access = local.cf_access_options[local.create_cloudfront_origin_access_identity ? "new" : "existing"]

  # Pick the IAM policy document based on whether the origin is an S3 origin or a Website origin
  iam_policy_document = local.enabled ? (
    local.website_enabled ? data.aws_iam_policy_document.s3_website_origin[0].json : data.aws_iam_policy_document.s3_origin[0].json
  ) : ""

  bucket             = local.origin_bucket.bucket
  bucket_domain_name = var.website_enabled ? local.origin_bucket.website_domain : local.origin_bucket.bucket_regional_domain_name

  override_origin_bucket_policy = local.enabled && var.override_origin_bucket_policy

  website_config = {
    redirect_all = [
      {
        redirect_all_requests_to = var.redirect_all_requests_to
      }
    ]
    default = [
      {
        index_document = var.index_document
        error_document = var.error_document
        routing_rules  = var.routing_rules
      }
    ]
  }
}

## Make up for deprecated template_file and lack of templatestring
# https://github.com/hashicorp/terraform-provider-template/issues/85
# https://github.com/hashicorp/terraform/issues/26838
locals {
  override_policy = replace(replace(replace(var.additional_bucket_policy,
    "$${origin_path}", local.origin_path),
    "$${bucket_name}", local.bucket),
  "$${cloudfront_origin_access_identity_iam_arn}", local.cf_access.arn)
}

module "origin_label" {
  source  = "cloudposse/label/null"
  version = "0.24.1"

  attributes = var.extra_origin_attributes

  context = module.this.context
}

resource "aws_cloudfront_origin_access_identity" "default" {
  count = local.create_cloudfront_origin_access_identity ? 1 : 0

  comment = module.this.id
}

resource "random_password" "referer" {
  count = local.website_password_enabled ? 1 : 0

  length  = 32
  special = false
}

data "aws_iam_policy_document" "s3_origin" {
  count = local.s3_origin_enabled ? 1 : 0

  override_json = local.override_policy

  statement {
    sid = "S3GetObjectForCloudFront"

    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.bucket}${local.origin_path}*"]

    principals {
      type        = "AWS"
      identifiers = [local.cf_access.arn]
    }
  }

  statement {
    sid = "S3ListBucketForCloudFront"

    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.bucket}"]

    principals {
      type        = "AWS"
      identifiers = [local.cf_access.arn]
    }
  }
}

data "aws_iam_policy_document" "s3_website_origin" {
  count = local.website_enabled ? 1 : 0

  override_json = local.override_policy

  statement {
    sid = "S3GetObjectForCloudFront"

    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.bucket}${local.origin_path}*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    dynamic "condition" {
      for_each = local.website_password_enabled ? ["password"] : []

      content {
        test     = "StringEquals"
        variable = "aws:referer"
        values   = [random_password.referer[0].result]
      }
    }
  }
}

data "aws_iam_policy_document" "deployment" {
  for_each = local.enabled ? var.deployment_principal_arns : {}

  statement {
    actions = var.deployment_actions

    resources = flatten(distinct([
      local.origin_bucket.arn,
      formatlist("${local.origin_bucket.arn}%s*", each.value),
    ]))

    principals {
      type        = "AWS"
      identifiers = [each.key]
    }
  }
}

data "aws_iam_policy_document" "combined" {
  count = local.enabled ? 1 : 0

  source_policy_documents = compact(concat(
    data.aws_iam_policy_document.s3_origin.*.json,
    data.aws_iam_policy_document.s3_website_origin.*.json,
    values(data.aws_iam_policy_document.deployment)[*].json
  ))
}


resource "aws_s3_bucket_policy" "default" {
  count = local.create_s3_bucket || local.override_origin_bucket_policy ? 1 : 0

  bucket = local.origin_bucket.bucket
  policy = join("", data.aws_iam_policy_document.combined.*.json)
}

resource "aws_s3_bucket" "origin" {
  #bridgecrew:skip=BC_AWS_S3_13:Skipping `Enable S3 Bucket Logging` check until bridgecrew will support dynamic blocks (https://github.com/bridgecrewio/checkov/issues/776).
  #bridgecrew:skip=BC_AWS_S3_14:Skipping `Ensure all data stored in the S3 bucket is securely encrypted at rest` check until bridgecrew will support dynamic blocks (https://github.com/bridgecrewio/checkov/issues/776).
  #bridgecrew:skip=CKV_AWS_52:Skipping `Ensure S3 bucket has MFA delete enabled` due to issue in terraform (https://github.com/hashicorp/terraform-provider-aws/issues/629).
  count = local.create_s3_bucket ? 1 : 0

  bucket        = module.origin_label.id
  acl           = "private"
  tags          = module.origin_label.tags
  force_destroy = var.origin_force_destroy

  dynamic "server_side_encryption_configuration" {
    for_each = var.encryption_enabled ? ["true"] : []

    content {
      rule {
        apply_server_side_encryption_by_default {
          sse_algorithm = "AES256"
        }
      }
    }
  }

  versioning {
    enabled = var.versioning_enabled
  }

  dynamic "logging" {
    for_each = var.access_log_bucket_name != "" ? [1] : []
    content {
      target_bucket = var.access_log_bucket_name
      target_prefix = var.access_log_bucket_prefix
    }
  }

  dynamic "website" {
    for_each = var.website_enabled ? local.website_config[var.redirect_all_requests_to == "" ? "default" : "redirect_all"] : []
    content {
      error_document           = lookup(website.value, "error_document", null)
      index_document           = lookup(website.value, "index_document", null)
      redirect_all_requests_to = lookup(website.value, "redirect_all_requests_to", null)
      routing_rules            = lookup(website.value, "routing_rules", null)
    }
  }

  dynamic "cors_rule" {
    for_each = distinct(compact(concat(var.cors_allowed_origins, var.aliases)))
    content {
      allowed_headers = var.cors_allowed_headers
      allowed_methods = var.cors_allowed_methods
      allowed_origins = [cors_rule.value]
      expose_headers  = var.cors_expose_headers
      max_age_seconds = var.cors_max_age_seconds
    }
  }
}

resource "aws_s3_bucket_public_access_block" "origin" {
  count                   = (local.create_s3_bucket || local.override_origin_bucket_policy) && var.block_origin_public_access_enabled ? 1 : 0
  bucket                  = local.bucket
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # Don't modify this bucket in two ways at the same time, S3 API will complain.
  depends_on = [aws_s3_bucket_policy.default]
}

#module "logs" {
#  source                   = "cloudposse/s3-log-storage/aws"
#  version                  = "0.20.0"
#  enabled                  = (local.enabled && var.logging_enabled)
#  attributes               = var.extra_logs_attributes
#  lifecycle_prefix         = var.log_prefix
#  standard_transition_days = var.log_standard_transition_days
#  glacier_transition_days  = var.log_glacier_transition_days
#  expiration_days          = var.log_expiration_days
#  force_destroy            = var.origin_force_destroy
#  versioning_enabled       = var.log_versioning_enabled
#
#  context = module.this.context
#}

data "aws_s3_bucket" "origin" {
  count  = local.enabled && (var.origin_bucket != null) ? 1 : 0
  bucket = var.origin_bucket
}

resource "aws_cloudfront_distribution" "default" {
  count = local.enabled ? 1 : 0

  #bridgecrew:skip=BC_AWS_LOGGING_20:Skipping `CloudFront Access Logging` check until bridgecrew will support dynamic blocks (https://github.com/bridgecrewio/checkov/issues/776).
  enabled             = var.distribution_enabled
  is_ipv6_enabled     = var.ipv6_enabled
  comment             = var.comment
  default_root_object = var.default_root_object
  price_class         = var.price_class
  depends_on          = [aws_s3_bucket.origin]

  dynamic "logging_config" {
    for_each = var.logging_enabled ? ["true"] : []

    content {
      include_cookies = var.log_include_cookies
      bucket          = var.cf_log_bucket
      prefix          = var.cf_log_prefix
    }
  }

  aliases = var.acm_certificate_arn != "" ? var.aliases : []

  origin {
    domain_name = local.bucket_domain_name
    origin_id   = module.this.id
    origin_path = var.origin_path

    dynamic "s3_origin_config" {
      for_each = ! var.website_enabled ? [1] : []
      content {
        origin_access_identity = local.cf_access.path
      }
    }

    dynamic "custom_origin_config" {
      for_each = var.website_enabled ? [1] : []
      content {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = var.origin_ssl_protocols
      }
    }
    dynamic "custom_header" {
      for_each = local.website_password_enabled ? concat([{ name = "referer", value = random_password.referer[0].result }], var.custom_origin_headers) : var.custom_origin_headers

      content {
        name  = custom_header.value["name"]
        value = custom_header.value["value"]
      }
    }
  }

  dynamic "origin" {
    for_each = var.s3_origins
    content {
      domain_name = origin.value.domain_name
      origin_id   = origin.value.origin_id
      origin_path = lookup(origin.value, "origin_path", "")
      s3_origin_config {
        origin_access_identity = lookup(origin.value.s3_origin_config, "origin_access_identity", "")
      }
    }
  }

  dynamic "origin" {
    for_each = var.custom_origins
    content {
      domain_name = origin.value.domain_name
      origin_id   = origin.value.origin_id
      origin_path = lookup(origin.value, "origin_path", "")
      dynamic "custom_header" {
        for_each = lookup(origin.value, "custom_headers", [])
        content {
          name  = custom_header.value["name"]
          value = custom_header.value["value"]
        }
      }
      custom_origin_config {
        http_port                = lookup(origin.value.custom_origin_config, "http_port", 80)
        https_port               = lookup(origin.value.custom_origin_config, "https_port", 443)
        origin_protocol_policy   = lookup(origin.value.custom_origin_config, "origin_protocol_policy", "https-only")
        origin_ssl_protocols     = lookup(origin.value.custom_origin_config, "origin_ssl_protocols", ["TLSv1.2"])
        origin_keepalive_timeout = lookup(origin.value.custom_origin_config, "origin_keepalive_timeout", 60)
        origin_read_timeout      = lookup(origin.value.custom_origin_config, "origin_read_timeout", 60)
      }
    }
  }

  dynamic "origin" {
    for_each = var.s3_origins
    content {
      domain_name = origin.value.domain_name
      origin_id   = origin.value.origin_id
      origin_path = lookup(origin.value, "origin_path", "")
      s3_origin_config {
        origin_access_identity = lookup(origin.value.s3_origin_config, "origin_access_identity", "")
      }
    }
  }

  viewer_certificate {
    acm_certificate_arn            = var.acm_certificate_arn
    ssl_support_method             = var.acm_certificate_arn == "" ? "" : "sni-only"
    minimum_protocol_version       = var.minimum_protocol_version
    cloudfront_default_certificate = var.acm_certificate_arn == "" ? true : false
  }

  default_cache_behavior {
    allowed_methods  = var.allowed_methods
    cached_methods   = var.cached_methods
    cache_policy_id  = var.cache_policy_id
    target_origin_id = module.this.id
    compress         = var.compress
    trusted_signers  = var.trusted_signers

    dynamic "forwarded_values" {
      # If a cache policy is specified, we cannot include a `forwarded_values` block at all in the API request
      for_each = var.cache_policy_id == null ? [true] : []
      content {
        query_string            = var.forward_query_string
        query_string_cache_keys = var.query_string_cache_keys
        headers                 = var.forward_header_values

        cookies {
          forward = var.forward_cookies
        }
      }
    }

    viewer_protocol_policy = var.viewer_protocol_policy
    default_ttl            = var.default_ttl
    min_ttl                = var.min_ttl
    max_ttl                = var.max_ttl

    dynamic "lambda_function_association" {
      for_each = var.lambda_function_association
      content {
        event_type   = lambda_function_association.value.event_type
        include_body = lookup(lambda_function_association.value, "include_body", null)
        lambda_arn   = lambda_function_association.value.lambda_arn
      }
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.ordered_cache

    content {
      path_pattern = ordered_cache_behavior.value.path_pattern

      allowed_methods  = ordered_cache_behavior.value.allowed_methods
      cached_methods   = ordered_cache_behavior.value.cached_methods
      target_origin_id = ordered_cache_behavior.value.target_origin_id == "" ? module.this.id : ordered_cache_behavior.value.target_origin_id
      compress         = ordered_cache_behavior.value.compress
      trusted_signers  = var.trusted_signers
      trusted_key_groups = ordered_cache_behavior.value.trusted_key_groups

      forwarded_values {
        query_string = ordered_cache_behavior.value.forward_query_string
        headers      = ordered_cache_behavior.value.forward_header_values

        cookies {
          forward = ordered_cache_behavior.value.forward_cookies
        }
      }

      viewer_protocol_policy = ordered_cache_behavior.value.viewer_protocol_policy
      default_ttl            = ordered_cache_behavior.value.default_ttl
      min_ttl                = ordered_cache_behavior.value.min_ttl
      max_ttl                = ordered_cache_behavior.value.max_ttl

      dynamic "lambda_function_association" {
        for_each = ordered_cache_behavior.value.lambda_function_association
        content {
          event_type   = lambda_function_association.value.event_type
          include_body = lookup(lambda_function_association.value, "include_body", null)
          lambda_arn   = lambda_function_association.value.lambda_arn
        }
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  dynamic "custom_error_response" {
    for_each = var.custom_error_response
    content {
      error_caching_min_ttl = lookup(custom_error_response.value, "error_caching_min_ttl", null)
      error_code            = custom_error_response.value.error_code
      response_code         = lookup(custom_error_response.value, "response_code", null)
      response_page_path    = lookup(custom_error_response.value, "response_page_path", null)
    }
  }

  web_acl_id          = var.web_acl_id
  wait_for_deployment = var.wait_for_deployment

  tags = module.this.tags
}

module "dns" {
  source           = "cloudposse/route53-alias/aws"
  version          = "0.12.0"
  enabled          = (local.enabled && var.dns_alias_enabled) ? true : false
  aliases          = var.aliases
  parent_zone_id   = var.parent_zone_id
  parent_zone_name = var.parent_zone_name
  target_dns_name  = try(aws_cloudfront_distribution.default[0].domain_name, "")
  target_zone_id   = try(aws_cloudfront_distribution.default[0].hosted_zone_id, "")
  ipv6_enabled     = var.ipv6_enabled

  context = module.this.context
}
