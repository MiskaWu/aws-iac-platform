# 兩份 SSM 文件：
#   PlatformSync  把 _platform/ 同步到主機並執行 install.sh。用 State Manager 的 association 綁在主機上：
#                 建立時（新主機）與平台檔案改了的時候自動執行，第一次開機和之後的更新是同一條路。
#   TenantDeploy  部署一個專案：主機上的 tenant-deploy 從 S3 拿部署包、同步秘密、安裝 Quadlet 單元、重啟。
#                 只接受專案名稱一個參數；之後給 CI 的部署角色只授權這份文件，不授權 AWS-RunShellScript。
#
# SSM 的指令不保證有 HOME 與 /snap/bin（AWS CLI 是 snap 裝的），所以每份都先設好。

resource "aws_ssm_document" "platform_sync" {
  name            = "PlatformSync"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Apply the shared host platform files from s3://${module.deploy_bucket.name}/_platform/"
    parameters = {
      revision = {
        type        = "String"
        description = "Hash of the platform files; a new value re-runs the association"
        default     = ""
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "sync"
      inputs = {
        timeoutSeconds = "1800"
        runCommand = [
          "set -euo pipefail",
          "export HOME=/root PATH=\"$PATH:/snap/bin\"",
          "echo 'revision {{ revision }}'",
          "cloud-init status --wait >/dev/null || true # 新主機：等 cloud-init 掛好資料碟、裝好套件",
          "aws s3 sync --delete --only-show-errors s3://${module.deploy_bucket.name}/_platform/ /usr/local/lib/platform/",
          "bash /usr/local/lib/platform/install.sh",
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "platform_sync" {
  name             = aws_ssm_document.platform_sync.name
  association_name = "platform-sync"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.host.id]
  }

  parameters = {
    revision = local.platform_revision
  }

  apply_only_at_cron_interval = false
  max_errors                  = "0"
  compliance_severity         = "HIGH"

  depends_on = [
    aws_s3_object.platform,
    aws_s3_object.platform_env,
    aws_volume_attachment.data,
    aws_iam_role_policy.host,
  ]
}

resource "aws_ssm_document" "tenant_deploy" {
  name            = "TenantDeploy"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Deploy one tenant on the shared host from s3://${module.deploy_bucket.name}/<project>/bundle.tar.gz"
    parameters = {
      project = {
        type           = "String"
        description    = "Project name (a key of var.projects)"
        allowedPattern = "^[a-z0-9][a-z0-9-]*$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deploy"
      inputs = {
        timeoutSeconds = "900"
        runCommand = [
          "export HOME=/root PATH=\"$PATH:/snap/bin\"",
          "/usr/local/sbin/tenant-deploy '{{ project }}'",
        ]
      }
    }]
  })
}
