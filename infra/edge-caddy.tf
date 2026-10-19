# edge-caddy 自建的映像（官方 Caddy 加 caddy-dns/cloudflare，DNS-01 申請憑證；docs/host-platform.md「憑證」）。
# 映像由這個 repo 的 .github/workflows/edge-caddy.yml 建（infra/host/platform/edge-caddy/Containerfile），
# 推到這個倉庫的 sha-<7 碼>；主機用哪一個標籤寫在 infra/host/platform/edge-caddy/tag。主機已經能讀所有 ECR 倉庫（host.tf）。

resource "aws_ecr_repository" "edge_caddy" {
  name                 = "edge-caddy"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "edge_caddy" {
  repository = aws_ecr_repository.edge_caddy.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "keep the newest 10 sha- tags (rollback = point edge-caddy/tag at an older one)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
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

# GitHub Actions 推映像的角色：只信任這個 repo 的 main 上的 edge-caddy.yml（信任條件和 registry.tf 的專案角色同一套）
data "aws_iam_policy_document" "edge_caddy_push_trust" {
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
      values = flatten([for o in var.github_owners : [
        "repo:${o.name}/${var.platform_github_repo}:ref:refs/heads/main",
        "repo:${o.name}@${o.id}/${var.platform_github_repo}@${var.platform_github_repository_id}:ref:refs/heads/main",
      ]])
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_id"
      values   = [var.platform_github_repository_id]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:job_workflow_ref"
      values   = [for o in var.github_owners : "${o.name}/${var.platform_github_repo}/.github/workflows/edge-caddy.yml@refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "edge_caddy_push" {
  name                 = "github-ecr-push-edge-caddy"
  description          = "Push the edge-caddy image to ECR from GitHub Actions: ${join(", ", [for o in var.github_owners : "${o.name}/${var.platform_github_repo}"])}"
  assume_role_policy   = data.aws_iam_policy_document.edge_caddy_push_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "edge_caddy_push" {
  statement {
    sid       = "Login"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushToEdgeCaddy"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.edge_caddy.arn]
  }
}

resource "aws_iam_role_policy" "edge_caddy_push" {
  name   = "ecr-push"
  role   = aws_iam_role.edge_caddy_push.id
  policy = data.aws_iam_policy_document.edge_caddy_push.json
}
