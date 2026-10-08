# 共用主機平台

一台 EC2 給多個專案共用（`infra/`）。每個專案只交一個**部署包**（podman 的 Quadlet 單元、站台檔、備份腳本），
主機、80/443 的入口、秘密、備份、映像倉庫都由這裡提供。第一個使用的專案是 ouin-fx（它的 `deploy/README.md`）。

```
網際網路 ── Elastic IP ── EC2 platform-host（t4g.small，Ubuntu 26.04 arm64，rootful podman）
                            │  安全群組：80/tcp、443/tcp、443/udp；沒有 22（登入走 SSM）
                            │
                            ├─ /etc/containers/systemd/          Quadlet 單元（根碟；開機時 systemd 的 generator 讀這裡）
                            │   ├─ container.d/ volume.d/        平台的頂層 drop-in：RequiresMountsFor=/srv、ECR 的登入設定
                            │   ├─ edge/                         edge.network、edge-caddy.container
                            │   └─ <專案>/                       各專案的單元（tenant-deploy 從 /srv/<專案>/quadlet 裝的）
                            │
                            ├─ /srv（獨立的 EBS 資料碟，換主機也留著，每天快照）
                            │   ├─ containers/storage/           podman 的儲存：映像、volume、secret
                            │   ├─ edge/caddy/                   Caddyfile、sites/<專案>.caddy；edge/data 是憑證
                            │   └─ <專案>/                       部署包解開後的正本：quadlet/、site.caddy、backup.sh
                            │
                            └─ podman 網路 edge（172.30.0.0/24，edge-caddy 固定 172.30.0.2，其他容器從 .128 起分配）
                                ├─ edge-caddy ──→ <專案>-<服務>:<埠>
                                └─ 各專案自己的網路（資料庫只在這裡）

ECR：每個專案一個倉庫　Parameter Store：/<專案>/<名稱>　S3：部署包、備份　SSM：PlatformSync、TenantDeploy
```

## 為什麼這樣做

- **podman＋Quadlet（rootful）**：容器交給 systemd 管（開機自動起、重啟、依賴順序、journald），是 podman 官方的做法。
  rootful 的 bridge 網路經過 NAT，IMDS 的跳數限制（1）才擋得住容器拿主機的 IAM 憑證；rootless 的 pasta 擋不住。
- **Ubuntu 26.04**：podman 5.7。Quadlet 的 `Notify=healthy`、頂層 drop-in、子資料夾都要 5.x（24.04 只有 4.9）。
- **主機可以換掉，狀態在 `/srv`**：資料碟是獨立的 EBS，`tofu apply -replace=aws_instance.host` 換一台新主機時，
  資料碟、Elastic IP 留著；新主機的 PlatformSync 會把已經部署過的專案從 `/srv` 裝回來。
- **第一次開機和之後的更新走同一條路**：cloud-init 只掛資料碟、裝套件；其餘的設定都是 `infra/host/platform/` 的檔案，
  OpenTofu 上傳到 S3、State Manager 的 association（`PlatformSync`）在新主機上與檔案改了的時候執行 `install.sh`。
- **不開 SSH**：登入用 SSM Session Manager，部署包經 S3、由 SSM 文件 `TenantDeploy` 叫主機上的 `tenant-deploy`。
  帳號裡沒有長期金鑰（和 bootstrap 同一個原則）。
- **秘密不經過 OpenTofu**：state 存在 S3，plan 角色讀得到。OpenTofu 只授權主機讀 `/<專案>/*`，值由負責人用 CLI 寫進 Parameter Store。

## 新增一個專案

1. `infra/terraform.tfvars` 的 `projects` 加一筆（repo 的數字 ID 用 `gh api repos/OWNER/REPO --jq .id` 查），開 PR、看 plan、合併。
   建好：ECR 倉庫（標籤不可覆寫，`main`、`latest` 例外）、GitHub Actions 推映像的角色 `github-ecr-push-<專案>`、
   主機讀 `/<專案>/*` 秘密與部署包的權限、寫備份的權限，有填 `dns` 的話還有 A 記錄。
2. 秘密：`aws ssm put-parameter --type SecureString --name /<專案>/<名稱> --value "$(openssl rand -base64 32)"`。
3. 專案的 CI 用 `aws-actions/configure-aws-credentials` 扮演 output `ecr_push_role_arns` 裡的角色、`docker/login-action` 登入 ECR 推映像
   （角色只信任 `main` 與 `v*` 標籤、只限 `push_workflow` 這份 workflow）。
