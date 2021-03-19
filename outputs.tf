output "cf_id" {
  value       = aws_cloudfront_distribution.default.id
  description = "ID of AWS CloudFront distribution"
}

output "cf_arn" {
  value       = aws_cloudfront_distribution.default.arn
  description = "ARN of AWS CloudFront distribution"
}

output "cf_status" {
  value       = aws_cloudfront_distribution.default.status
  description = "Current status of the distribution"
}

output "cf_domain_name" {
  value       = aws_cloudfront_distribution.default.domain_name
  description = "Domain name corresponding to the distribution"
}

output "cf_etag" {
  value       = aws_cloudfront_distribution.default.etag
  description = "Current version of the distribution's information"
}

output "cf_hosted_zone_id" {
  value       = aws_cloudfront_distribution.default.hosted_zone_id
  description = "CloudFront Route 53 zone ID"
}

output "cf_identity_iam_arn" {
  value       = try(aws_cloudfront_origin_access_identity.default[0].iam_arn, "")
  description = "CloudFront Origin Access Identity IAM ARN"
}

output "cf_s3_canonical_user_id" {
  value       = try(aws_cloudfront_origin_access_identity.default[0].s3_canonical_user_id, "")
  description = "Canonical user ID for CloudFront Origin Access Identity"
}

output "s3_bucket" {
  value       = local.bucket
  description = "Name of origin S3 bucket"
}

output "s3_bucket_domain_name" {
  value       = local.bucket_domain_name
  description = "Domain of origin S3 bucket"
}

output "s3_bucket_arn" {
  value       = join("", aws_s3_bucket.origin.*.arn)
  description = "ARN of origin S3 bucket"
}

#output "logs" {
#  value       = module.logs
#  description = "Log bucket resource"
#}

output "aliases" {
  value       = var.aliases
  description = "Aliases of the CloudFront distibution"
}
