# bootstrap 用的 Makefile，設計給 AWS CloudShell（root 登入）使用。
# 典型流程：make plan → 看過輸出 → make apply → make migrate
# 之後 bootstrap/backend.tf 進了 repo，再改 bootstrap 只要 make plan / make apply。
# 本機只會用到 make tofu、make lock，以及升級 OpenTofu 時的 make tofu-pin。

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

BOOTSTRAP := bootstrap
INFRA     := infra
PLANFILE  := /tmp/bootstrap.tfplan

# OpenTofu 版本寫在 .opentofu-version，各平台安裝檔的 SHA256 寫在 .opentofu-checksums，CI 也讀這兩個檔。
# make tofu 只比對雜湊，不需要 GnuPG、cosign 或 root；官方簽章在升級版本時由 make tofu-pin 驗一次。
# 每個版本裝在自己的目錄，改版本號就會裝新版，不覆蓋舊版。
TOFU_VERSION := $(strip $(file < .opentofu-version))
ifeq ($(TOFU_VERSION),)
$(error 讀不到 .opentofu-version，請在 repo 根目錄執行 make)
endif
TOFU_DIR := $(or $(XDG_CACHE_HOME),$(HOME)/.cache)/opentofu/$(TOFU_VERSION)
TOFU     := $(TOFU_DIR)/tofu

TOFU_OS      := $(shell uname -s | tr '[:upper:]' '[:lower:]')
TOFU_ARCH    := $(shell uname -m | sed -e 's/^x86_64$$/amd64/' -e 's/^aarch64$$/arm64/')
TOFU_ZIP     := tofu_$(TOFU_VERSION)_$(TOFU_OS)_$(TOFU_ARCH).zip
TOFU_RELEASE := https://github.com/opentofu/opentofu/releases/download/v$(TOFU_VERSION)
SHA256       := $(if $(shell command -v sha256sum),sha256sum,shasum -a 256)

# OpenTofu 官方簽章金鑰。tofu-pin 只接受主金鑰指紋等於這串的簽章，金鑰檔被換掉也過不了。
TOFU_GPG_KEY := https://get.opentofu.org/opentofu.asc
TOFU_GPG_FPR := E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80

# 鎖檔要涵蓋的平台：CloudShell 與 CI 是 linux_amd64，本機 Mac 是 darwin_arm64
LOCK_PLATFORMS := linux_amd64 darwin_arm64

