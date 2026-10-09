#!/bin/bash
# 套用主機平台的設定。SSM 的 PlatformSync 每次都執行它（新主機、平台檔案改了），所以必須可以重跑。
# 檔案來源 /usr/local/lib/platform/ = s3://<部署 bucket>/_platform/ = infra/host/platform/（加上 OpenTofu 產生的 platform.env）。
set -euo pipefail
export HOME=/root PATH="$PATH:/snap/bin"

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

# ---------- podman ----------
put "$src/storage.conf" /etc/containers/storage.conf 644
printf '{\n  "credHelpers": {\n    "%s": "ecr-login"\n  }\n}\n' "$REGISTRY" >"$tmp/auth.json"
put "$tmp/auth.json" /etc/containers/platform-auth.json 600
put "$src/quadlet/container.d/10-platform.conf" /etc/containers/systemd/container.d/10-platform.conf 644
put "$src/quadlet/volume.d/10-platform.conf" /etc/containers/systemd/volume.d/10-platform.conf 644

# ---------- 共用入口 ----------
install -d -m 755 /srv/edge /srv/edge/caddy /srv/edge/caddy/sites /srv/edge/data /srv/edge/config
{
  echo "# infra/host/platform/install.sh 產生；各專案的站台檔放在 sites/（tenant-deploy 放的）"
  if [[ -n "${ACME_EMAIL:-}" ]]; then
    printf '{\n\temail %s\n}\n\n' "$ACME_EMAIL"
  fi
  echo "import /etc/caddy/sites/*.caddy"
} >"$tmp/Caddyfile"
put "$tmp/Caddyfile" /srv/edge/caddy/Caddyfile 644
put "$src/quadlet/edge/edge.network" /etc/containers/systemd/edge/edge.network 644
put "$src/quadlet/edge/edge-caddy.container" /etc/containers/systemd/edge/edge-caddy.container 644

# ---------- 給各專案用的指令 ----------
put "$src/tenant-deploy" /usr/local/sbin/tenant-deploy 755
put "$src/tenant-backup" /usr/local/sbin/tenant-backup 755
put "$src/systemd/tenant-backup.service" /etc/systemd/system/tenant-backup.service 644
put "$src/systemd/tenant-backup.timer" /etc/systemd/system/tenant-backup.timer 644
put "$src/tenant-hourly" /usr/local/sbin/tenant-hourly 755
put "$src/systemd/tenant-hourly.service" /etc/systemd/system/tenant-hourly.service 644
put "$src/systemd/tenant-hourly.timer" /etc/systemd/system/tenant-hourly.timer 644

systemctl daemon-reload
systemctl enable --now tenant-backup.timer
systemctl enable --now tenant-hourly.timer

# edge：單元或 podman 的設定改了就重啟；只有 Caddyfile 改了就 reload（不斷線）
if was_changed /etc/containers/systemd/ /etc/containers/storage.conf /etc/containers/platform-auth.json; then
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
