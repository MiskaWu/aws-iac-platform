# bootstrap 用的 Makefile，設計給 AWS CloudShell（root 登入）使用。
# 典型流程：make plan → 看過輸出 → make apply → make migrate
# 之後 bootstrap/backend.tf 進了 repo，再改 bootstrap 只要 make plan / make apply。
# 本機只會用到 make tofu 和 make lock。

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

BOOTSTRAP := bootstrap
INFRA     := infra
PLANFILE  := /tmp/bootstrap.tfplan

# OpenTofu 版本只寫在 .opentofu-version，CI 也讀同一個檔。
# 每個版本裝在自己的目錄，改版本號就會裝新版，不覆蓋舊版、不需要 root。
TOFU_VERSION := $(strip $(file < .opentofu-version))
ifeq ($(TOFU_VERSION),)
$(error 讀不到 .opentofu-version，請在 repo 根目錄執行 make)
endif
TOFU_DIR := $(or $(XDG_CACHE_HOME),$(HOME)/.cache)/opentofu/$(TOFU_VERSION)
TOFU     := $(TOFU_DIR)/tofu

# 鎖檔要涵蓋的平台：CloudShell 與 CI 是 linux_amd64，本機 Mac 是 darwin_arm64
LOCK_PLATFORMS := linux_amd64 darwin_arm64

# CloudShell 家目錄只有 1 GB，provider 放 /tmp
export TF_DATA_DIR ?= /tmp/tofu-bootstrap
export TF_IN_AUTOMATION := 1

.PHONY: help tofu lock init plan apply migrate output clean

help:
	@echo "make tofu     安裝 .opentofu-version 指定的 OpenTofu（已安裝則略過）"
	@echo "make lock     重新產生 bootstrap 與 infra 的 provider 鎖檔"
	@echo "make plan     init 並產生計畫檔，請檢查輸出"
	@echo "make apply    套用上一步的計畫檔"
	@echo "make migrate  第一次 apply 後，把 bootstrap state 搬進 S3"
	@echo "make output   顯示角色 ARN 與 bucket 名稱"

tofu:
	@if [ ! -x $(TOFU) ]; then \
	  installer="$$(mktemp)"; \
	  trap 'rm -f "$$installer"' EXIT; \
	  curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o "$$installer"; \
	  bash "$$installer" --install-method standalone --root-method none \
	    --opentofu-version $(TOFU_VERSION) --install-path $(TOFU_DIR) --symlink-path -; \
	fi
	@$(TOFU) version | grep -xF 'OpenTofu v$(TOFU_VERSION)' >/dev/null || { echo "$(TOFU) 不是 v$(TOFU_VERSION)，刪掉 $(TOFU_DIR) 再重跑"; exit 1; }
	@$(TOFU) version

lock: tofu
	cd $(BOOTSTRAP) && $(TOFU) providers lock $(addprefix -platform=,$(LOCK_PLATFORMS))
	cd $(INFRA) && $(TOFU) providers lock $(addprefix -platform=,$(LOCK_PLATFORMS))

init: tofu
	@test -f $(BOOTSTRAP)/terraform.tfvars || { echo "缺少 $(BOOTSTRAP)/terraform.tfvars"; exit 1; }
	cd $(BOOTSTRAP) && $(TOFU) init -input=false

plan: init
	cd $(BOOTSTRAP) && $(TOFU) plan -input=false -out=$(PLANFILE)
	@echo
	@echo "確認上面的變更無誤後，執行 make apply"

apply: tofu
	@test -f $(PLANFILE) || { echo "找不到計畫檔，先執行 make plan"; exit 1; }
	cd $(BOOTSTRAP) && $(TOFU) apply -input=false $(PLANFILE)
	@rm -f $(PLANFILE)
	@if [ ! -f $(BOOTSTRAP)/backend.tf ]; then echo; echo "第一次套用完成，接著執行 make migrate"; fi

migrate: tofu
	@test ! -f $(BOOTSTRAP)/backend.tf || { echo "backend.tf 已存在，state 應該已經在 S3"; exit 1; }
	@test -f $(BOOTSTRAP)/terraform.tfstate || { echo "找不到本機 state，先完成 make apply"; exit 1; }
	@bucket="$$(cd $(BOOTSTRAP) && $(TOFU) output -raw state_bucket)"; \
	  grep -q "\"$$bucket\"" $(BOOTSTRAP)/backend.tf.example || { echo "backend.tf.example 的 bucket 和實際的 $$bucket 不一致，先修正"; exit 1; }
	cp $(BOOTSTRAP)/backend.tf.example $(BOOTSTRAP)/backend.tf
	cd $(BOOTSTRAP) && $(TOFU) init -input=false -migrate-state -force-copy
	rm -f $(BOOTSTRAP)/terraform.tfstate $(BOOTSTRAP)/terraform.tfstate.backup
	@echo
	@echo "state 已搬進 S3。回本機把 bootstrap/backend.tf.example 改名成 backend.tf 並 commit。"

output: init
	cd $(BOOTSTRAP) && $(TOFU) output

clean:
	rm -rf $(TF_DATA_DIR) $(PLANFILE)
