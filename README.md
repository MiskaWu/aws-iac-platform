# AWS IaC（OpenTofu）

帳號 123456789012 的基礎設施程式碼。所有資源由 GitHub Actions 透過 OIDC 部署，帳號裡不存放任何長期存取金鑰。

```
bootstrap/   一次性：GitHub OIDC 提供者、兩個部署角色、state bucket。手動套用，CI 不碰。
infra/       之後所有資源都寫在這裡，由 GitHub Actions 部署。
Makefile     在 CloudShell 套用 bootstrap 用：make plan / apply / migrate。
.github/workflows/opentofu.yml   PR 跑 plan，main 跑 apply。
```

## bootstrap 會建立什麼

| 資源 | 名稱 | 誰能用 | 權限 |
| --- | --- | --- | --- |
| OIDC 身分提供者 | token.actions.githubusercontent.com | — | 讓 AWS 信任 GitHub Actions 發的 token |
| IAM 角色 | `github-tofu-apply` | 指定 repo、`main` 分支、`opentofu.yml` 這個 workflow | AdministratorAccess |
| IAM 角色 | `github-tofu-plan` | 指定 repo 的 `pull_request` 事件 | ReadOnlyAccess + 寫入 infra state 鎖檔 |
| S3 bucket | `tofu-state-123456789012-ap-northeast-1` | 上面兩個角色 | 版本控制、加密、封鎖公開、只接受 TLS |

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

剩下一步：產生兩邊的 provider 鎖檔並 commit，讓 CloudShell、PR 的 plan、main 的 apply 都用同一版 provider。

```sh
(cd bootstrap && tofu providers lock -platform=linux_amd64 -platform=darwin_arm64)
(cd infra && tofu providers lock -platform=linux_amd64 -platform=darwin_arm64)
```

沒有鎖檔也能跑，只是每次 `init` 都會抓最新的 6.x provider。

### 2. CloudShell 套用

在 AWS console 用 root 登入，右上角區域切到 `ap-northeast-1`（東京），打開 CloudShell。

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

2. 產生計畫並檢查：

   ```sh
   make plan
   ```

   輸出應該只有 OIDC 提供者、兩個角色及其政策、state bucket 相關資源。安裝程式會用 cosign 或 GnuPG 驗證 OpenTofu 的簽章；如果它說兩者都沒有，先 `sudo dnf install -y gnupg2` 再重跑。

3. 確認無誤後套用，再把 bootstrap 自己的 state 搬進剛建好的 bucket：

   ```sh
   make apply
   make migrate
   make output
   ```

   `make migrate` 會先比對實際的 bucket 名稱和 `backend.tf.example` 是否一致，不一致就停下來。

4. 到 GitHub 把 deploy key 刪掉，並在 CloudShell 執行 `rm -f ~/.ssh/aws-iac ~/.ssh/aws-iac.pub`。

CloudShell 的家目錄只有 1 GB，Makefile 已把 provider 放到 `/tmp`。工作階段重開後 `/tmp` 和 tofu 都會被清掉，但 `make` 會自動重裝、重新 init，不必手動處理。

### 3. 回到本機收尾

1. 把 `bootstrap/backend.tf.example` 改名成 `bootstrap/backend.tf`（`git mv`）。少了它，下次跑 bootstrap 會從空的本機 state 開始，試圖重建所有東西。
2. [Actions variables](https://github.com/MiskaWu/aws-infra/settings/variables/actions) 新增兩個變數。ARN 不是機密，放 Variables 即可。
   - `AWS_APPLY_ROLE_ARN` = `arn:aws:iam::123456789012:role/github-tofu-apply`
   - `AWS_PLAN_ROLE_ARN` = `arn:aws:iam::123456789012:role/github-tofu-plan`
3. [Branches](https://github.com/MiskaWu/aws-infra/settings/branches) 替 `main` 加保護規則，規定必須透過 PR 合併。能直接推到 `main` 的人，等於拿到帳號 Admin。
4. commit 並 push，或在 Actions 頁面重跑先前失敗的那次 workflow。

### 之後要改 bootstrap

在 CloudShell 用同樣方式取得程式碼（或 `git pull`），然後 `make plan`、`make apply`。state 已經在 S3，不需要再 migrate。

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
- **root 進不了這兩個角色**（root 不能切換角色）。本機要直接操作時，另外啟用 IAM Identity Center 建自己的管理員身分。