4. 照下面的約定做部署包，上傳到 `s3://platform-deploy-<帳號>-<區域>/<專案>/bundle.tar.gz`，再
   `aws ssm send-command --document-name TenantDeploy --parameters project=<專案> --instance-ids <host_instance_id>`。

## 專案的約定

| 項目 | 約定 |
| --- | --- |
| 部署包 | `bundle.tar.gz`：`quadlet/`（單元檔與這個環境的 drop-in）、`site.caddy`（填好網域的站台檔，選配）、`backup.sh`（選配） |
| 命名 | `quadlet/` 底下每個檔案與 drop-in 資料夾都以 `<專案>-` 開頭（或 `<專案>.`）；`ContainerName=`、`NetworkName=`、`VolumeName=` 也是。`tenant-deploy` 會擋不合的部署包 |
| 對外的服務 | `Network=edge.network` 加 `NetworkAlias=<專案>-<服務>`，站台檔用這個別名當上游 |
| 其他服務 | 只在專案自己的網路（`Internal=true` 的 `.network`）。**任何服務都不寫 `PublishPort=`**，對外一律經過 edge-caddy |
| 來源 IP | 只信任 `172.30.0.2/32` 帶來的 `X-Forwarded-For`（取最右邊）。不能信任整段：`edge` 上還有別的專案的容器 |
| 秘密 | Parameter Store `/<專案>/<名稱>` 在每次部署時同步成 podman secret `<專案>_<名稱>`；單元用 `Secret=<專案>_<名稱>,type=env,target=<變數>`（同一個秘密可以給不同容器用不同的變數名） |
| 每個環境不同的值 | 用 drop-in（例如 `<專案>-server.container.d/10-env.conf` 放 `Image=`），基本的單元檔各環境共用 |
| 映像 | `<帳號>.dkr.ecr.<區域>.amazonaws.com/<專案>:<標籤>`，至少含 `linux/arm64`；不用 `podman login`。主機上已經有的映像不重拉（部署用的標籤不可覆寫） |
| 開機自動起 | `[Install] WantedBy=default.target` |
| 資料碟依賴 | 不用自己寫：平台的頂層 drop-in 會替每個 `.container`、`.volume` 加 `RequiresMountsFor=/srv` |
| 備份 | 每天 04:17（台北）以 root 執行 `/srv/<專案>/backup.sh`，stdout 寫到暫存檔、整份跑完才上傳成 `s3://platform-backups-…/<專案>/<UTC 時間>.dump`（留 35 天）。主機對備份 bucket 只能寫 |
| 日誌 | journald：`journalctl -u <專案>-<服務>` |

`tenant-deploy` 的順序：在暫存區驗證整包（檔名、沒有符號連結、站台檔放進 Caddy 驗證整份設定）→ 寫進 `/srv/<專案>/` →
同步秘密 → 拉映像 → 換單元、重啟 → 確認服務都是 active → 放上站台檔、reload Caddy。驗證不過就什麼都不動；
服務沒起來時站台檔不會更新，但服務已經換成新的了（不會自動退回，用上一包再部署一次）。

## 日常操作

- **登入**：`aws ssm start-session --target <host_instance_id>`（本機要裝 session-manager-plugin），然後 `sudo -i`。
  SSM 的環境沒有 `/snap/bin`：用 `aws` 之前先 `export PATH="$PATH:/snap/bin"`。
- **改平台**（`infra/host/platform/` 底下任何檔案）：開 PR、合併。OpenTofu 上傳新檔案，association 的 `revision` 變了就重跑，
  `install.sh` 只換有變的檔案：edge 的單元或 podman 設定變了才重啟 edge-caddy，只有 Caddyfile 變了就 reload。
- **換主機**（換 AMI、cloud-init 改了、主機壞了或失聯）：`infra/terraform.tfvars` 的 `host_generation` 加一，開 PR、看 plan
  （應該是主機與它的掛載、Elastic IP 的關聯被替換，資料碟、Elastic IP 不動）、合併。主機沒有開防誤刪：
  它本來就可以換掉，不能刪的資料碟與 Elastic IP 有 `prevent_destroy`。
- **流量可能突然變大**（例如在社群發文）：`host_cpu_credits = "unlimited"`，CPU 用完額度也不降速，長時間超過基準的部分另外計費；平常改回 `standard`。改這個不會換主機。
- **cloud-init 改了**：只對新主機有效（`user_data` 在 `ignore_changes` 裡），要套用就換主機。
- **不要在主機上裝 Docker**：它一啟動就把 iptables 的 FORWARD 設成 DROP，podman 容器進出的封包全被丟掉。
  主機的 apt 設定成不裝推薦套件（`/etc/apt/apt.conf.d/90platform-no-recommends`），`install.sh` 檢查到 Docker 會停下來。
  不要用 `apt-get autoremove` 清套件：這台主機的 SSM agent 是 snap，連帶拆掉 snapd 就失聯了（下面的事故紀錄）。

