# 共用主機：Ubuntu 26.04 arm64、rootful podman（Quadlet）。
#
# 主機本身是可以換掉的；狀態都在 /srv 資料碟（獨立的 EBS，換主機時留著、掛到新主機）。
# 第一次開機的 cloud-init 只做兩件事：掛資料碟、裝套件。其餘的設定（podman、共用入口、tenant-deploy、備份）
# 全部由 ssm.tf 的 PlatformSync 從 S3 套用，第一次開機與之後的更新走同一條路。

# Canonical 公布的 AMI；之後 AMI 更新不會讓主機被重建（ignore_changes），要換新 AMI 就 tofu apply -replace
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/26.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

data "aws_ec2_instance_type_offerings" "host" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.host_instance_type]
  }

  filter {
    name   = "location"
    values = [var.host_availability_zone]
  }
}

locals {
  # infra/host/packages.txt：一行一個套件，# 開頭是註解
  host_packages = [
    for line in split("\n", file("${path.module}/host/packages.txt")) : trimspace(line)
    if trimspace(line) != "" && !startswith(trimspace(line), "#")
  ]
}

# ---------- IAM ----------

data "aws_iam_policy_document" "host_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "platform-host"
  description        = "Shared host: SSM, pull from ECR, read tenant secrets and bundles, write backups"
  assume_role_policy = data.aws_iam_policy_document.host_trust.json
}

resource "aws_iam_role_policy_attachment" "host_managed" {
  for_each = toset([
    "AmazonSSMManagedInstanceCore",       # Session Manager 登入、Run Command、State Manager
    "AmazonEC2ContainerRegistryReadOnly", # podman 經 ecr-login 拉映像
  ])

  role       = aws_iam_role.host.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

data "aws_iam_policy_document" "host" {
  # 每個專案的秘密（tenant-deploy 同步成 podman secret）。SecureString 用 aws/ssm 預設金鑰，不用另外給 KMS 權限
  statement {
    sid     = "TenantSecrets"
    actions = ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:GetParameters"]
    resources = flatten([for name in keys(var.projects) : [
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${name}",
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${name}/*",
    ]])
  }

  # 平台自己的秘密（install.sh 同步成 podman secret）：/platform/CLOUDFLARE_API_TOKEN（edge-caddy 的 DNS-01）
  statement {
    sid     = "PlatformSecrets"
    actions = ["ssm:GetParametersByPath", "ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/platform",
      "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/platform/*",
    ]
  }

  # 平台檔案（_platform/）與各專案的部署包：只能讀
  statement {
    sid       = "ReadPlatformAndBundles"
    actions   = ["s3:GetObject"]
    resources = concat(["${module.deploy_bucket.arn}/_platform/*"], [for name in keys(var.projects) : "${module.deploy_bucket.arn}/${name}/*"])
  }

  statement {
    sid       = "ListPlatformFiles"
    actions   = ["s3:ListBucket"]
    resources = [module.deploy_bucket.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["_platform/*"]
    }
  }

  # 備份只能寫、不能讀也不能刪：主機被打進去也毀不掉備份
  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject"]
    resources = [for name in keys(var.projects) : "${module.backup_bucket.arn}/${name}/*"]
  }
}

resource "aws_iam_role_policy" "host" {
  name   = "platform-host"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.host.json
}

resource "aws_iam_instance_profile" "host" {
  name = "platform-host"
  role = aws_iam_role.host.name
}

# ---------- /srv 資料碟 ----------

resource "aws_ebs_volume" "data" {
  availability_zone = var.host_availability_zone
  size              = var.host_data_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name     = "platform-data"
    Snapshot = "daily" # dlm 的對象
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ---------- 主機 ----------

# 換主機的開關：terraform.tfvars 的 host_generation 加一，開 PR，合併後 CI 就換一台新主機
# （資料碟、Elastic IP 留著；新主機的 PlatformSync 會把已部署的專案從 /srv 裝回來）。
# 這個資源第一次建立時也會觸發一次替換。
resource "terraform_data" "host_generation" {
  input = var.host_generation
}

resource "aws_instance" "host" {
  ami                    = data.aws_ssm_parameter.ubuntu.insecure_value
  instance_type          = var.host_instance_type
  subnet_id              = data.aws_subnet.host.id
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.host.name

  # 只開 IMDSv2、跳數 1：rootful podman 的容器經過 NAT 多一跳，拿不到主機的 IAM 憑證
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 10
    encrypted   = true
  }

  credit_specification {
    cpu_credits = var.host_cpu_credits
  }

  maintenance_options {
    auto_recovery = "default" # 硬體故障時自動搬到新的實體主機，IP 與資料碟不變
  }

  # 主機本身可以換掉（狀態都在 /srv 資料碟），所以不開防誤刪：換主機是 tofu apply -replace=aws_instance.host。
  # 不能刪的是資料碟與 Elastic IP，它們有 prevent_destroy。
  disable_api_termination = false

  user_data = templatefile("${path.module}/host/cloud-init.yaml.tftpl", {
    data_volume_id = aws_ebs_volume.data.id
    mount_script   = file("${path.module}/host/mount-data.sh")
    packages       = local.host_packages
  })

  tags = {
    Name = "platform-host"
  }

  lifecycle {
    # AMI 有新版、cloud-init 改了都不重建主機；平台設定的更新走 PlatformSync
    ignore_changes       = [ami, user_data]
    replace_triggered_by = [terraform_data.host_generation]

    precondition {
      condition     = length(data.aws_ec2_instance_type_offerings.host.instance_types) > 0
      error_message = "${var.host_availability_zone} 沒有 ${var.host_instance_type}，換一個可用區域或機型。"
    }
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf" # Nitro 主機上實際是 NVMe，cloud-init 用 volume id 找裝置
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.host.id

  stop_instance_before_detaching = true
}

resource "aws_eip" "host" {
  domain = "vpc"

  tags = {
    Name = "platform-host"
  }

  lifecycle {
    prevent_destroy = true # DNS 指著它
  }
}

resource "aws_eip_association" "host" {
  allocation_id = aws_eip.host.id
  instance_id   = aws_instance.host.id
}

# ---------- 資料碟每天快照（Data Lifecycle Manager）----------

data "aws_iam_policy_document" "dlm_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "platform-dlm"
  description        = "Data Lifecycle Manager: daily snapshots of the shared host data volume"
  assume_role_policy = data.aws_iam_policy_document.dlm_trust.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "platform-data daily snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "daily" }

    schedule {
      name      = "daily"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["19:00"] # UTC，台北 03:00；在各專案 04:17 的備份之前
      }

      retain_rule {
        count = 7
      }
    }
  }
}
