variable "name" {
  description = "Bucket 名稱。"
  type        = string
}

variable "expire_current_days" {
  description = "目前版本幾天後刪除；null 表示不刪。"
  type        = number
  default     = null
}

variable "expire_noncurrent_days" {
  description = "舊版本（被覆蓋或刪除的）幾天後清掉。"
  type        = number
}
