# 主機放在預設 VPC 的公開子網路（單台主機用不到自己的 VPC）。
# 對外只開 80、443（TCP）與 443（UDP，HTTP/3）；登入走 SSM Session Manager，不開 22。
# 先不開 IPv6：租戶的限流靠 Caddy 寫的 X-Forwarded-For，IPv6 經 NAT 轉進來會全部變成同一個位址。

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "host" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.host_availability_zone
  default_for_az    = true
}

resource "aws_security_group" "host" {
  name        = "platform-host"
  description = "Shared host: web from anywhere, no SSH (use SSM)"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "host_web" {
  for_each = {
    http  = { protocol = "tcp", port = 80 }
    https = { protocol = "tcp", port = 443 }
    http3 = { protocol = "udp", port = 443 }
  }

  security_group_id = aws_security_group.host.id
  description       = each.key
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "0.0.0.0/0"
}

# OpenTofu 建安全群組時會拿掉 AWS 預設的對外規則，要自己加回來
resource "aws_vpc_security_group_egress_rule" "host_all" {
  security_group_id = aws_security_group.host.id
  description       = "all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
