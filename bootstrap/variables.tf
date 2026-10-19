variable "region" {
  description = "State bucket 所在區域，也是 provider 的預設區域。IAM 是全域服務，不受這個值影響。ap-east-2（台北）是需要手動啟用的區域。"
  type        = string
  default     = "ap-east-2"
}

variable "github_owners" {
  description = <<-EOT
    repo 的擁有者（GitHub 使用者或組織）：name 的大小寫要和 GitHub 上完全一致；id 是不可變的數字 ID
    （gh api users/NAME --jq .id），2026-07-15 之後建立、改名或移轉的 repo，OIDC sub 會帶這個 ID。
    平常只有一個。repo 移轉到別的擁有者時（2026-10 MiskaWu → 組織 sinshotgames，docs/org-migration.md），
    先把新的加進來套用、再移轉 repo、最後拿掉舊的 —— 移轉的那一刻新舊兩邊都扮演得到，CI 不會斷。
    repository_id 移轉後不變，所以多一個擁有者不會讓別人的同名 repo 冒用。
  EOT
  type = list(object({
    name = string
    id   = string
  }))

  validation {
    condition     = length(var.github_owners) > 0
    error_message = "至少要有一個擁有者。"
  }
}

variable "github_repo" {
  description = "放 IaC 程式碼的 repo 名稱，大小寫要和 GitHub 上完全一致。"
  type        = string
}

variable "github_repository_id" {
  description = "Repo 的不可變數字 ID（gh api repos/OWNER/REPO --jq .id）。同時用在 sub 與 repository_id 條件，repo 被改名、刪除後同名重建都無法冒用角色。"
  type        = string
}

variable "workflow_file" {
  description = "允許扮演 apply 角色的 workflow 檔案路徑（相對於 repo 根目錄）。"
  type        = string
  default     = ".github/workflows/opentofu.yml"
}

variable "pin_workflow_file" {
  description = "是否用 job_workflow_ref 限定只有 workflow_file 能扮演 apply 角色。只有在 token 不帶這個欄位、導致 apply 被拒時才關掉。"
  type        = bool
  default     = true
}

variable "apply_branch" {
  description = "允許扮演 apply 角色的分支。"
  type        = string
  default     = "main"
}

variable "state_bucket_name" {
  description = "State bucket 名稱。留空則用 tofu-state-<帳號 ID>-<區域>。"
  type        = string
  default     = null
}

variable "create_github_oidc_provider" {
  description = "帳號裡還沒有 GitHub 的 OIDC 身分提供者時設為 true。一個帳號只能有一個同 URL 的提供者。"
  type        = bool
  default     = true
}
