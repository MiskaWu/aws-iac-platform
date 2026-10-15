github_owner    = "MiskaWu"
github_owner_id = "37805889"

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
}
