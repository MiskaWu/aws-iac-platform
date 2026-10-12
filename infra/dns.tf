# 網域在這個帳號的 Route 53：每個專案的 dns.names 建一筆 A 記錄指到主機的 Elastic IP。
# 網域在別家（例如 Cloudflare）就不要填 dns，自己把 A 記錄指到 output host_public_ip；Cloudflare 要設成 DNS only（灰色雲）。
# miskawu.com 就是這樣：Cloudflare 上一筆萬用字元 `*` 指到主機，新的子網域只要站台檔、DNS 不用動（docs/host-platform.md「網域」）。
# 先不加 AAAA，理由見 network.tf。

locals {
  dns_records = merge([
    for project, p in var.projects : {
      for name in try(p.dns.names, []) : name => { zone_id = p.dns.zone_id }
    }
  ]...)
}

resource "aws_route53_record" "project" {
  for_each = local.dns_records

  zone_id = each.value.zone_id
  name    = each.key
  type    = "A"
  ttl     = 300
  records = [aws_eip.host.public_ip]
}
