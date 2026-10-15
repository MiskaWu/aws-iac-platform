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
                            │   └─ <專案>/                       部署包解開後的正本：quadlet/、site.caddy、backup.sh、hourly.sh
                            │
                            └─ podman 網路 edge（172.30.0.0/24，edge-caddy 固定 172.30.0.2，其他容器從 .128 起分配）
                                ├─ edge-caddy ──→ <專案>-<服務>:<埠>
                                └─ 各專案自己的網路（資料庫只在這裡）

ECR：每個專案一個倉庫、edge-caddy　Parameter Store：/<專案>/<名稱>、/platform/<名稱>　S3：部署包、備份　SSM：PlatformSync、TenantDeploy
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
| 部署包 | `bundle.tar.gz`：`quadlet/`（單元檔與這個環境的 drop-in）、`site.caddy`（填好網域的站台檔，選配）、`backup.sh`（選配）、`hourly.sh`（選配） |
| 命名 | `quadlet/` 底下每個檔案與 drop-in 資料夾都以 `<專案>-` 開頭（或 `<專案>.`）；`ContainerName=`、`NetworkName=`、`VolumeName=` 也是。`tenant-deploy` 會擋不合的部署包 |
| 對外的服務 | `Network=edge.network` 加 `NetworkAlias=<專案>-<服務>`，站台檔用這個別名當上游 |
| 其他服務 | 只在專案自己的網路（`Internal=true` 的 `.network`）。**任何服務都不寫 `PublishPort=`**，對外一律經過 edge-caddy |
| 來源 IP | 站台檔的轉發加 `header_up X-Real-IP {client_ip}`（edge-caddy 算好的真實 IP，灰色雲、橘色雲都對，見「Cloudflare 代理」）；應用只在對端是 `172.30.0.2/32` 時讀它，沒帶才退回 `X-Forwarded-For` 最右邊（換版那幾秒舊站台檔轉來的請求）。不能信任整段：`edge` 上還有別的專案的容器 |
| 秘密 | Parameter Store `/<專案>/<名稱>` 在每次部署時同步成 podman secret `<專案>_<名稱>`；單元用 `Secret=<專案>_<名稱>,type=env,target=<變數>`（同一個秘密可以給不同容器用不同的變數名） |
| 每個環境不同的值 | 用 drop-in（例如 `<專案>-server.container.d/10-env.conf` 放 `Image=`），基本的單元檔各環境共用 |
| 映像 | `<帳號>.dkr.ecr.<區域>.amazonaws.com/<專案>:<標籤>`，至少含 `linux/arm64`；不用 `podman login`。主機上已經有的映像不重拉（部署用的標籤不可覆寫） |
| 開機自動起 | `[Install] WantedBy=default.target` |
| 換版不斷線（選配） | 對外的服務寫成**範本單元** `<專案>-<服務>@.container`（`ContainerName=<專案>-<服務>-%i`、`NetworkAlias=<專案>-<服務>-%i`，要有 `HealthCmd` 與 `Notify=healthy`）。平台平常只跑一份（`@a` 或 `@b`），換版時在另一個位子起新版、等它健康才關舊的。站台檔兩個位子都列、加健康檢查；服務收到 SIGTERM 要先讓健康檢查失敗幾秒（排水）再關。見下面「範本單元」 |
| 資料碟依賴 | 不用自己寫：平台的頂層 drop-in 會替每個 `.container`、`.volume` 加 `RequiresMountsFor=/srv` |
| 備份 | 每天 04:17（台北）以 root 執行 `/srv/<專案>/backup.sh`，stdout 寫到暫存檔、整份跑完才上傳成 `s3://platform-backups-…/<專案>/<UTC 時間>.dump`（留 35 天）。主機對備份 bucket 只能寫 |
| 寄信（選配） | `projects` 填 `ses = { from_domain = "<網域>" }`：平台每 15 分鐘把只能用 `*@<網域>` 寄信的臨時憑證寫成 `/srv/<專案>/aws/credentials.json`（credential_process 格式、1 小時效期、所有人可讀）。要寄信的單元自己 `Volume=/srv/<專案>/aws:/run/aws:ro`，程式在 Expiration 前重讀。見「寄信（SES）」 |
| 每小時的工作 | 每個整點過 2 分以 root 在 `/srv/<專案>/` 裡執行 `hourly.sh`（例如發報告），`AWS_REGION` 已經設好，讀得到 Parameter Store 的 `/<專案>/…`（主機角色本來就能讀，部署時同步秘密用的同一個權限）；最多跑 5 分鐘、錯過的不補跑。日誌：`journalctl -u tenant-hourly` |
| 日誌 | journald：`journalctl -u <專案>-<服務>`（範本單元：`journalctl -u '<專案>-<服務>@*'`）。整台主機保留 **30 天**（見「日誌保留」），IP 不要另外寫到別的地方，隱私說明才寫得出天數 |

