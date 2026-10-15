#!/bin/bash
# 套用主機平台的設定。SSM 的 PlatformSync 每次都執行它（新主機、平台檔案改了），所以必須可以重跑。
# 檔案來源 /usr/local/lib/platform/ = s3://<部署 bucket>/_platform/ = infra/host/platform/（加上 OpenTofu 產生的 platform.env）。
set -euo pipefail
export HOME=/root PATH="$PATH:/snap/bin" REGISTRY_AUTH_FILE=/etc/containers/platform-auth.json

src=/usr/local/lib/platform
# shellcheck source=/dev/null
. "$src/platform.env"

log() { echo "install.sh: $*"; }
die() {
  echo "install.sh: $*" >&2
  exit 1
}

mountpoint -q /srv || die "/srv 沒有掛上，不套用（cloud-init 的 mount-data 失敗了？）"

# 主機上不能有 Docker：它一啟動就把 iptables 的 FORWARD 設成 DROP，podman 容器進出的封包全被丟掉。
# 只檢查、不自動移除（2026-10-08 自動移除時連帶拆掉了 snapd 與 SSM agent）：要人看過再處理，或直接換主機。
if dpkg-query -W -f='${db:Status-Abbrev}' docker.io docker-ce 2>/dev/null | grep -q '^ii'; then
  die "主機上裝了 Docker（docker.io／docker-ce），會讓 podman 的容器網路失效。不要在這台主機上裝 Docker；已經裝了就換主機（docs/host-platform.md）"
fi