# bootstrap 的目標區域，取自 terraform.tfvars。台北（ap-east-2）是需要手動啟用的區域。
REGION := $(shell sed -n 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' $(BOOTSTRAP)/terraform.tfvars 2>/dev/null)

# CloudShell 家目錄只有 1 GB，provider 放 /tmp
export TF_DATA_DIR ?= /tmp/tofu-bootstrap
export TF_IN_AUTOMATION := 1

.PHONY: help tofu tofu-pin lock region-check enable-region init plan apply migrate output clean

help:
	@echo "make tofu     安裝 .opentofu-version 指定的 OpenTofu（已安裝則略過）"
	@echo "make tofu-pin 改了 .opentofu-version 之後執行：驗證官方簽章並更新 .opentofu-checksums"
	@echo "make lock     重新產生 bootstrap 與 infra 的 provider 鎖檔"
	@echo "make region-check   確認 terraform.tfvars 的區域已在帳號啟用（make plan 會先跑）"
	@echo "make enable-region  啟用該區域（只需一次，要等幾分鐘）"
	@echo "make plan     init 並產生計畫檔，請檢查輸出"
	@echo "make apply    套用上一步的計畫檔"
	@echo "make migrate  第一次 apply 後，把 bootstrap state 搬進 S3"
	@echo "make output   顯示角色 ARN 與 bucket 名稱"

tofu:
	@if [ ! -x $(TOFU) ]; then \
	  sum="$$(awk '$$2 == "$(TOFU_ZIP)" { print $$1 }' .opentofu-checksums)"; \
	  [ -n "$$sum" ] || { echo ".opentofu-checksums 沒有 $(TOFU_ZIP) 的雜湊，先在本機執行 make tofu-pin"; exit 1; }; \
	  tmp="$$(mktemp -d)"; \
	  trap 'rm -rf "$$tmp"' EXIT; \
	  echo "下載 $(TOFU_ZIP)"; \
	  curl --proto '=https' --tlsv1.2 -fsSL "$(TOFU_RELEASE)/$(TOFU_ZIP)" -o "$$tmp/$(TOFU_ZIP)"; \
	  (cd "$$tmp" && echo "$$sum  $(TOFU_ZIP)" | $(SHA256) -c - >/dev/null) \
	    || { echo "$(TOFU_ZIP) 和 .opentofu-checksums 記錄的雜湊不符，不安裝"; exit 1; }; \
	  mkdir -p $(TOFU_DIR); \
	  unzip -p "$$tmp/$(TOFU_ZIP)" tofu > $(TOFU).partial; \
	  chmod +x $(TOFU).partial; \
	  mv $(TOFU).partial $(TOFU); \
	fi
	@$(TOFU) version | grep -xF 'OpenTofu v$(TOFU_VERSION)' >/dev/null || { echo "$(TOFU) 不是 v$(TOFU_VERSION)，刪掉 $(TOFU_DIR) 再重跑"; exit 1; }
	@$(TOFU) version

tofu-pin:
	@tmp="$$(mktemp -d)"; \
	trap 'gpgconf --homedir "$$tmp/gnupg" --kill all 2>/dev/null || true; rm -rf "$$tmp"' EXIT; \
	sums="tofu_$(TOFU_VERSION)_SHA256SUMS"; \
	for f in "$$sums" "$$sums.gpgsig"; do \
	  curl --proto '=https' --tlsv1.2 -fsSL "$(TOFU_RELEASE)/$$f" -o "$$tmp/$$f"; \
	done; \
	curl --proto '=https' --tlsv1.2 -fsSL $(TOFU_GPG_KEY) -o "$$tmp/key.asc"; \
	mkdir -m 700 "$$tmp/gnupg"; \
	gpg --batch --quiet --homedir "$$tmp/gnupg" --import "$$tmp/key.asc" 2>/dev/null; \
	gpg --batch --homedir "$$tmp/gnupg" --status-fd 1 --verify "$$tmp/$$sums.gpgsig" "$$tmp/$$sums" 2>/dev/null \
	  | grep -E '^\[GNUPG:\] VALIDSIG .* $(TOFU_GPG_FPR)$$' >/dev/null \
	  || { echo "$$sums 不是 OpenTofu 官方金鑰 $(TOFU_GPG_FPR) 簽的，不更新"; exit 1; }; \
	grep -E '  tofu_$(TOFU_VERSION)_[a-z0-9]+_[a-z0-9]+\.zip$$' "$$tmp/$$sums" | sort -k2 > "$$tmp/pins"; \
	mv "$$tmp/pins" .opentofu-checksums; \
	echo "官方簽章驗證通過，.opentofu-checksums 已更新為 v$(TOFU_VERSION)（$$(wc -l < .opentofu-checksums | tr -d ' ') 個平台）"

lock: tofu
	cd $(BOOTSTRAP) && $(TOFU) providers lock $(addprefix -platform=,$(LOCK_PLATFORMS))
	cd $(INFRA) && $(TOFU) providers lock $(addprefix -platform=,$(LOCK_PLATFORMS))

region-check:
	@if [ -z "$(REGION)" ]; then echo "terraform.tfvars 沒寫 region，略過區域檢查"; exit 0; fi; \
	status="$$(aws account get-region-opt-status --region us-east-1 --region-name $(REGION) --query RegionOptStatus --output text)"; \
	case "$$status" in \
	  ENABLED|ENABLED_BY_DEFAULT) echo "區域 $(REGION)：$$status" ;; \
	  ENABLING) echo "區域 $(REGION) 啟用中，過幾分鐘再跑一次。"; exit 1 ;; \
	  *) echo "區域 $(REGION) 目前是 $$status。先執行 make enable-region，等狀態變成 ENABLED 再繼續。"; exit 1 ;; \
	esac

enable-region:
	@test -n "$(REGION)" || { echo "terraform.tfvars 沒寫 region"; exit 1; }
	aws account enable-region --region us-east-1 --region-name $(REGION)
	@echo "已送出啟用要求，通常幾分鐘內完成。用 make region-check 確認狀態。"

init: tofu region-check
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
