# 兩個 bucket：
#   部署包  platform-deploy-…   _platform/ 是主機平台的檔案（下面上傳），<專案>/bundle.tar.gz 是各專案的部署包
#   備份    platform-backups-…  <專案>/<UTC 時間>.dump，主機只能寫（host.tf）

module "deploy_bucket" {
  source = "./modules/private-bucket"

  name                   = "platform-deploy-${local.account_id}-${local.region}"
  expire_noncurrent_days = 30 # 舊的部署包留 30 天，可以退回上一包
}

module "backup_bucket" {
  source = "./modules/private-bucket"

  name                   = "platform-backups-${local.account_id}-${local.region}"
  expire_current_days    = 35
  expire_noncurrent_days = 7
}

# ---------- 主機平台的檔案 ----------
# host/platform/ 底下的檔案原封不動放到 s3://<部署 bucket>/_platform/，PlatformSync 同步到主機的 /usr/local/lib/platform/
# 再執行 install.sh。platform.env 是這裡產生的設定（bucket 名稱、ECR 位址等）。

locals {
  platform_files = fileset("${path.module}/host/platform", "**")

  platform_env = <<-EOT
    # OpenTofu 產生（infra/storage.tf），不要在主機上改
    REGION=${local.region}
    REGISTRY=${local.registry}
    DEPLOY_BUCKET=${module.deploy_bucket.name}
    BACKUP_BUCKET=${module.backup_bucket.name}
    ACME_EMAIL=${var.acme_email}
  EOT

  # 平台檔案任何一個改了，這個值就變，PlatformSync 的 association 跟著重跑
  platform_revision = sha256(join("\n", concat(
    [for f in sort(tolist(local.platform_files)) : "${f} ${filesha256("${path.module}/host/platform/${f}")}"],
    [sha256(local.platform_env)],
  )))
}

resource "aws_s3_object" "platform" {
  for_each = local.platform_files

  bucket = module.deploy_bucket.name
  key    = "_platform/${each.value}"
  source = "${path.module}/host/platform/${each.value}"
  etag   = filemd5("${path.module}/host/platform/${each.value}")
}

resource "aws_s3_object" "platform_env" {
  bucket  = module.deploy_bucket.name
  key     = "_platform/platform.env"
  content = local.platform_env
}
