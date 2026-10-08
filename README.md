# AWS IaC（OpenTofu）

帳號 123456789012 的基礎設施程式碼。所有資源由 GitHub Actions 透過 OIDC 部署，帳號裡不存放任何長期存取金鑰。

```
bootstrap/   一次性：GitHub OIDC 提供者、兩個部署角色、state bucket。手動套用，CI 不碰。
infra/       之後所有資源都寫在這裡，由 GitHub Actions 部署。
Makefile     安裝 OpenTofu（make tofu）、更新鎖檔（make lock）、在 CloudShell 套用 bootstrap（make plan / apply / migrate）。
.opentofu-version                OpenTofu 版本，本機、CloudShell、CI 都照這個檔安裝。
.opentofu-checksums              該版本各平台安裝檔的 SHA256，安裝時比對。
.github/workflows/opentofu.yml   PR 跑 plan，main 跑 apply。
```

## 工具版本

OpenTofu 本身和 provider 都鎖在 repo 裡，不依賴各台機器上剛好裝了什麼：

| 鎖什麼 | 寫在哪 | 誰讀 |
| --- | --- | --- |
| OpenTofu 版本 | `.opentofu-version` | `make tofu`、CI 的 `setup-opentofu`（`tofu_version`） |
| OpenTofu 安裝檔雜湊 | `.opentofu-checksums` | `make tofu`、CI 的 `setup-opentofu`（`checksums`） |
| provider 版本與雜湊 | `bootstrap/.terraform.lock.hcl`、`infra/.terraform.lock.hcl` | `tofu init` |

`make tofu` 從 GitHub releases 下載該版本的 zip，和 `.opentofu-checksums` 比對雜湊，相符才裝到 `~/.cache/opentofu/<版本>/tofu`。不需要 root、GnuPG 或 cosign，也不碰 PATH 上原本的 `tofu`；已經裝過就直接略過。之後的 `make` 指令都用這一支。

雜湊檔的可信度來自官方簽章，但簽章只在升級時驗一次：`make tofu-pin` 下載官方的 SHA256SUMS 和簽章，只接受主金鑰指紋為 `E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80`（寫在 `Makefile`）的簽章，驗過才寫入 `.opentofu-checksums`。和 provider 鎖檔一樣，雜湊的變更會出現在 PR diff 裡。