changed=() # 內容有變的目的地
put() {    # put <來源> <目的地> <權限>
  if ! cmp -s "$1" "$2"; then
    install -D -m "$3" "$1" "$2"
    changed+=("$2")
  fi
}
was_changed() { # was_changed <前綴>…：有沒有任何變更的檔案以這些前綴開頭
  local c prefix
  for c in "${changed[@]}"; do
    for prefix in "$@"; do [[ "$c" == "$prefix"* ]] && return 0; done
  done
  return 1
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------- 日誌保留（30 天，docs/host-platform.md「日誌保留」）----------
put "$src/journald.conf" /etc/systemd/journald.conf.d/10-platform.conf 644
if was_changed /etc/systemd/journald.conf.d/; then
  log "重啟 systemd-journald（保留天數）"
  systemctl restart systemd-journald.service
fi

# ---------- podman ----------
put "$src/storage.conf" /etc/containers/storage.conf 644
printf '{\n  "credHelpers": {\n    "%s": "ecr-login"\n  }\n}\n' "$REGISTRY" >"$tmp/auth.json"
put "$tmp/auth.json" /etc/containers/platform-auth.json 600
put "$src/quadlet/container.d/10-platform.conf" /etc/containers/systemd/container.d/10-platform.conf 644
put "$src/quadlet/volume.d/10-platform.conf" /etc/containers/systemd/volume.d/10-platform.conf 644

# ---------- 共用入口 ----------
install -d -m 755 /srv/edge /srv/edge/caddy /srv/edge/caddy/sites /srv/edge/data /srv/edge/config

# 映像：edge-caddy/tag 有標籤就用 ECR 上自建的（多了 caddy-dns/cloudflare），空的就用官方的同一版。
# 單元檔的 Image=@IMAGE@ 在這裡填；DNS-01 的 token 另外放 drop-in（20-cloudflare.conf）
caddy_version="$(sed -n 's/^ARG CADDY_VERSION=//p' "$src/edge-caddy/Containerfile")"
[[ -n "$caddy_version" ]] || die "edge-caddy/Containerfile 讀不到 CADDY_VERSION"
edge_tag="$(sed '/^#/d' "$src/edge-caddy/tag" | tr -d '[:space:]')"
if [[ -n "$edge_tag" ]]; then
  edge_image="$REGISTRY/edge-caddy:$edge_tag"
else
  edge_image="docker.io/library/caddy:$caddy_version"
fi

# Cloudflare 的 API token（DNS-01，docs/host-platform.md「憑證」）：Parameter Store /platform/CLOUDFLARE_API_TOKEN
# → podman secret platform_CLOUDFLARE_API_TOKEN（值放在只有 root 讀得到的暫存檔，不進命令列）。只存雜湊，變了就重啟 edge-caddy
token="$tmp/cloudflare-token"
aws ssm get-parameters-by-path --region "$REGION" --path /platform/ --with-decryption --output json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["Parameters"]:
    if p["Name"] == "/platform/CLOUDFLARE_API_TOKEN":
        sys.stdout.write(p["Value"].strip())
' >"$token"
if [[ -s "$token" ]]; then
  podman secret create --replace platform_CLOUDFLARE_API_TOKEN "$token" >/dev/null
  sha256sum <"$token" | cut -d' ' -f1 >"$tmp/edge-secrets.sha256"
else
  podman secret rm platform_CLOUDFLARE_API_TOKEN >/dev/null 2>&1 || true
  : >"$tmp/edge-secrets.sha256"
fi
# DNS-01 要自建的映像（官方的沒有 cloudflare 模組，設定會載入失敗）和 token 都在；少一樣就照舊用 HTTP-01／TLS-ALPN-01
dns01=false
if [[ -n "$edge_tag" && -s "$token" ]]; then dns01=true; fi

cloudflare_ips="$(sed '/^#/d' "$src/cloudflare-ips" | tr '\n' ' ')"
[[ -n "${cloudflare_ips// /}" ]] || die "cloudflare-ips 是空的"
{
  echo "# infra/host/platform/install.sh 產生；各專案的站台檔放在 sites/（tenant-deploy 放的）"
  echo "{"
  if [[ -n "${ACME_EMAIL:-}" ]]; then printf '\temail %s\n' "$ACME_EMAIL"; fi
  if $dns01; then printf '\tacme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}\n'; fi
  # 真實 IP（docs/host-platform.md「Cloudflare 代理」）：只對 Cloudflare 的網段採信 CF-Connecting-IP。
  # {client_ip}（站台檔的 header_up X-Real-IP）與存取紀錄的 client_ip 都照這條；灰色雲時就是連進來的對端
  printf '\tservers {\n\t\ttrusted_proxies static %s\n\t\tclient_ip_headers CF-Connecting-IP\n\t}\n' "${cloudflare_ips% }"
  echo "}"
  echo
  echo "import /etc/caddy/sites/*.caddy"
} >"$tmp/Caddyfile"
sed "s|@IMAGE@|$edge_image|" "$src/quadlet/edge/edge-caddy.container" >"$tmp/edge-caddy.container"
printf '[Container]\nSecret=platform_CLOUDFLARE_API_TOKEN,type=env,target=CLOUDFLARE_API_TOKEN\n' >"$tmp/20-cloudflare.conf"

# 換上去之前先在旁邊驗過：拉不到映像、新的設定在新的映像上載入不了，就停在這裡，正在跑的 edge-caddy 不動
podman image exists "$edge_image" || podman pull --quiet "$edge_image" >/dev/null || die "拉不到 $edge_image，edge-caddy 沒有動"
rm -rf "$tmp/edge-check"
cp -r /srv/edge/caddy "$tmp/edge-check"
cp "$tmp/Caddyfile" "$tmp/edge-check/Caddyfile"
check=(podman run --rm --network none -v "$tmp/edge-check:/etc/caddy:ro")
if $dns01; then check+=(--secret "platform_CLOUDFLARE_API_TOKEN,type=env,target=CLOUDFLARE_API_TOKEN"); fi
if ! "${check[@]}" "$edge_image" caddy validate --config /etc/caddy/Caddyfile >"$tmp/edge-check.log" 2>&1; then
  tail -5 "$tmp/edge-check.log" >&2
  die "新的 Caddyfile 在 $edge_image 上驗證不過，edge-caddy 沒有動"
fi

# 從來沒有 token 的主機不寫雜湊檔（第一次寫空的也算「變了」，會白白重啟一次）
if [[ -s "$token" || -e /srv/edge/.secrets.sha256 ]]; then put "$tmp/edge-secrets.sha256" /srv/edge/.secrets.sha256 600; fi
put "$tmp/Caddyfile" /srv/edge/caddy/Caddyfile 644
put "$src/quadlet/edge/edge.network" /etc/containers/systemd/edge/edge.network 644
put "$tmp/edge-caddy.container" /etc/containers/systemd/edge/edge-caddy.container 644
dropin=/etc/containers/systemd/edge/edge-caddy.container.d/20-cloudflare.conf
if $dns01; then
  put "$tmp/20-cloudflare.conf" "$dropin" 644
elif [[ -e "$dropin" ]]; then
  rm -f "$dropin"
  changed+=("$dropin")
fi

# ---------- 給各專案用的指令 ----------
put "$src/tenant-deploy" /usr/local/sbin/tenant-deploy 755
put "$src/tenant-backup" /usr/local/sbin/tenant-backup 755
put "$src/systemd/tenant-backup.service" /etc/systemd/system/tenant-backup.service 644
put "$src/systemd/tenant-backup.timer" /etc/systemd/system/tenant-backup.timer 644
put "$src/tenant-hourly" /usr/local/sbin/tenant-hourly 755
put "$src/systemd/tenant-hourly.service" /etc/systemd/system/tenant-hourly.service 644
put "$src/systemd/tenant-hourly.timer" /etc/systemd/system/tenant-hourly.timer 644
put "$src/tenant-credentials" /usr/local/sbin/tenant-credentials 755
put "$src/systemd/tenant-credentials.service" /etc/systemd/system/tenant-credentials.service 644
put "$src/systemd/tenant-credentials.timer" /etc/systemd/system/tenant-credentials.timer 644

systemctl daemon-reload
systemctl enable --now tenant-backup.timer
systemctl enable --now tenant-hourly.timer
systemctl enable --now tenant-credentials.timer
# 寄信的臨時憑證先換一次（開了 ses 的專案、或剛關掉的要刪檔）：失敗不擋平台，timer 15 分鐘後再試
/usr/local/sbin/tenant-credentials || log "tenant-credentials 有專案失敗（journalctl -u tenant-credentials 看之後的重試）"

# edge：單元、映像、token 或 podman 的設定改了就重啟（主機上所有站台斷幾秒）；只有 Caddyfile 改了就 reload（不斷線）
if was_changed /etc/containers/systemd/ /etc/containers/storage.conf /etc/containers/platform-auth.json /srv/edge/.secrets.sha256; then
  log "重啟 edge-caddy"
  systemctl restart edge-caddy.service
elif was_changed /srv/edge/caddy/Caddyfile && systemctl is-active --quiet edge-caddy.service; then
  log "reload edge-caddy"
  podman exec edge-caddy caddy reload --config /etc/caddy/Caddyfile
fi
systemctl is-active --quiet edge-caddy.service || systemctl start edge-caddy.service

# 換了新主機：把 /srv 裡已經部署過、但這台主機還沒裝的專案裝回來
rc=0
for dir in /srv/*/quadlet; do
  [[ -d "$dir" ]] || continue
  p="$(basename "$(dirname "$dir")")"
  [[ -d "/etc/containers/systemd/$p" ]] && continue
  log "裝回 $p"
  /usr/local/sbin/tenant-deploy --local "$p" || rc=1
done

log "完成（變更 ${#changed[@]} 個檔案）"
exit "$rc"