`tenant-deploy` 的順序：在暫存區驗證整包（檔名、沒有符號連結、站台檔放進 Caddy 驗證整份設定）→ 寫進 `/srv/<專案>/` →
同步秘密 → 拉映像 → 換單元、重啟有變的一般單元 → 範本單元換位子 → 確認服務都是 active → 放上站台檔、reload Caddy →
停掉這次不再有的服務（新的起來、站台換好之後才停，換了單元名稱也不斷線）。

**只重啟需要的**：一般單元只有**它自己的**單元檔或 drop-in 變了、秘密變了（比對雜湊，存在 `/srv/<專案>/.secrets.sha256`，不存值）、
或沒在跑才重啟——只換了伺服器的映像時，資料庫不會跟著重啟。`.network`、`.volume` 這類檔案變了、或秘密變了，就全部重啟（那一次會斷線）。
同一版重新部署（只換站台檔、`backup.sh`、`hourly.sh`）什麼都不重啟。驗證不過就什麼都不動；
一般單元沒起來時站台檔不會更新，但服務已經換成新的了（不會自動退回，用上一包再部署一次）。

### 範本單元：換版不斷線

範本單元 `<專案>-<服務>@.container` 平常只跑一個實例（位子 `a` 或 `b`，記在 `/srv/<專案>/.slot-<專案>-<服務>`）。
範本或它的 drop-in（`<專案>-<服務>@.container.d/`）變了、秘密變了、或現在的位子沒在跑時，`tenant-deploy`：

1. 在另一個位子建實例檔（`/etc/containers/systemd/<專案>/<專案>-<服務>@<位子>.container`，符號連結到範本）、`systemctl start`。
   `Notify=healthy` 讓它健康了才回來（`TimeoutStartSec` 內）。
2. 起不來：把新的停掉、刪掉實例檔，**舊的照常服務**，這次部署失敗（站台檔不更新）。
3. 起來了：`systemctl stop` 舊的位子（服務自己先排水再關）、刪掉它的實例檔、記下新的位子。

開機時只有現在的位子有實例檔，`[Install]` 只套在它身上，所以只會起一份。站台檔兩個位子都列：

```caddy
reverse_proxy {
	to <專案>-<服務>-a:8080 <專案>-<服務>-b:8080
	lb_policy first
	lb_try_duration 10s
	health_uri /readyz
	health_interval 1s
}
```

