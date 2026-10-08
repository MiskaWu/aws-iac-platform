#!/bin/bash
# 把 /srv 資料碟掛上（cloud-init 第一次開機時執行；之後開機靠 fstab）。
# 資料碟是獨立的 EBS（infra/host.tf），換主機時會掛到新主機：已經有檔案系統就絕對不格式化。
set -euo pipefail

vol="$(cat /etc/platform/data-volume-id)"
dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol//-/}"

# 主機開起來時資料碟可能還沒掛上（aws_volume_attachment 在主機建好之後才做），等它出現
for _ in $(seq 1 120); do
  [[ -e "$dev" ]] && break
  sleep 5
done
[[ -e "$dev" ]] || { echo "mount-data: 等了 10 分鐘，資料碟 $vol 還沒出現" >&2; exit 1; }

if ! blkid "$dev" >/dev/null 2>&1; then
  mkfs.ext4 -q -L platform-data "$dev"
fi

uuid="$(blkid -s UUID -o value "$dev")"
mkdir -p /srv
if ! grep -q "^UUID=$uuid " /etc/fstab; then
  echo "UUID=$uuid /srv ext4 defaults,nofail,x-systemd.device-timeout=60s 0 2" >>/etc/fstab
fi

if ! mountpoint -q /srv; then
  chattr +i /srv # 沒掛上時誰都寫不進去，不會在根碟上悄悄長出一份空的資料
  mount /srv
fi
