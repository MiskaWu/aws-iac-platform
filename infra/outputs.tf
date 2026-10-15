output "host_instance_id" {
  description = "登入：aws ssm start-session --target <這個值>"
  value       = aws_instance.host.id
}

output "host_public_ip" {
  description = "Elastic IP；網域在別家時，A 記錄指到這裡"
  value       = aws_eip.host.public_ip
}

output "registry" {
  value = local.registry
}

output "ecr_repositories" {
  value = { for name, repo in aws_ecr_repository.project : name => repo.repository_url }
}

output "ecr_push_role_arns" {
  description = "各專案的 GitHub Actions 用 aws-actions/configure-aws-credentials 扮演這個角色推映像"
  value       = { for name, role in aws_iam_role.ecr_push : name => role.arn }
}

output "edge_caddy_push_role_arn" {
  description = ".github/workflows/edge-caddy.yml 扮演它推映像（ARN 寫在 workflow 的 env）"
  value       = aws_iam_role.edge_caddy_push.arn
}

output "deploy_bucket" {
  value = module.deploy_bucket.name
}

output "backup_bucket" {
  value = module.backup_bucket.name
}
