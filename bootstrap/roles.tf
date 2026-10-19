# 兩個角色：
#   github-tofu-apply：AdministratorAccess，只有指定 repo、main 分支、指定 workflow 檔能扮演
#   github-tofu-plan ：ReadOnlyAccess + infra state 鎖檔寫入，只有該 repo 的 pull_request 事件能扮演
# 權限大小靠「誰能扮演」來鎖，而不是靠政策本身。
# 同一個 condition 運算子下的多個 key 是 AND；同一個 key 的多個 value 是 OR。

# ---------- apply ----------

data "aws_iam_policy_document" "apply_trust" {
  statement {
    sid     = "GitHubActionsApplyBranch"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # job 若設定了 environment:，sub 會變成 ...:environment:NAME，這裡就不會符合
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [for p in local.sub_prefixes : "${p}:ref:refs/heads/${var.apply_branch}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_id"
      values   = [var.github_repository_id]
    }

    # 只有這個 workflow 檔能拿 Admin。main 上其他 workflow（schedule、issue_comment、
    # workflow_dispatch 等）即使拿得到 OIDC token，也不符合這個條件。
    dynamic "condition" {
      for_each = var.pin_workflow_file ? [var.workflow_file] : []
      content {
        test     = "StringEquals"
        variable = "${local.oidc_host}:job_workflow_ref"
        values   = [for r in local.repo_fulls : "${r}/${condition.value}@refs/heads/${var.apply_branch}"]
      }
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "github-tofu-apply"
  description          = "OpenTofu apply from GitHub Actions: ${join(", ", local.repo_fulls)} branch ${var.apply_branch}"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

# ---------- plan ----------

data "aws_iam_policy_document" "plan_trust" {
  statement {
    sid     = "GitHubActionsPullRequest"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [for p in local.sub_prefixes : "${p}:pull_request"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_id"
      values   = [var.github_repository_id]
    }

    # pull_request 事件的 ref 是 refs/pull/N/merge；pull_request_target 的 ref 是 base 分支，
    # 這個條件把 pull_request_target 排除在外。
    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:ref"
      values   = ["refs/pull/*/merge"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "github-tofu-plan"
  description          = "OpenTofu plan from GitHub Actions pull requests: ${join(", ", local.repo_fulls)}"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

# plan 也要取得 state 鎖，只開放 infra 這份 state 的鎖檔
data "aws_iam_policy_document" "plan_state_lock" {
  statement {
    sid       = "InfraStateLockFile"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/infra/terraform.tfstate.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_state_lock" {
  name   = "infra-state-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state_lock.json
}
