# IAM Identity Center：本機與主控台的日常登入，取代 root。
#
# 前提（只能在主控台做，見 README「IAM Identity Center」）：
#   1. 用 root 在 ap-east-2 啟用 Identity Center 的 organization instance，
#      這一步會順便建立 AWS Organizations，本帳號成為 management account。
#   2. Settings > Authentication > Standard authentication 開啟「Send email OTP」，
#      這裡建立的使用者第一次登入時才會收到設定密碼的信。
#
# Identity Center 的資料存在 ap-east-2，所以 provider 必須在同一區（infra 的預設就是）。

data "aws_caller_identity" "current" {}

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = one(data.aws_ssoadmin_instances.this.arns)
  identity_store_id = one(data.aws_ssoadmin_instances.this.identity_store_ids)
  account_id        = data.aws_caller_identity.current.account_id

  # 權限組合：名稱 => 設定。平常用 ReadOnly，要改東西才切 Administrator。
  permission_sets = {
    ReadOnly = {
      description      = "唯讀，日常查看用"
      managed_policy   = "arn:aws:iam::aws:policy/ReadOnlyAccess"
      session_duration = "PT8H"
    }
    Administrator = {
      description      = "完整權限，需要修改時才使用"
      managed_policy   = "arn:aws:iam::aws:policy/AdministratorAccess"
      session_duration = "PT4H"
    }
  }
}

# ---------- 使用者與群組 ----------

resource "aws_identitystore_user" "miskawu" {
  identity_store_id = local.identity_store_id

  user_name    = "miskawu"
  display_name = "Miska Wu"

  name {
    given_name  = "Miska"
    family_name = "Wu"
  }

  emails {
    value   = "you@example.com"
    primary = true
  }
}

# 權限指派給群組而不是個人，之後加人只要加進群組
resource "aws_identitystore_group" "admins" {
  identity_store_id = local.identity_store_id
  display_name      = "admins"
  description       = "帳號管理者：可用 ReadOnly 與 Administrator"
}

resource "aws_identitystore_group_membership" "admins_miskawu" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.admins.group_id
  member_id         = aws_identitystore_user.miskawu.user_id
}

# ---------- 權限組合與指派 ----------

resource "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_sets

  instance_arn     = local.sso_instance_arn
  name             = each.key
  description      = each.value.description
  session_duration = each.value.session_duration
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = local.permission_sets

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  managed_policy_arn = each.value.managed_policy
}

resource "aws_ssoadmin_account_assignment" "admins" {
  for_each = local.permission_sets

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.key].arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.admins.group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = local.account_id

  # 先掛好政策再指派，避免第一次登入時拿到沒有權限的角色
  depends_on = [aws_ssoadmin_managed_policy_attachment.this]
}

output "sso_instance_arn" {
  value = local.sso_instance_arn
}

output "identity_store_id" {
  value = local.identity_store_id
}
