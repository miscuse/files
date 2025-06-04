#!/usr/bin/env bash
set -euo pipefail

# --- Step 0: Custom mirrorlist ---
cat << EOF > /etc/pacman.d/mirrorlist
CacheServer = https://mirrors.bfsu.edu.cn/archlinux/$repo/os/$arch
CacheServer = https://mirrors.cloud.tencent.com/archlinux/$repo/os/$arch
CacheServer = https://mirrors.jlu.edu.cn/archlinux/$repo/os/$arch
CacheServer = https://mirrors.nju.edu.cn/archlinux/$repo/os/$arch
CacheServer = https://mirrors.zju.edu.cn/archlinux/$repo/os/$arch
CacheServer = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
CacheServer = https://mirrors.pku.edu.cn/archlinux/$repo/os/$arch
CacheServer = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
CacheServer = https://mirrors.163.com/archlinux/$repo/os/$arch
#CacheServer = https://asia.archive.pkgbuild.com/.all
#Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.bfsu.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
EOF

# --- Step 1: User input ---
read -rp "Enter target disk (e.g. /dev/nvme0n1): " disk
read -rp "Enter EFI partition size (default: 1G): " efi_size
efi_size=${efi_size:-1G}

read -rp "Enter hostname: " hostname
read -rp "Enter new username: " username

echo -n "[*] Enter a password for root: "
read -rs password
echo

# --- Step 2: Wipe disk ---
echo "[*] Wiping disk $disk"
blkdiscard -v -f "$disk"
sgdisk -o "$disk" || true

# --- Step 3: Create partitions ---
echo "[*] Creating partitions"
sgdisk -n 1:0:+"$efi_size" -t 1:ef00 -c 1:"EFI system partition" "$disk"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux filesystem" "$disk"
partprobe "$disk"
efi_part="/dev/$(lsblk -lno NAME "$disk" | head -2 | tail -1)"
root_part="/dev/$(lsblk -lno NAME "$disk" | head -3 | tail -1)"

# --- Step 4: Format partitions ---
echo "[*] Formatting partitions"
mkfs.fat -F 32 -n ARCH_EFI "$efi_part"
mkfs.btrfs -L ARCH_ROOT "$root_part"

# --- Step 5: Create subvolumes and mount ---
echo "[*] Creating and mounting Btrfs subvolumes"
mount -o compress=zstd,ssd "$root_part" /mnt

for subvol in root home log cache snapshots-root snapshots-home portables machines aurbuild swap dotvar; do
  btrfs subvolume create "/mnt/$subvol"
done

umount -R /mnt

mount -o compress=zstd,ssd,subvol=root "$root_part" /mnt
mkdir -p /mnt/{boot/efi,var/log,var/cache,var/lib/portables,var/lib/machines,var/lib/aurbuild,home/"$username"/.var}
mount "$efi_part" /mnt/boot/efi
mount -o compress=zstd,ssd,subvol=log "$root_part" /mnt/var/log
mount -o compress=zstd,ssd,subvol=cache "$root_part" /mnt/var/cache
mount -o compress=zstd,ssd,subvol=portables "$root_part" /mnt/var/portables
mount -o compress=zstd,ssd,subvol=machines "$root_part" /mnt/var/machines
mount -o compress=zstd,ssd,subvol=aurbuild "$root_part" /mnt/var/aurbuild
mount -o compress=zstd,ssd,subvol=home "$root_part" /mnt/home/"$username"
mount -o compress=zstd,ssd,subvol=dotvar "$root_part" /mnt/home/"$username"/.var

# --- Step 6: Install base system ---
echo "[*] Installing base system"
pacstrap -K /mnt base base-devel linux linux-firmware \
  neovim networkmanager sudo btrfs-progs man-db man-pages \
  vim intel-ucode zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting \
  noto-fonts-cjk noto-fonts noto-fonts-emoji ttf-sarasa-gothic ttf-jetbrains-mono \
  ttf-nerd-fonts-symbols-mono starship htop moreutils ripgrep fd fzf fastfetch

# --- Step 7: Configure system ---
echo "[*] Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "[*] Configuring system"

arch-chroot /mnt /bin/bash << EOF
set -euo pipefail

echo "$hostname" > /etc/hostname
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc

# Locale settings
sed -i 's/^\(#\s*\)\(en_US.UTF-8.*\)/\2/' /etc/locale.gen
sed -i 's/^\(#\s*\)\(zh_CN.UTF-8.*\)/\2/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# Set user and passwords
echo "root:$password" | chpasswd
useradd -m -G wheel -s /bin/zsh "$username"
echo "$username:$password" | chpasswd
cp -rT /etc/skel /home/$username
chown -R "$username:$username" /home/$username

# Enable sudo for wheel group
sed -i 's/^\(#\s*\)\(%wheel ALL=(ALL:ALL) ALL.*\)/\2/' /etc/sudoers

# GRUB installation
pacman -S --noconfirm grub efibootmgr os-prober
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 button.lid_init_state=open"/' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Install other packages
pacman -S --noconfirm gnome firefox firefox-i18n-zh-cn

# Fix nvidia black screen issue (optional)
ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules

# Enable services
systemctl enable NetworkManager
systemctl enable gdm
EOF

echo "[✓] System installation complete! You can now reboot."