- **升級 OpenTofu**：改 `.opentofu-version`，在本機執行 `make tofu-pin`（需要完整版 GnuPG），把兩個檔一起開 PR。CI 會照新版本跑 plan，本機與 CloudShell 下次 `make` 會自動裝新版，舊版留在原目錄不受影響。
- **更新 provider 鎖檔**：`make lock`。改了 `versions.tf` 的版本限制，或要多支援一個平台（`Makefile` 的 `LOCK_PLATFORMS`）時執行，然後 commit 兩個鎖檔。AWS provider 每個平台解開約 700 MB，暫存目錄空間不夠時（例如 WSL 的 `/tmp` 是記憶體 tmpfs）改用磁碟：`TMPDIR=$(mktemp -d -p ~/.cache) make lock`。
- 想在 shell 直接打 `tofu`，可以裝 [tenv](https://github.com/tofuutils/tenv)，它會自動讀 `.opentofu-version`。

## 區域

預設區域是 `ap-east-2`（台北），寫在 `bootstrap/terraform.tfvars` 和 `infra/versions.tf`。客群是台灣和日本；台北的主機、硬碟、S3 是東京的九折，資料傳出網路是九五折。

台北是需要手動啟用的區域，而且**沒有 CloudShell**。所以 CloudShell 要在東京（`ap-northeast-1`）開，bucket 仍會建在台北，因為 provider 的區域是看 `region` 變數，不是看 CloudShell 在哪。

之後如果某個服務台北沒有，可以在 `infra/` 加一個指向東京的 provider alias，只把那個資源放東京。跨區傳輸台北到東京每 GB $0.08、東京到台北每 GB $0.09。

## bootstrap 會建立什麼

| 資源 | 名稱 | 誰能用 | 權限 |
| --- | --- | --- | --- |
| OIDC 身分提供者 | token.actions.githubusercontent.com | — | 讓 AWS 信任 GitHub Actions 發的 token |
| IAM 角色 | `github-tofu-apply` | 指定 repo、`main` 分支、`opentofu.yml` 這個 workflow | AdministratorAccess |
| IAM 角色 | `github-tofu-plan` | 指定 repo 的 `pull_request` 事件 | ReadOnlyAccess + 寫入 infra state 鎖檔 |
| S3 bucket | `tofu-state-123456789012-ap-east-2`（台北） | 上面兩個角色 | 版本控制、加密、封鎖公開、只接受 TLS |

權限大小是靠信任政策（誰能扮演角色）鎖住的。apply 角色要同時符合四個條件：

- `aud` 是 `sts.amazonaws.com`。
- `sub` 是這個 repo 的 `main` 分支。新舊兩種格式都接受：舊格式 `repo:OWNER/REPO:ref:refs/heads/main`，以及 2026-07-15 之後建立、改名或移轉的 repo 使用的 `repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main`。
- `repository_id` 是這個 repo 的不可變 ID，所以 repo 被刪掉、別人用同名重建也冒用不了。
- `job_workflow_ref` 是 `main` 上的 `opentofu.yml`。之後在 main 加其他 workflow（排程、留言觸發等），即使拿得到 OIDC token 也拿不到 Admin。

plan 角色把最後一條換成 `ref` 必須是 `refs/pull/*/merge`，用來排除 `pull_request_target` 事件。

## 第一次設定

這是唯一需要用 root 的流程。分成本機準備、CloudShell 套用、回到本機收尾三段。CloudShell 已預裝 `git` 和 `make`，OpenTofu 由 `make` 自動安裝。

### 1. 本機準備

`bootstrap/terraform.tfvars` 已經填好 `MiskaWu/aws-infra` 的名稱和數字 ID。這個 repo 建立於 2026-10-07，GitHub 發出的 OIDC `sub` 會是含 ID 的新格式。

兩邊的 provider 鎖檔也已經 commit（見「工具版本」），CloudShell、PR 的 plan、main 的 apply 會用同一版 provider。本機不需要再做什麼，直接到 CloudShell。

### 2. CloudShell 套用

在 AWS console 用 root 登入，右上角區域切到 `ap-northeast-1`（東京），打開 CloudShell。台北沒有 CloudShell，見「區域」。

1. 取得程式碼。repo 是私有的，所以用一把唯讀的 deploy key：

   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/aws-iac -N "" -C cloudshell-aws-iac
   cat ~/.ssh/aws-iac.pub
   ```

   把印出的公鑰貼到 [Deploy keys](https://github.com/MiskaWu/aws-infra/settings/keys)，**不要**勾 Allow write access。然後：

   ```sh
   export GIT_SSH_COMMAND="ssh -i ~/.ssh/aws-iac -o IdentitiesOnly=yes"
   git clone git@github.com:MiskaWu/aws-infra.git && cd aws-infra
   ```

   第一次連線會問 GitHub 的主機指紋，對照 GitHub 文件公布的 ED25519 指紋後回答 `yes`。

2. 啟用台北區。已經啟用的話 `make enable-region` 會直接略過，第一次啟用通常幾分鐘內完成：

   ```sh
   make enable-region
   make region-check    # 顯示 ENABLED 才繼續；ENABLING 就等幾分鐘再跑
   ```

   也可以在 console 右上角帳號選單 →「帳戶」→「AWS 區域」手動啟用「亞太地區（台北）」。

3. 產生計畫並檢查：

   ```sh
   make plan
   ```

   輸出應該只有 OIDC 提供者、兩個角色及其政策、state bucket 相關資源。OpenTofu 由 `make` 依 `.opentofu-checksums` 驗證後安裝，CloudShell 不需要另外裝任何套件。

4. 確認無誤後套用，再把 bootstrap 自己的 state 搬進剛建好的 bucket：

   ```sh
   make apply
   make migrate
   make output
   ```

   `make migrate` 會先比對實際的 bucket 名稱和 `backend.tf.example` 是否一致，不一致就停下來。

5. 到 GitHub 把 deploy key 刪掉，並在 CloudShell 執行 `rm -f ~/.ssh/aws-iac ~/.ssh/aws-iac.pub`。

CloudShell 的家目錄只有 1 GB，Makefile 已把 provider 放到 `/tmp`。OpenTofu 本身約 110 MB，裝在家目錄的 `~/.cache/opentofu`，工作階段重開後還在；`/tmp` 會被清掉，但 `make` 會自動重新 init，不必手動處理。

### 3. 回到本機收尾

1. 把 `bootstrap/backend.tf.example` 改名成 `bootstrap/backend.tf`（`git mv`）。少了它，下次跑 bootstrap 會從空的本機 state 開始，試圖重建所有東西。
2. [Actions variables](https://github.com/MiskaWu/aws-infra/settings/variables/actions) 新增兩個變數。ARN 不是機密，放 Variables 即可。
   - `AWS_APPLY_ROLE_ARN` = `arn:aws:iam::123456789012:role/github-tofu-apply`
   - `AWS_PLAN_ROLE_ARN` = `arn:aws:iam::123456789012:role/github-tofu-plan`
3. [Branches](https://github.com/MiskaWu/aws-infra/settings/branches) 替 `main` 加保護規則，規定必須透過 PR 合併。能直接推到 `main` 的人，等於拿到帳號 Admin。
4. commit 並 push，或在 Actions 頁面重跑先前失敗的那次 workflow。

### 之後要改 bootstrap

在 CloudShell 用同樣方式取得程式碼（或 `git pull`），然後 `make plan`、`make apply`。state 已經在 S3，不需要再 migrate。

## IAM Identity Center（日常登入）

本機 CLI 和主控台的日常操作都用 Identity Center 登入，不再用 root。設定寫在 `infra/identity-center.tf`：

| 項目 | 內容 |
| --- | --- |
| instance | organization instance `ssoins-0123456789abcdef`，位於 `ap-east-2`（台北），組織 `o-exampleorgid` |
| 使用者 | `miskawu`（you@example.com），屬於 `admins` 群組 |
| 權限組合 | `ReadOnly`（ReadOnlyAccess，工作階段 8 小時）、`Administrator`（AdministratorAccess，4 小時） |
| 指派 | `admins` 群組在本帳號可使用上面兩個權限組合 |

平常用 `ReadOnly`，要修改時才切 `Administrator`。正式的變更還是走 PR 和 CI。

### 一次性：在主控台啟用（root）

Identity Center 的 organization instance 依官方文件只能在主控台啟用（API 的 CreateInstance 只能建 account instance，而 account instance 不能用來登入 AWS 帳號）。這一步會順便建立 AWS Organizations，本帳號成為 management account；組織本身不收費。

1. 用 root 登入，右上角區域切到**亞太地區（台北）**，打開 IAM Identity Center，按「啟用」。
2. 如果有出現 Instance 設定，選**單一區域**。多區域會自動建立 KMS 金鑰，要另外收費。
3. 「Enable multi-account permissions」保持**開啟**。關掉的話不能用它登入 AWS 帳號。
4. 出現「Enable IAM Identity Center with AWS Organizations」頁面時按「啟用」。
5. 到 Settings → Authentication → Standard authentication → Configure，勾選 **Send email OTP** 後儲存。少了這一步，用 OpenTofu 建立的使用者收不到設定密碼的信。
6. （可選）在 Settings 把 AWS access portal 的網址改成好記的名稱。目前的網址是 `https://d-0123456789.awsapps.com/start`，改了之後下面 `~/.aws/config` 的 `sso_start_url` 也要跟著改。

MFA 不用另外設定：新的 instance 預設第一次登入就要註冊 MFA，建議註冊 passkey 或實體安全金鑰。

Identity Center 的區域之後**不能直接更改**，要換只能刪掉重建。台北又是需要手動啟用的區域，所以之後如果在組織裡加新帳號，每個新帳號都要先啟用台北區，才能從 access portal 登入。

### 啟用之後

1. 合併 `infra/identity-center.tf` 的 PR，CI 會建立使用者、群組、權限組合和指派。
2. 打開 access portal 網址，用 `miskawu` 登入。系統會寄驗證信到 you@example.com，設定密碼並註冊 MFA。
3. 本機設定 `~/.aws/config`：

   ```ini
   [sso-session miskawu]
   sso_start_url = https://d-0123456789.awsapps.com/start
   sso_region = ap-east-2
   sso_registration_scopes = sso:account:access

   [profile readonly]
   sso_session = miskawu
   sso_account_id = 123456789012
   sso_role_name = ReadOnly
   region = ap-east-2

   [profile admin]
   sso_session = miskawu
   sso_account_id = 123456789012
   sso_role_name = Administrator
   region = ap-east-2
   ```

4. 登入並確認：

   ```sh
   aws sso login --sso-session miskawu
   aws sts get-caller-identity --profile readonly
   ```

之後 root 只留給必須由 root 做的少數操作。

## 日常流程

1. 在分支修改 `infra/`，開 PR。workflow 用 plan 角色跑 `fmt`、`validate`、`plan`。
2. 看過 plan 後合併到 `main`。workflow 用 apply 角色跑 `plan` 再 `apply`。

`bootstrap/` 的變更不會觸發 CI，要改就照「之後要改 bootstrap」手動套用。

## 注意事項

- **apply job 不能加 `environment:`。** 加了之後 `sub` 會變成 `...:environment:NAME`，信任政策不會符合。想要部署前人工核准，要連信任條件一起改成比對 environment。
- **workflow 檔改名或搬家**，要同步改 `workflow_file` 變數並重新套用 bootstrap，否則 apply 角色會拒絕。
- **apply 出現 `Not authorized to perform sts:AssumeRoleWithWebIdentity`** 時，在 workflow 裡暫時加一步印出 token 的 claims，對照 `sub`、`repository_id`、`job_workflow_ref` 哪一個不符。如果 token 根本沒有 `job_workflow_ref`，把 `pin_workflow_file` 設成 `false` 重新套用 bootstrap。
- **plan 角色看得到帳號裡所有可讀的東西**，包含 S3 物件內容。它只接受 `pull_request` 事件。如果 repo 是私有的，不要開啟「Send write tokens to workflows from fork pull requests」，否則 fork 的 PR 也可能拿到 OIDC token。
- **state bucket 設了 `prevent_destroy`**，誤下 `tofu destroy` 會被擋下。
- **費用**：OIDC 提供者和 IAM 角色不收費；state 檔只有幾 KB，S3 月費趨近 0。
- **出現 `Invalid AWS Region: ap-east-2`** 表示 OpenTofu 或 provider 版本太舊、不認得台北區。照「工具版本」升級 `.opentofu-version` 或重跑 `make lock`。台北區在 2025 年 6 月開放，之後發布的版本都應該認得。
- **root 進不了這兩個角色**（root 不能切換角色）。本機要直接操作 AWS 時，用「IAM Identity Center」的身分登入。
