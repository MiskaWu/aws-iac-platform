#!/usr/bin/env bash
# 在本機模擬共用主機，跑同一份平台腳本（infra/host/platform/）：平台的改動與各專案的部署包，上線前先在這裡演練。
#
#   tests/host-sim/run.sh up                           建映像、起主機、套用平台（等於 PlatformSync）
#   tests/host-sim/run.sh secret <專案> <名稱>           從 stdin 讀值，寫進假的 Parameter Store
#   tests/host-sim/run.sh load <映像>                    把本機（rootless podman）的映像載入模擬主機
#   tests/host-sim/run.sh deploy <專案> <bundle.tar.gz>  放進假的 S3 並執行 tenant-deploy（等於 TenantDeploy）
#   tests/host-sim/run.sh sync                          平台檔案改了之後重新套用
#   tests/host-sim/run.sh replace                       換一台新主機（/srv 留著），驗證專案自己回來
#   tests/host-sim/run.sh backup                        執行一次每日備份，列出假 S3 裡的備份
#   tests/host-sim/run.sh hourly                        執行一次每小時的工作（各專案的 hourly.sh），印出它的輸出
#   tests/host-sim/run.sh exec <指令…>                  在模擬主機裡執行
#   tests/host-sim/run.sh down [--purge]                停掉；--purge 連 /srv 與假的 S3、Parameter Store 一起刪
#
# 模擬主機是一個 rootless、privileged、跑 systemd 的容器，不需要 sudo；平台在裡面以 root 身分跑 podman，
# 和正式主機一樣是 rootful 的 Quadlet。
# 對外：https://localhost:28443、http://localhost:28080（HOST_SIM_HTTPS、HOST_SIM_HTTP 可改；站台檔的網域用 localhost，
# Caddy 用自己簽的憑證）。
# 和正式環境的差別：沒有 ECR、IAM、IMDS；aws 指令是假的（fake-aws）；不經過 cloud-init（/srv 是掛進來的資料夾）。
# 寄信的臨時憑證：HOST_SIM_SES_PROJECTS="<專案> …" 當成開了 ses 的專案（fake-aws 給假的憑證）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STATE="${HOST_SIM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/host-sim}"
NAME=host-sim
IMAGE=localhost/host-sim:latest
BUCKET=platform-deploy-sim
BACKUPS=platform-backups-sim
PODMAN=(podman)
HTTP_PORT="${HOST_SIM_HTTP:-28080}"
HTTPS_PORT="${HOST_SIM_HTTPS:-28443}"

die() {
  echo "host-sim: $*" >&2
  exit 1
}
inside() { "${PODMAN[@]}" exec "$NAME" "$@"; }
running() { [[ "$("${PODMAN[@]}" container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" == true ]]; }

# 平台檔案放進假的 S3（正式環境由 infra/storage.tf 上傳）
publish_platform() {
  local dst="$STATE/fake/s3/$BUCKET/_platform"
  rm -rf "$dst"
  mkdir -p "$dst"
  cp -r "$REPO/infra/host/platform/." "$dst/"
  cat >"$dst/platform.env" <<EOF
# tests/host-sim/run.sh 產生（正式環境由 infra/storage.tf 產生）
REGION=ap-east-2
REGISTRY=000000000000.dkr.ecr.ap-east-2.amazonaws.com
DEPLOY_BUCKET=$BUCKET
BACKUP_BUCKET=$BACKUPS
ACME_EMAIL=
ACCOUNT_ID=000000000000
SES_PROJECTS="${HOST_SIM_SES_PROJECTS:-}"
EOF
}

# 和 infra/ssm.tf 的 PlatformSync 同樣的步驟
platform_sync() {
  publish_platform
  inside bash -c "set -euo pipefail
    aws s3 sync --delete --only-show-errors s3://$BUCKET/_platform/ /usr/local/lib/platform/
    bash /usr/local/lib/platform/install.sh"
}

start() {
  mkdir -p "$STATE/srv" "$STATE/fake/s3" "$STATE/fake/ssm"
  # rootless 的轉埠走 pasta（userspace），不靠主機的 nftables：WSL 的核心沒有 nft_fib_inet，rootful 的轉埠規則不會生效
  "${PODMAN[@]}" run -d --name "$NAME" --hostname "$NAME" --privileged --systemd=always \
    -v "$STATE/srv:/srv" -v "$STATE/fake:/fake" \
    -p "127.0.0.1:$HTTP_PORT:80" -p "127.0.0.1:$HTTPS_PORT:443" -p "127.0.0.1:$HTTPS_PORT:443/udp" \
    "$IMAGE" >/dev/null
  local s
  for _ in $(seq 1 60); do
    s="$(inside systemctl is-system-running 2>/dev/null || true)"
    [[ "$s" == running || "$s" == degraded ]] && return 0
    sleep 1
  done
  die "模擬主機的 systemd 沒有起來（$s）"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  up)
    "${PODMAN[@]}" build -q -t "$IMAGE" --build-arg "PACKAGES=$(grep -v -e '^#' -e '^[[:space:]]*$' "$REPO/infra/host/packages.txt" | xargs)" "$HERE" >/dev/null
    running || start
    platform_sync
    ;;
  secret)
    p="${1:?用法：secret <專案> <名稱>（值從 stdin 讀）}"
    n="${2:?用法：secret <專案> <名稱>}"
    mkdir -p "$STATE/fake/ssm/$p"
    (umask 077 && cat >"$STATE/fake/ssm/$p/$n")
    ;;
  load)
    img="${1:?用法：load <映像>}"
    podman save -q "$img" | "${PODMAN[@]}" exec -i "$NAME" podman load -q
    ;;
  deploy)
    p="${1:?用法：deploy <專案> <bundle.tar.gz>}"
    b="${2:?用法：deploy <專案> <bundle.tar.gz>}"
    install -D -m 644 "$b" "$STATE/fake/s3/$BUCKET/$p/bundle.tar.gz"
    inside tenant-deploy "$p"
    ;;
  sync) platform_sync ;;
  replace)
    "${PODMAN[@]}" rm -f -t 30 "$NAME" >/dev/null
    start
    platform_sync
    ;;
  hourly)
    inside systemctl start tenant-hourly.service
    inside journalctl -u tenant-hourly.service -n 40 --no-pager -o cat
    ;;
  backup)
    inside systemctl start tenant-backup.service
    inside journalctl -u tenant-backup.service -n 5 --no-pager -o cat
    find "$STATE/fake/s3/$BACKUPS" -type f -printf '%P\t%s bytes\n' 2>/dev/null | sort
    ;;
  exec) inside "$@" ;;
  down)
    "${PODMAN[@]}" rm -f -t 30 "$NAME" >/dev/null 2>&1 || true
    if [[ "${1:-}" == --purge ]]; then
      podman unshare rm -rf "$STATE" # 模擬主機裡的檔案屬於 rootless 的 subuid，要在同一個 user namespace 裡刪
    fi
    ;;
  *)
    sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
