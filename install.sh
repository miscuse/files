#!/usr/bin/bash
set -euo pipefail

# 用法: curl -s https://example.com/install.sh | bash -s /dev/nvme0n1 2G
disk="${1:-/dev/vda}"
efi_size="${2:-1G}"

# 分区名自动适配: nvme使用p1/p2，其它用1/2
part_suffix="" && [[ $disk == *"nvme"* ]] && part_suffix="p"

efi_part="${disk}${part_suffix}1"
root_part="${disk}${part_suffix}2"

echo "[*] Wiping disk: $disk"
# sgdisk --zap-all "$disk"
blkdiscard -v -f "$disk"
# 不能用 blkdiscard 才考虑 dd bs=1M status=progress if=/dev/urandom of=/dev/deleteyourssd
sgdisk --zap-all -o "$disk"

echo "[*] Creating partitions"
sgdisk -n 1:0:+"$efi_size" -t 1:ef00 -c 1:"EFI system partition" "$disk"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux filesystem" "$disk"
# 使用 sgdisk -p "$disk" 查看分区结果
partprobe "$disk"

echo "[*] Formatting partitions"
mkfs.fat -F32 -n arch-efi "$efi_part"
mkfs.btrfs -L arch-root "$root_part"

echo "[*] Mounting root device temporarily to create subvolumes"
mount -o compress=zstd "$root_part" /mnt

for subvol in root home log cache snapshots-root snapshots-home; do
  btrfs subvolume create "/mnt/$subvol"
done

umount -R /mnt

echo "[*] Remounting subvolumes"
mount -o compress=zstd,subvol=root "$root_part" /mnt

mkdir -p /mnt/{boot/efi,var/log,var/cache,home/mii}
mount "$efi_part" /mnt/boot/efi
mount -o compress=zstd,subvol=log "$root_part" /mnt/var/log
mount -o compress=zstd,subvol=cache "$root_part" /mnt/var/cache
mount -o compress=zstd,subvol=home "$root_part" /mnt/home/mii

echo "[✓] Btrfs layout and mount complete!"
