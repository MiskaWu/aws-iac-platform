# 帳號層級的安全基線，對應 AWS Security Hub 的 S3.1 與 EC2.7。兩項都不收費。

# 整個帳號的 S3 都不允許公開存取。
# 之後要對外提供靜態檔案，用 CloudFront 加 Origin Access Control，不必把 bucket 開成公開。
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 台北區之後新建的 EBS 硬碟一律加密，用 AWS 管理的金鑰，不另外收費。
# 這個設定是每個區域各自一份，只對 provider 所在的 ap-east-2 生效。
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}
