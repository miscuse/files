#!/usr/bin/env bash
set -euo pipefail

# --- Step 1: 用户交互输入 ---
read -rp "请输入目标磁盘（如 /dev/nvme0n1）: " disk
read -rp "请输入 EFI 分区大小（默认 1G）: " efi_size
efi_size=${efi_size:-1G}

read -rp "请输入主机名: " hostname
read -rp "请输入新用户名: " username

echo "[*] 输入 root 和用户通用的登录密码："
read -rs password
echo

# 分区名适配 nvme 使用 p1/p2
part_suffix="" && [[ $disk == *"nvme"* ]] && part_suffix="p"
efi_part="${disk}${part_suffix}1"
root_part="${disk}${part_suffix}2"

# --- Step 2: 擦除磁盘 ---
echo "[*] 擦除磁盘 $disk"
blkdiscard -v -f "$disk" || true
sgdisk -o "$disk" || true

# --- Step 3: 创建分区 ---
echo "[*] 创建分区"
sgdisk -n 1:0:+"$efi_size" -t 1:ef00 -c 1:"EFI system partition" "$disk"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux filesystem" "$disk"
partprobe "$disk"

# --- Step 4: 格式化分区 ---
echo "[*] 格式化分区"
mkfs.fat -F 32 -n arch-efi "$efi_part"
mkfs.btrfs -L arch-root "$root_part"

# --- Step 5: 创建子卷并挂载 ---
echo "[*] 创建并挂载 Btrfs 子卷"
mount -o compress=zstd "$root_part" /mnt

for subvol in root home log cache snapshots-root snapshots-home; do
  btrfs subvolume create "/mnt/$subvol"
done

umount -R /mnt

mount -o compress=zstd,subvol=root "$root_part" /mnt
mkdir -p /mnt/{boot/efi,var/log,var/cache,home/"$username"}
mount "$efi_part" /mnt/boot/efi
mount -o compress=zstd,subvol=log "$root_part" /mnt/var/log
mount -o compress=zstd,subvol=cache "$root_part" /mnt/var/cache
mount -o compress=zstd,subvol=home "$root_part" /mnt/home/"$username"

# --- Step 6: 安装基本系统 ---
echo "[*] 安装基础系统"
pacstrap -K /mnt base base-devel linux linux-firmware \
  neovim networkmanager sudo btrfs-progs man-db man-pages \
  vim intel-ucode zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting \
  noto-fonts-cjk noto-fonts noto-fonts-emoji ttf-sarasa-gothic ttf-jetbrains-mono \
  ttf-nerd-fonts-symbols-mono starship htop moreutils ripgrep fd fzf fastfetch

# --- Step 7: 配置系统 ---
echo "[*] 生成 fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "[*] 配置系统项"

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo "$hostname" > /etc/hostname
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc

# Locale 设置
sed -i 's/^\(#\s*\)\(en_US.UTF-8.*\)/\2/' /etc/locale.gen
sed -i 's/^\(#\s*\)\(zh_CN.UTF-8.*\)/\2/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# 创建用户和 root 密码
echo "root:$password" | chpasswd
useradd -m -G wheel -s /bin/zsh "$username"
echo "$username:$password" | chpasswd
cp -rT /etc/skel /home/$username
chown -R "$username:$username" /home/$username

# sudo 权限
sed -i 's/^\(#\s*\)\(%wheel ALL=(ALL:ALL) ALL.*\)/\2/' /etc/sudoers

# GRUB 安装
pacman -S --noconfirm grub efibootmgr os-prober
pacman -S --noconfirm gnome
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 button.lid_init_state=open"/' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# udev/gdm 修复双显卡黑屏问题（可选）
ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules

# 启用服务
systemctl enable NetworkManager
systemctl enable gdm
EOF

echo "[✓] 系统安装完成！可以 reboot 重启进入系统。"
