# 寄信（Amazon SES）：projects 裡有填 ses 的專案（docs/host-platform.md「寄信（SES）」，負責人 2026-10-15 定甲案）。
#
# 沒有長期金鑰：每個專案一個只能寄信的角色，只信任主機角色。主機每 15 分鐘 assume 一次（tenant-credentials），
# 1 小時效期的臨時憑證寫成 /srv/<專案>/aws/credentials.json，專案的容器唯讀掛進去讀。容器本身拿不到主機的角色（IMDS 擋著）。
# SES 在東京（台北沒有）。寄件網域的 DKIM 記錄由 output ses_dkim_records 列出：網域在 Cloudflare，由負責人自己加。

provider "aws" {
  alias  = "ses"
  region = "ap-northeast-1"

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Stack     = "infra"
    }
  }
}

locals {
  ses_region   = "ap-northeast-1"
  ses_projects = { for name, p in var.projects : name => p.ses if p.ses != null }
  ses_domains  = toset([for s in values(local.ses_projects) : s.from_domain])
}

# 寄件網域（Easy DKIM）：DKIM 的 CNAME 加好之後 SES 自己驗證
resource "aws_sesv2_email_identity" "domain" {
  for_each = local.ses_domains
  provider = aws.ses

  email_identity = each.value
}

data "aws_iam_policy_document" "ses_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.host.arn]
    }
  }
}

resource "aws_iam_role" "ses" {
  for_each = local.ses_projects

  name                 = "platform-ses-${each.key}"
  description          = "Send mail via SES as *@${each.value.from_domain}; assumed by the shared host for ${each.key}'s containers"
  assume_role_policy   = data.aws_iam_policy_document.ses_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ses_send" {
  for_each = local.ses_projects

  statement {
    sid     = "SendAsOwnDomain"
    actions = ["ses:SendEmail", "ses:SendRawEmail"]
    # 沙盒期間 SES 連收件人的 identity 也檢查，所以資源是帳號在東京的所有 identity；寄件人由條件限在自己的網域
    resources = ["arn:${local.partition}:ses:${local.ses_region}:${local.account_id}:identity/*"]

    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = ["*@${each.value.from_domain}"]
    }
  }
}

resource "aws_iam_role_policy" "ses" {
  for_each = local.ses_projects

  name   = "ses-send"
  role   = aws_iam_role.ses[each.key].id
  policy = data.aws_iam_policy_document.ses_send[each.key].json
}
