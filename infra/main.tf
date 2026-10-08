# 之後所有資源都寫在 infra/ 底下，由 GitHub Actions 部署。
# bootstrap/ 只在本機或 CloudShell 手動套用，CI 不碰它。
#
#   baseline.tf         帳號層級的安全基線（S3 封鎖公開存取、EBS 預設加密）
#   identity-center.tf  IAM Identity Center 的日常登入
#
# 多個專案共用的一台主機（docs/host-platform.md）：
#   network.tf   預設 VPC、安全群組（80/443，不開 22）
#   host.tf      EC2（rootful podman）、/srv 資料碟、Elastic IP、IAM 角色、每日快照
#   storage.tf   部署包與備份兩個 bucket、主機平台的檔案（host/platform/）
#   ssm.tf       PlatformSync（套用平台檔案）與 TenantDeploy（部署一個專案）兩份 SSM 文件
#   registry.tf  每個專案的 ECR 倉庫與 GitHub Actions 推映像的角色
#   dns.tf       Route 53 管的網域指到主機
#   budget.tf    每月費用警報

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  registry = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # GitHub 的 OIDC 身分提供者由 bootstrap 建立
  oidc_host         = "token.actions.githubusercontent.com"
  oidc_provider_arn = "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${local.oidc_host}"
}
