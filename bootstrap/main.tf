data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  repo_full  = "${var.github_owner}/${var.github_repo}"
  oidc_host  = "token.actions.githubusercontent.com"

  state_bucket = coalesce(var.state_bucket_name, "tofu-state-${local.account_id}-${var.region}")

  oidc_provider_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${local.oidc_host}"
  )

  # GitHub OIDC 的 sub 有兩種格式，兩種都接受：
  #   舊格式：repo:OWNER/REPO:...（2026-07-15 前建立且沒改名、移轉的 repo）
  #   新格式：repo:OWNER@OWNER_ID/REPO@REPO_ID:...（之後建立、改名或移轉的 repo）
  # 舊格式本身可被同名 repo 冒用，所以另外用 repository_id 條件鎖住。
  sub_prefixes = [
    "repo:${local.repo_full}",
    "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repository_id}",
  ]
}

# GitHub Actions 的 OIDC 身分提供者。
# GitHub 的憑證由 AWS 信任的根 CA 簽發，所以不需要 thumbprint。
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}
