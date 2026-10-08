variable "github_owner" {
  description = "GitHub 使用者名稱，大小寫要和 GitHub 上完全一致。"
  type        = string
}

variable "github_owner_id" {
  description = "Owner 的不可變數字 ID（gh api users/OWNER --jq .id）。2026-07-15 之後建立的 repo，OIDC sub 會帶這個 ID。"
  type        = string
}

variable "projects" {
  description = <<-EOT
    共用主機上的租戶。key 是專案名稱（小寫英數字與 -），加一筆就建好：ECR 倉庫、GitHub Actions 推映像的角色、
    主機讀 Parameter Store /<專案>/* 與部署包的權限、寫備份的權限，以及（有填 dns 時）DNS 記錄。
    租戶要遵守的約定見 docs/host-platform.md。
  EOT
  type = map(object({
    github_repo          = string                                       # repo 名稱，大小寫要和 GitHub 上一致
    github_repository_id = string                                       # gh api repos/OWNER/REPO --jq .id
    push_workflow        = optional(string, ".github/workflows/ci.yml") # 只有這個 workflow 能推映像
    dns = optional(object({
      zone_id = string       # Route 53 的 hosted zone ID（網域在別家就不要填 dns，自己把 A 記錄指到 host_public_ip）
      names   = list(string) # 例如 ["fx.example.com"]
    }))
  }))

  validation {
    condition     = alltrue([for name in keys(var.projects) : can(regex("^[a-z0-9][a-z0-9-]*$", name))])
    error_message = "專案名稱只能有小寫英數字與 -（它同時是 ECR 倉庫、Parameter Store 路徑、主機上的資料夾名稱）。"
  }

  validation {
    condition     = alltrue([for p in values(var.projects) : can(regex("^[0-9]+$", p.github_repository_id))])
    error_message = "github_repository_id 要填 repo 的數字 ID：gh api repos/OWNER/REPO --jq .id（要有讀得到該 repo 的權限）。"
  }
}

variable "host_instance_type" {
  description = "主機機型。要是 arm64（Graviton）：AMI 是 arm64 的 Ubuntu。"
  type        = string
  default     = "t4g.small"
}

variable "host_availability_zone" {
  description = "主機與資料碟所在的可用區域。EBS 只能掛在同一區的主機上，換主機時也要在這一區。"
  type        = string
  default     = "ap-east-2a"
}

variable "host_generation" {
  description = "主機的代數。加一就換一台新主機（新的 AMI、新的 cloud-init 都靠換主機生效），資料碟與 Elastic IP 不變。"
  type        = number
  default     = 1
}

variable "host_data_volume_gb" {
  description = "/srv 資料碟的大小（GB）。只能加大，不能縮小。"
  type        = number
  default     = 20
}

variable "acme_email" {
  description = "Let's Encrypt 的聯絡信箱（憑證快到期、出問題時通知）。留空也能申請憑證，只是收不到通知。"
  type        = string
  default     = ""
}

variable "budget_email" {
  description = "每月費用警報寄給誰；null 表示不建費用警報。"
  type        = string
  default     = null
}

variable "budget_monthly_usd" {
  description = "每月費用上限（美元）：預估會超過 80% 與實際超過 100% 時寄信。"
  type        = number
  default     = 30
}