沒在跑、還沒好、正在排水的那份健康檢查（`/readyz` 這類「要不要送流量」的端點，不要用外面監控用的那支）不過，edge-caddy 就不送；送不出去（連不上）在 `lb_try_duration` 內改送另一份。
服務收到 SIGTERM 要先讓健康檢查失敗、照常服務幾秒（比 `health_interval` 長），再關；`StopTimeout` 要涵蓋這段時間。
換位子時新舊兩份會同時跑幾秒：資料庫的 migration 只能「加」、兩份都要能處理同一筆資料。ouin-fx 的做法見它的
[0018](https://github.com/MiskaWu/ouin-fx/blob/main/docs/decisions/0018-zero-downtime-deploy.md)。

## 網域

對外的網域是 **`sinshot.com`**（社團 SinShot，2026-10-15 起）：`*.sinshot.com` 一筆萬用字元 A 記錄指到主機的 Elastic IP（灰色雲），
規則和下面的 miskawu.com 一樣，負責人在 Cloudflare 加。`miskawu.com` 留著當搬家前的舊網址（各專案的交接期，例如 ouin-fx 的
0021），一直續約、舊連結不會壞。新的專案用 `<專案>.sinshot.com`。

`miskawu.com` 的註冊商與 DNS 都在 **Cloudflare**（2026-10-12 定，比較過的方案：Cloudflare 全留＋萬用字元、委派子網域給 Route 53、
寫成程式碼、整個搬到 AWS）。理由：在 Cloudflare 註冊的網域只能用 Cloudflare 的 DNS；whorl 等站用 Cloudflare Workers 的自訂網域，
要求網域在 Cloudflare；註冊商和 DNS 在同一個帳號，要守的帳號只有一個。

- **萬用字元**：`*.miskawu.com` 一筆 A 記錄指到主機的 Elastic IP（`host_public_ip`），**灰色雲**（DNS only：限流要看玩家真正的 IP）。
  沒有自己記錄的子網域都由它回答，所以新的專案只要在部署包放站台檔就上線（Caddy 自己申請憑證），DNS 一筆都不用加。
  打錯的名字會連到主機，但 edge-caddy 沒有那個站台就不給憑證、不回應。
- **有自己記錄的名字照它自己的**：whorl、rpg、sim-gensokyo 是 Cloudflare 上的站（Workers 加自訂網域時 Cloudflare 自動建記錄、蓋過萬用字元）。
- **安全設定**（Cloudflare 免費方案都有）：帳號兩步驟驗證、DNSSEC、防冒名寄信（`TXT v=spf1 -all`、`_dmarc` 的 `v=DMARC1; p=reject`、
  null MX `0 .`；這個網域不收發信）、網域轉移鎖。限制發憑證的 CAA 還沒加（要加的話允許 `letsencrypt.org`）。
- **主機換 IP**（換掉 Elastic IP 才會，平常換主機會沿用）：改 Cloudflare 上那一筆。真的常換、或要開第二台主機時，
  再把一個子網域（例如 `edge`）委派給 Route 53、萬用字元改成 CNAME 指過去。

## Cloudflare 代理（橘色雲）

負責人 2026-10-15 要求：主機上的網址隨時可以從灰色雲（DNS only）切成橘色雲（Cloudflare 代理），**切換只改 DNS 那一筆記錄的雲朵**，
不改程式、不重新部署；什麼時候切由他決定。交接期新舊網址的雲朵可能不同，所以每一項都要在兩種雲朵下同時成立。

| 項目 | 灰色雲 | 橘色雲 | 由誰做到 |
| --- | --- | --- | --- |
| 真實 IP | 連進來的對端 | Cloudflare 給的 `CF-Connecting-IP` | 平台：`install.sh` 產生的 Caddyfile 全域 `servers { trusted_proxies static <cloudflare-ips> ; client_ip_headers CF-Connecting-IP }`，只對 Cloudflare 的網段採信那個標頭。`{client_ip}` 與存取紀錄的 `client_ip` 都照它 |
| 應用拿到真實 IP | 同左 | 同左 | 專案：站台檔 `header_up X-Real-IP {client_ip}`，應用只在對端是 edge-caddy 時讀（「專案的約定」的來源 IP）。**不要**讀 `X-Forwarded-For` 最右邊當真實 IP：橘色雲時那是 Cloudflare |
| 憑證 | DNS-01 | DNS-01 | 平台：見下面「憑證」。HTTP-01／TLS-ALPN-01 在代理後面申請不保險 |
| 長連線 | 不限 | 約 100 秒沒資料會被切（Cloudflare 的 proxy read timeout，免費方案不能調） | 專案：SSE 這類長連線要有心跳（ouin-fx：行情每 100 毫秒、沒事件時每 15 秒 keep-alive） |
| 快取 | 不經過 | 預設只快取帶靜態副檔名的檔案、照來源的 `Cache-Control`；HTML、API 不快取 | 專案：API、帶 `Set-Cookie` 的回應不要有靜態副檔名、不要給 `public`；圖片這類不變的資源給長的 `max-age`，正好讓 Cloudflare 接住 |
| SSL 模式 | — | **Full (strict)**（Cloudflare 驗主機的憑證；主機的是 Let's Encrypt，有效） | 負責人在 Cloudflare 設定 |

- **Cloudflare 的網段**在 `infra/host/platform/cloudflare-ips`（一行一個，IPv4、IPv6）。`.github/workflows/cloudflare-ips.yml`
  每週一和 https://www.cloudflare.com/ips/ 比對，變了就失敗（GitHub 寄信），照 diff 更新、開 PR（只 reload，不斷線）。
  比較過的：Caddy 的 `trusted_proxies cloudflare` 模組（自己定時抓網段）要多編一個第三方模組進拿著所有私鑰的入口，
  網段幾年才變一次，用每週比對＋PR 換得到可以審查的變更。
- **鎖住主機只收 Cloudflare 的連線**（安全群組 80、443 只開 Cloudflare 的網段）：要等主機上**每一個**網址都切成橘色雲才能做，
  包括交接期的 `*.miskawu.com`；有任何一個還是灰色雲，鎖了它就連不上。到時在 `network.tf` 的安全群組改成 `cloudflare-ips` 的網段
  （同一個檔，用 `file()` 讀），憑證照樣是 DNS-01、不受影響。這次不動。
- 驗收（切之前，拿一個測試用的子網域切成橘色雲）：存取紀錄的 `client_ip` 與應用記到的是自己的 IP、不是 Cloudflare 的；限流只擋
  單一玩家；SSE 撐過 5 分鐘不斷；憑證有效（Full (strict) 不報錯）；分享預覽正常。切回灰色雲再看一次。

## 憑證（DNS-01）

負責人 2026-10-15 定：edge-caddy 改用 DNS-01 申請憑證（在 Cloudflare 的 DNS 加一筆 `_acme-challenge` TXT 記錄證明網域是自己的）。
它不需要連到主機，所以灰色雲、橘色雲、之後鎖住安全群組都申請得到。

- 比較過的：HTTP-01／TLS-ALPN-01（現在的預設）在橘色雲下，TLS-ALPN-01 一定失敗（Cloudflare 終結 TLS），HTTP-01 會碰上
  「Always Use HTTPS」之類的設定，續約不保險；鎖住安全群組之後 Let's Encrypt 連不進來，兩個都失敗。Cloudflare 的 Origin CA 憑證
  只有 Cloudflare 信任，切回灰色雲時瀏覽器直接看到它就是無效的憑證，不符合「切換只改雲朵」。
- **映像**：官方 Caddy 沒有 DNS 供應商的模組，要自己建：`infra/host/platform/edge-caddy/Containerfile`（官方 builder 加
  `caddy-dns/cloudflare`，版本釘死）。`.github/workflows/edge-caddy.yml` 在 main 建好推到 ECR `edge-caddy:sha-<7 碼>`（只有 arm64，
  原生的 arm runner），PR 只建。主機用哪一個寫在 `edge-caddy/tag`：**空的就是官方映像**（沒有 DNS-01）。
  比較過的：在主機上建（t4g.small 的 2 GB 記憶體編 Go 會擠到正在跑的專案；新主機要先編完 edge 才起得來）、第三方建好的映像
  （拿著所有私鑰的入口不用別人建的東西）。
- **token**：負責人自己在 Cloudflare 建一把 API token，權限只給 **Zone → Zone → Read** 與 **Zone → DNS → Edit**，Zone Resources 只選
  **sinshot.com 與 miskawu.com** 兩個 zone（caddy-dns/cloudflare 要 Zone Read 才找得到 zone）。放進 Parameter Store，不經過其他地方：

  ```sh
  aws ssm put-parameter --type SecureString --name /platform/CLOUDFLARE_API_TOKEN --value '<token>'
  ```

  `install.sh` 每次同步成 podman secret `platform_CLOUDFLARE_API_TOKEN`，edge-caddy 以環境變數讀（drop-in `20-cloudflare.conf`），
  Caddyfile 的全域 `acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}`。主機只存雜湊（`/srv/edge/.secrets.sha256`），token 換了就重啟 edge-caddy。
  **自建的映像與 token 兩樣都在才用 DNS-01**，少一樣就照舊（官方映像沒有 cloudflare 模組，設定會載入失敗）。
- **miskawu.com 也一起改 DNS-01**：`acme_dns` 是全域的，主機上所有網址都照它申請；交接期 ouin-fx 的新舊網域在同一個站台，
  分開設定要每個專案在站台檔各寫一份 `tls`、token 散到各專案。所以 token 涵蓋兩個 zone，一套規則。之後 miskawu.com 的網址也能切橘色雲。
- **換上去那一次的影響**：`install.sh` 先把新映像拉好、用新映像把新的 Caddyfile（含所有專案的站台檔）驗過，拉不到或驗不過就停下來、
  正在跑的 edge-caddy 不動；過了才換單元、**重啟 edge-caddy：主機上所有站台（ouin-fx、quarter-master）斷幾秒**，SSE 這類長連線
  會斷一次（瀏覽器自己重連）。憑證在 `/srv/edge/data`，換映像不會重新申請；之後的續約才走 DNS-01。挑非熱門時段合併。
- **退回**：PR 把 `edge-caddy/tag` 改回上一個標籤（ECR 留最近 10 個），或清空回官方映像（`acme_dns` 自動拿掉，憑證續約回到 HTTP-01／
  TLS-ALPN-01；此時所有網址要是灰色雲）。一樣會重啟一次。token 不用刪。
- **順序**（第一次）：
  1. 這個 PR 合併：建 ECR `edge-caddy`、推映像的角色、主機讀 `/platform/*` 的權限；Caddyfile 加上 Cloudflare 的網段（只 reload）。
     `tag` 是空的、沒有 token，所以憑證照舊。
  2. 手動跑一次 `edge-caddy` workflow（`gh workflow run edge-caddy.yml --ref main`；同一次推送觸發的那一輪會在角色建好之前就跑、失敗，不用管它）。
  3. 負責人建 token、寫進 Parameter Store（上面那行）。這一步不會觸發主機，下一次 PlatformSync 才同步。
  4. 非熱門時段，PR 把 `edge-caddy/tag` 改成第 2 步的標籤，合併：PlatformSync 同步 token、換映像、重啟 edge-caddy。
  5. 確認：`podman exec edge-caddy caddy list-modules | grep dns.providers.cloudflare`；`journalctl -u edge-caddy` 下一次申請或續約
     看到 `dns-01`；拿一個新的子網域部署一次，看它申請得到憑證。
- token 被撤銷或過期：申請、續約失敗，已經有的憑證照用到過期（Caddy 在剩三分之一效期時續約，90 天的憑證約有一個月可以處理）。
  `journalctl -u edge-caddy` 會一直報錯；換一把寫進 Parameter Store，再跑一次 PlatformSync（`aws ssm start-associations-once`）。

## 寄信（SES）

負責人 2026-10-15 定（sinshot 通行證的 email 驗證碼，SPEC.md §8.1 甲案）：**帳號裡不放長期金鑰**，SMTP 帳密（IAM 使用者的金鑰）不用；
容器拿不到主機的角色（IMDS 擋著），所以由平台替專案換臨時憑證。

- **AWS 這邊**（`infra/ses.tf`）：`projects` 有填 `ses` 的專案各一個角色 `platform-ses-<專案>`，只信任主機角色，只能
  `ses:SendEmail`、`ses:SendRawEmail`，條件 `ses:FromAddress` 限 `*@<from_domain>`。寄件網域在 **東京**（ap-northeast-1，台北沒有 SES）
  建 Easy DKIM 的 identity。
- **主機這邊**：`tenant-credentials`（`tenant-credentials.timer` 每 15 分鐘；`install.sh`、`tenant-deploy` 也先跑一次）assume 那個角色，
  1 小時效期的憑證寫成 `/srv/<專案>/aws/credentials.json`：

  ```json
  {"Version": 1, "AccessKeyId": "…", "SecretAccessKey": "…", "SessionToken": "…", "Expiration": "2026-10-15T12:00:00Z"}
  ```

  先寫暫存檔再改名（讀的人不會讀到一半）；權限 444，容器裡不一定是 root。專案關掉 `ses` 之後，留下的檔案下一輪刪掉。
  失敗不擋平台與部署：舊的憑證還有 45 分鐘，`journalctl -u tenant-credentials` 看重試。
- **專案這邊**：要寄信的單元 `Volume=/srv/<專案>/aws:/run/aws:ro`，程式讀 `/run/aws/credentials.json`，**在 Expiration 之前（例如前 5 分鐘）
  或檔案修改時間變了就重讀**。SDK 的共用憑證檔大多讀一次就快取、不會自己重讀，不要靠它；容器有 shell 的話可以用 SDK 的
  `credential_process = cat /run/aws/credentials.json`。
- 信任範圍：檔案所有人可讀，但主機上只有 root，別的專案的容器看不到 `/srv/<專案>/`（除非它的單元故意掛別人的資料夾，
  平台信任主機上的專案都是自己的）。
- **負責人要做的**（AWS 與 Cloudflare 的主控台）：
  1. DKIM：`tofu output ses_dkim_records` 的三筆 CNAME 加到 Cloudflare（DNS only）。加好之後 SES 自己驗證，主控台的 identity 變成 Verified 才寄得出去。
     寄件網域的 DMARC 是 `p=reject`、SPF 是 `-all` 也沒關係：SES 預設的 MAIL FROM 在 amazonses.com，DMARC 靠 DKIM 對齊就過。
  2. 沙盒：新帳號的 SES 只能寄給驗證過的地址。正式寄給玩家前，在東京的 SES 主控台申請 production access（說明用途：通行證的驗證碼）。
     核准之前先用驗證過的地址測。

## 日誌保留

主機上所有日誌（edge-caddy 的存取紀錄含 IP 與 User-Agent、各專案的服務、系統）保留 **30 天**，之後自動刪除
（負責人 2026-10-15 定）。設定是 `infra/host/platform/journald.conf`：`MaxRetentionSec=30day`，再加 `MaxFileSec=1day`。
journald 整個檔一起刪、檔裡最新的一筆也超過保留期才刪，預設一個檔最長一個月，不加這行實際會拖到將近 60 天。

- **隱私說明可以寫**：伺服器存取紀錄（含 IP 位址、瀏覽器資訊）保留 30 天後自動刪除。所有專案同一個數字。
- 平台上 IP 只在 journald：資料碟的每日快照只有 `/srv`（journald 在根碟），備份是各專案的資料庫。專案不要把 IP 寫進資料庫或
  `/srv` 底下的檔案，要的話在自己的隱私說明另外寫。
- 切成橘色雲之後，Cloudflare 也會照它自己的政策處理連線資料，隱私說明要另外提。
- 比較過的天數：14 天（較嚴，但兩週後才回報的問題查不到）、90 天（流量報告用不到、說明不好看）。各專案的流量報告最多回頭看 7 天。

## 日常操作

- **登入**：`aws ssm start-session --target <host_instance_id>`（本機要裝 session-manager-plugin），然後 `sudo -i`。
  SSM 的環境沒有 `/snap/bin`：用 `aws` 之前先 `export PATH="$PATH:/snap/bin"`。
- **改平台**（`infra/host/platform/` 底下任何檔案）：開 PR、合併。OpenTofu 上傳新檔案，association 的 `revision` 變了就重跑，
  `install.sh` 只換有變的檔案：edge 的單元、映像、token 或 podman 設定變了才重啟 edge-caddy，只有 Caddyfile 變了就 reload。
- **升級 Caddy**：改 `edge-caddy/Containerfile` 的 `CADDY_VERSION`（和 `caddy-dns/cloudflare` 的版本）→ 合併後 workflow 推新映像 →
  PR 改 `edge-caddy/tag`。`tag` 空的時候用的官方映像也跟著 `CADDY_VERSION`。
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

2026-10-15 驗過 Cloudflare 與 DNS-01（「Cloudflare 代理」「憑證」）：全域設定帶 Cloudflare 的網段、重跑不會白白重啟 edge-caddy；
非 Cloudflare 來的連線帶假的 `CF-Connecting-IP`，存取紀錄的 `client_ip` 照樣是真正的對端；自建映像加 token 時 `acme_dns` 與
drop-in 都在、token 以環境變數進到容器、專案照樣部署；映像拉不到時停下來、正在跑的 edge-caddy 不動；`tag` 清空退回官方映像。
模擬器沒有 ECR，自建的映像要先建好載進去、標成假的倉庫位址：

```sh
podman build -t localhost/edge-caddy:test infra/host/platform/edge-caddy
tests/host-sim/run.sh load localhost/edge-caddy:test
tests/host-sim/run.sh exec podman tag localhost/edge-caddy:test 000000000000.dkr.ecr.ap-east-2.amazonaws.com/edge-caddy:sha-test
printf '%s' '<40 個英數字的假 token>' | tests/host-sim/run.sh secret platform CLOUDFLARE_API_TOKEN
echo sha-test >> infra/host/platform/edge-caddy/tag && tests/host-sim/run.sh sync   # 測完把 tag 改回來
```

`edge-caddy/tag` 有值時（2026-10-15 起正式用 `sha-b618851`），模擬器的 `up` 會停在「拉不到映像」：照上面建好、載入，
標成 `000000000000.dkr.ecr.ap-east-2.amazonaws.com/edge-caddy:<tag 的值>` 再 `sync`。
寄信的臨時憑證：`HOST_SIM_SES_PROJECTS="<專案>" tests/host-sim/run.sh up`（fake-aws 給假的憑證）。2026-10-15 驗過：
憑證檔的格式、容器以 65532 讀得到、timer 有排上、專案關掉 ses 之後刪檔、重跑變更 0 個檔案。

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

