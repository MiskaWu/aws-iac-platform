output "apply_role_arn" {
  description = "設成 GitHub repo variable AWS_APPLY_ROLE_ARN"
  value       = aws_iam_role.apply.arn
}

output "plan_role_arn" {
  description = "設成 GitHub repo variable AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.plan.arn
}

output "state_bucket" {
  description = "bootstrap/backend.tf 與 infra/backend.tf 的 bucket"
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}

output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}
