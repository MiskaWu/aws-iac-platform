# aws-infra（2026-10-07 建立，OIDC sub 使用含 ID 的新格式）
# 2026-10-19 起搬到組織 sinshotgames（docs/org-migration.md）：搬家期間新舊兩個擁有者都信任，
# aws-infra 移轉、確認 CI 正常之後，拿掉 MiskaWu 那一行再套用一次。
github_owners = [
  { name = "MiskaWu", id = "37805889" },
  { name = "sinshotgames", id = "344725661" },
]
github_repo          = "aws-infra"
github_repository_id = "1408978994"

region = "ap-east-2" # 台北；CloudShell 在東京開，這個值決定 bucket 建在哪
