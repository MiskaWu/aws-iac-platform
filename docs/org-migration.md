# 搬到組織 sinshotgames（2026-10）

私人 repo 從個人帳號 `MiskaWu` 移轉到組織 [`sinshotgames`](https://github.com/sinshotgames)（GitHub Free for organizations，
組織 ID `344725661`；`MiskaWu` 的 ID 是 `37805889`）。

## 為什麼

2026-10-19 個人帳號的 Actions 免費分鐘數用完、預算是 0，所有私人 repo 的 CI 都不開跑。決定 CI 改跑使用者 WSL 上的
自架 runner（dev-env-ansible 的 `gha-runner` 項目）。**個人帳號的 runner 只能綁單一 repo**，每加一個專案就要再註冊一次；
組織層級的 runner 註冊一次，之後新開、搬進來的私人 repo 都能直接用（使用者：「避免我後續加專案進來都要重複做」）。
組織另外有自己一份免費分鐘數，搬過去的 repo 在改用自架 runner 之前，CI 用雲端的也跑得起來。

## 要動的信任條件

AWS 這邊每個「GitHub Actions 換權限」的角色都綁著擁有者名稱：`sub`（`repo:OWNER/REPO…` 與新格式
`repo:OWNER@OWNER_ID/REPO@REPO_ID…`）與 `job_workflow_ref`（`OWNER/REPO/…`）。`repository_id` 移轉後不變。

| 角色 | 定義在 | 怎麼套用 |
| --- | --- | --- |
| `github-tofu-apply`、`github-tofu-plan`（aws-infra 自己的 CI） | `bootstrap/` | 手動：CloudShell `make plan`、`make apply` |
| `github-ecr-push-<專案>`（各專案 CI 推映像） | `infra/registry.tf` | aws-infra 的 CI（PR plan、main apply） |
| edge-caddy 推映像 | `infra/edge-caddy.tf` | 同上 |

做法：擁有者從一個變成一份清單，**搬家期間新舊兩個都信任** —— 先套用、再移轉 repo、最後拿掉舊的。
移轉的那一刻兩邊都扮演得到，哪個專案的 CI 都不會斷。

## 步驟

- [ ] **1. bootstrap 同時信任兩個擁有者**（分支 `migrate-org-bootstrap`）
  - `bootstrap/variables.tf`：`github_owner`／`github_owner_id` → `github_owners`（清單）。
  - 預期的 plan：`github-tofu-apply`、`github-tofu-plan` 兩個角色 **in-place 更新**（信任政策多 sinshotgames 的兩種 sub
    與 job_workflow_ref、description），沒有新增或刪除。原本 MiskaWu 的條件一字不差地留著。
  - 套用：CloudShell（東京）`git fetch && git checkout migrate-org-bootstrap && make plan && make apply`，再把 PR 合併。
- [ ] **2. 移轉 aws-infra** 到 sinshotgames（repo 的 Settings → Danger Zone → Transfer）。
  移轉後確認：Actions variables（`AWS_APPLY_ROLE_ARN`／`AWS_PLAN_ROLE_ARN`）、main 的保護規則、CloudShell 的 deploy key 都跟著過去。
- [ ] **3. infra 同時信任兩個擁有者**（`infra/variables.tf` 的 `github_owner` 同樣改成清單）：PR → plan → 合併 → apply。
  這是 aws-infra 搬進組織之後第一次跑 CI，順便確認組織的雲端分鐘數能用。
- [ ] **4. 逐一移轉其他私人 repo**：quarter-master、ouin-fx、sinshot、vroop、hyaku-monogatari。
  每個移轉完：CI 推得了映像（main 上推一次或重跑），有正式站的跑一次部署確認。
- [ ] **5. 組織層級的自架 runner**：`gha-runner` 支援註冊到組織，從組織的 Settings → Actions → Runners 拿一次註冊碼；
  各 repo 的 workflow 改 `runs-on: [self-hosted, linux, x64]`（quarter-master 的做法見它的 docs/decisions/0018）。
- [ ] **6. 收尾**：bootstrap 與 infra 拿掉 `MiskaWu`（各套用一次）；各專案文件、腳本裡寫死的 `MiskaWu/…` 改成 `sinshotgames/…`。

公開 repo（braid、canopy）不在這次的範圍：公開 repo 用雲端 runner 本來就免費，組織 runner 預設也不給公開 repo 用。
