# bootstrap 用的 Makefile，設計給 AWS CloudShell（root 登入）使用。
# 典型流程：make plan → 看過輸出 → make apply → make migrate
# 之後 bootstrap/backend.tf 進了 repo，再改 bootstrap 只要 make plan / make apply。

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

BOOTSTRAP := bootstrap
PLANFILE  := /tmp/bootstrap.tfplan

# CloudShell 家目錄只有 1 GB，provider 放 /tmp
export TF_DATA_DIR ?= /tmp/tofu-bootstrap
export TF_IN_AUTOMATION := 1

.PHONY: help tofu init plan apply migrate output clean

help:
	@echo "make tofu     安裝 OpenTofu（CloudShell 每個新工作階段都要，已安裝則略過）"
	@echo "make plan     init 並產生計畫檔，請檢查輸出"
	@echo "make apply    套用上一步的計畫檔"
	@echo "make migrate  第一次 apply 後，把 bootstrap state 搬進 S3"
	@echo "make output   顯示角色 ARN 與 bucket 名稱"

tofu:
	@if ! command -v tofu >/dev/null 2>&1; then \
	  curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh; \
	  chmod +x /tmp/install-opentofu.sh; \
	  /tmp/install-opentofu.sh --install-method standalone; \
	  rm -f /tmp/install-opentofu.sh; \
	fi
	@tofu version

init: tofu
	@test -f $(BOOTSTRAP)/terraform.tfvars || { echo "缺少 $(BOOTSTRAP)/terraform.tfvars"; exit 1; }
	cd $(BOOTSTRAP) && tofu init -input=false

plan: init
	cd $(BOOTSTRAP) && tofu plan -input=false -out=$(PLANFILE)
	@echo
	@echo "確認上面的變更無誤後，執行 make apply"

apply: tofu
	@test -f $(PLANFILE) || { echo "找不到計畫檔，先執行 make plan"; exit 1; }
	cd $(BOOTSTRAP) && tofu apply -input=false $(PLANFILE)
	@rm -f $(PLANFILE)
	@if [ ! -f $(BOOTSTRAP)/backend.tf ]; then echo; echo "第一次套用完成，接著執行 make migrate"; fi

migrate: tofu
	@test ! -f $(BOOTSTRAP)/backend.tf || { echo "backend.tf 已存在，state 應該已經在 S3"; exit 1; }
	@test -f $(BOOTSTRAP)/terraform.tfstate || { echo "找不到本機 state，先完成 make apply"; exit 1; }
	@bucket="$$(cd $(BOOTSTRAP) && tofu output -raw state_bucket)"; \
	  grep -q "\"$$bucket\"" $(BOOTSTRAP)/backend.tf.example || { echo "backend.tf.example 的 bucket 和實際的 $$bucket 不一致，先修正"; exit 1; }
	cp $(BOOTSTRAP)/backend.tf.example $(BOOTSTRAP)/backend.tf
	cd $(BOOTSTRAP) && tofu init -input=false -migrate-state -force-copy
	rm -f $(BOOTSTRAP)/terraform.tfstate $(BOOTSTRAP)/terraform.tfstate.backup
	@echo
	@echo "state 已搬進 S3。回本機把 bootstrap/backend.tf.example 改名成 backend.tf 並 commit。"

output: init
	cd $(BOOTSTRAP) && tofu output

clean:
	rm -rf $(TF_DATA_DIR) $(PLANFILE)
