# 每個專案一個 ECR 倉庫，和一個只能推到該倉庫的 GitHub Actions 角色（OIDC，沒有長期金鑰）。
#
# 標籤不可覆寫，只有 main 與 latest 例外（CI 每次都會把它們移到最新的一顆）。部署照 sha-<7 碼> 換版。
# 生命週期：sha- 標籤保留最近 30 個；沒有標籤的超過 30 天清掉。多平台映像的子映像沒有標籤，
# 但被 manifest list 引用時不會被清（ECR 的生命週期規則），只有 list 被清掉之後留下的孤兒才會被回收。

resource "aws_ecr_repository" "project" {
  for_each = var.projects

  name                 = each.key
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = ["main", "latest"]
    content {
      filter      = image_tag_mutability_exclusion_filter.value
      filter_type = "WILDCARD"
    }
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "project" {
  for_each = aws_ecr_repository.project

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "keep the newest 30 sha- tags"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "untagged images older than 30 days (children of a live manifest list are kept)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ---------- GitHub Actions 推映像的角色 ----------
# 信任條件比照 bootstrap/roles.tf 的 apply 角色：aud、sub（新舊兩種格式）、repository_id、job_workflow_ref。
# 允許 main 分支與 v* 標籤（CI 在這兩種事件推映像）。

data "aws_iam_policy_document" "ecr_push_trust" {
  for_each = var.projects

  statement {
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
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = flatten([for prefix in [
        "repo:${var.github_owner}/${each.value.github_repo}",
        "repo:${var.github_owner}@${var.github_owner_id}/${each.value.github_repo}@${each.value.github_repository_id}",
      ] : ["${prefix}:ref:refs/heads/main", "${prefix}:ref:refs/tags/v*"]])
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_id"
      values   = [each.value.github_repository_id]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:job_workflow_ref"
      values = [
        "${var.github_owner}/${each.value.github_repo}/${each.value.push_workflow}@refs/heads/main",
        "${var.github_owner}/${each.value.github_repo}/${each.value.push_workflow}@refs/tags/v*",
      ]
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  for_each = var.projects

  name                 = "github-ecr-push-${each.key}"
  description          = "Push images to ECR ${each.key} from GitHub Actions: ${var.github_owner}/${each.value.github_repo}"
  assume_role_policy   = data.aws_iam_policy_document.ecr_push_trust[each.key].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ecr_push" {
  for_each = aws_ecr_repository.project

  statement {
    sid       = "Login"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushToOwnRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [each.value.arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  for_each = aws_ecr_repository.project

  name   = "ecr-push"
  role   = aws_iam_role.ecr_push[each.key].id
  policy = data.aws_iam_policy_document.ecr_push[each.key].json
}
