# 2026-10-19 起搬到組織 sinshotgames（docs/org-migration.md）：搬家期間新舊兩個擁有者都信任，
# 所有 repo 移轉、確認各自的 CI 推得了映像之後，拿掉 MiskaWu 那一行再套用一次。
github_owners = [
  { name = "MiskaWu", id = "37805889" },
  { name = "sinshotgames", id = "344725661" },
]

# 這個 repo（MiskaWu/aws-infra）：CI 建 edge-caddy 的映像（edge-caddy.tf）
platform_github_repository_id = "1408978994"

# 平常 standard；在社群發文、流量可能突然湧進來時改 unlimited（2026-10-09～10-12 ouin-fx 發文期間用過，流量回落後改回）
host_cpu_credits = "standard"

projects = {
  # 歐印FX（MiskaWu/ouin-fx）。網域 ouin-fx.miskawu.com 在 Cloudflare（DNS only），A 記錄自己指到 host_public_ip
  "ouin-fx" = {
    github_repo          = "ouin-fx"
    github_repository_id = "1407134684"
  }
  # 光之籌備士（MiskaWu/quarter-master）。網域 quarter-master.miskawu.com 由 *.miskawu.com 萬用字元回答（docs/host-platform.md「網域」）
  "quarter-master" = {
    github_repo          = "quarter-master"
    github_repository_id = "1412774898"
  }
  # SinShot 作品站與通行證（MiskaWu/sinshot）。網域 sinshot.com：根網址的 A 記錄由負責人加（灰色雲），www 由 *.sinshot.com 回答
  "sinshot" = {
    github_repo          = "sinshot"
    github_repository_id = "1420498632"
    # 通行證的 email 驗證碼：noreply@sinshot.com，臨時憑證在 /srv/sinshot/aws/credentials.json（docs/host-platform.md「寄信（SES）」）
    ses = { from_domain = "sinshot.com" }
  }
  # Vroop（MiskaWu/vroop，翻轉迴圈小遊戲）。網域 vroop.sinshot.com 由 *.sinshot.com 萬用字元回答（docs/host-platform.md「網域」）
  "vroop" = {
    github_repo          = "vroop"
    github_repository_id = "1423424663"
  }
}