## 本機演練：主機模擬器

`tests/host-sim/run.sh` 在本機起一台模擬主機：rootless podman 起一個跑 systemd 的 Ubuntu 26.04 容器，
裡面以 root 跑 podman（和正式主機一樣是 rootful 的 Quadlet），執行同一份 `infra/host/platform/`。`aws` 指令換成 `fake-aws`，
S3 與 Parameter Store 是本機的資料夾。平台的改動與各專案的部署包都先在這裡跑一次（指令見檔案開頭）。

和正式環境的差別：沒有 ECR、IAM、IMDS；沒有經過 cloud-init（`/srv` 是掛進來的資料夾）；防火牆用 iptables
（WSL 的核心沒有 `nft_fib_inet`，正式主機照預設用 nftables）。**套件清單只有一份**（`infra/host/packages.txt`，
cloud-init 與模擬器都讀它），apt 的設定也一樣不裝推薦套件，所以正式主機少了或多了什麼，模擬器會先看到
（`aardvark-dns` 就是這樣抓到的：它只是 podman 的推薦套件，沒有它容器之間不能用名稱互找）。
模擬器預設用 28080／28443，被占用時用 `HOST_SIM_HTTP`、`HOST_SIM_HTTPS` 換。

2026-10-08 用 ouin-fx 的部署包驗過：部署、SSE 經過 edge-caddy、資料庫不在 `edge` 上、每日備份、換主機後專案自己回來
（資料與市場種子都在）、壞的站台檔與不合約定的檔名整包不生效。

## 第一次套用之後要確認的

模擬器測不到的部分：

- [ ] `aws ssm start-session --target <host_instance_id>` 登得進去；安全群組沒有 22。
- [ ] `PlatformSync` 的 association 是 Success（`aws ssm describe-association-executions --association-id …`），主機上 `systemctl is-active edge-caddy` 是 active。
- [ ] `podman info --format '{{.Store.GraphRoot}}'` 是 `/srv/containers/storage`；`lsattr -d /srv`（卸載時）有 `i`。
- [ ] 主機上 `podman pull <帳號>.dkr.ecr.ap-east-2.amazonaws.com/<專案>:<標籤>` 不用 `podman login` 就成功（`REGISTRY_AUTH_FILE=/etc/containers/platform-auth.json`）。
- [ ] 容器拿不到 IMDS：`podman run --rm docker.io/curlimages/curl -sS -m 3 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'` 失敗。
- [ ] 主機上 `aws s3 rm s3://platform-backups-…/<專案>/<某個備份>` 被拒。
- [ ] ECR 的生命週期規則：推過幾次之後 `aws ecr start-lifecycle-policy-preview --repository-name <專案>` 看會清掉什麼，manifest list 引用的子映像不應該在裡面。
- [ ] 費用（台北）：t4g.small 約 US$14／月、EBS 30 GB 約 US$3、公開 IPv4 約 US$3.6、快照、ECR、S3 約 US$1–2，合計約 US$22。

## 事故紀錄

### 2026-10-08：Docker 讓容器網路失效，移除時主機失聯

- **症狀**：第一次部署 ouin-fx 之後，外面連 80、443 逾時，edge-caddy 連不到 Let's Encrypt。
- **原因**：cloud-init 的 `packages` 會連推薦套件一起裝，`amazon-ecr-credential-helper` 推薦 `docker.io`，
  Docker 一啟動就把 iptables 的 FORWARD 設成 DROP。模擬器不裝推薦套件，所以沒有重現——兩邊的套件策略不一樣。
- **處理時又出錯**：用 `apt-get autoremove` 加 `APT::AutoRemove::RecommendsImportant=false` 清 Docker 帶進來的套件，
  這個選項會移除所有「只因為被推薦才裝」的套件，連 snapd 一起拆掉，snap 裝的 SSM agent 停了，主機失聯（沒有 SSH）。
- **修正**：套件清單改成一份（`packages.txt`）、正式主機與模擬器都不裝推薦套件；`install.sh` 檢查到 Docker 就停下來、
  不自動移除；主機改成用 `host_generation` 走 PR 換掉，失聯的主機直接換一台（資料在 `/srv`，換主機不會掉）。

