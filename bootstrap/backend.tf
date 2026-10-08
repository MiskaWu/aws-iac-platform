# bootstrap 自己的 state 也放在它建立的 bucket 裡（第一次套用後由 make migrate 搬進來）。
# 刪掉這個檔，下次 init 會改用空的本機 state，plan 會試圖重建所有資源。

terraform {
  backend "s3" {
    bucket       = "tofu-state-123456789012-ap-east-2"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-east-2"
    use_lockfile = true
  }
}
