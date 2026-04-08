#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
TARGET_MOUNT="/mnt"
CRYPT_NAME="cryptroot"
EFI_SIZE_MIB=1024
DEFAULT_LOCALE="en_US.UTF-8"
DEFAULT_KEYMAP="us"
DEFAULT_ZRAM_SIZE_EXPR='min(ram / 2, 8192)'

SELECTED_DISK=""
EFI_PART=""
ROOT_PART=""
MICROCODE_PACKAGE=""
MICROCODE_IMAGE=""
LIVE_TIMEZONE="UTC"
HOSTNAME_VALUE=""
USERNAME_VALUE=""
ROOT_POLICY="lock"
LUKS_PASSPHRASE=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root."
}

require_clean_mountpoint() {
  if findmnt -rn "$TARGET_MOUNT" >/dev/null 2>&1; then
    die "$TARGET_MOUNT is already mounted. Unmount it before running the installer."
  fi
}

require_commands() {
  local commands=(
    arch-chroot
    btrfs
    findmnt
    blkid
    bootctl
    cryptsetup
    curl
    genfstab
    lsblk
    mkfs.btrfs
    mkfs.fat
    pacstrap
    partprobe
    sgdisk
    udevadm
    wipefs
  )
  local missing=()
  local cmd

  for cmd in "${commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    die "Missing required commands in the live environment: ${missing[*]}"
  fi
}

require_uefi() {
  [[ -d /sys/firmware/efi/efivars ]] || die "UEFI mode is required. Boot the Arch ISO in UEFI mode."
}

require_network() {
  curl -fsSI --connect-timeout 10 https://archlinux.org >/dev/null ||
    die "Network check failed. Bring the live environment online before installing."
}

detect_timezone() {
  local tz
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ -n "$tz" && "$tz" != "n/a" && -e "/usr/share/zoneinfo/$tz" ]]; then
    LIVE_TIMEZONE="$tz"
  fi
}

detect_microcode() {
  local vendor
  vendor="$(awk -F: '/vendor_id/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)"
  case "$vendor" in
    AuthenticAMD)
      MICROCODE_PACKAGE="amd-ucode"
      MICROCODE_IMAGE="amd-ucode.img"
      ;;
    GenuineIntel)
      MICROCODE_PACKAGE="intel-ucode"
      MICROCODE_IMAGE="intel-ucode.img"
      ;;
    *)
      die "Unsupported or unknown CPU vendor '$vendor'."
      ;;
  esac
}

trim() {
  awk '{$1=$1; print}'
}

partition_path() {
  local disk="$1"
  local number="$2"

  if [[ "$disk" =~ (nvme|mmcblk|loop) ]]; then
    printf '%sp%s\n' "$disk" "$number"
  else
    printf '%s%s\n' "$disk" "$number"
  fi
}

list_disks() {
  lsblk -dprno NAME,TYPE | awk '$2 == "disk" {print $1}'
}

show_disk_overview() {
  local disk="$1"
  local size model tran

  size="$(lsblk -dnro SIZE "$disk" | trim)"
  model="$(lsblk -dnro MODEL "$disk" | trim)"
  tran="$(lsblk -dnro TRAN "$disk" | trim)"
  [[ -n "$model" ]] || model="unknown-model"
  [[ -n "$tran" ]] || tran="unknown-transport"

  printf '  Disk: %s | Size: %s | Model: %s | Transport: %s\n' "$disk" "$size" "$model" "$tran"
  lsblk -nrpo NAME,SIZE,FSTYPE,MOUNTPOINTS,TYPE "$disk" | awk '
    $5 == "part" {
      fstype = $3 == "" ? "-" : $3
      mountp = $4 == "" ? "-" : $4
      printf "    %s | %s | fs=%s | mount=%s\n", $1, $2, fstype, mountp
    }
  '
}

select_disk() {
  local disks=()
  local disk
  local index=1
  local choice

  while IFS= read -r disk; do
    disks+=("$disk")
  done < <(list_disks)

  ((${#disks[@]} > 0)) || die "No installable disks were found."

  echo "Available disks:"
  for disk in "${disks[@]}"; do
    printf '%d)\n' "$index"
    show_disk_overview "$disk"
    index=$((index + 1))
  done

  while true; do
    read -rp "Select the target disk number: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || {
      echo "Enter a valid disk number."
      continue
    }
    if ((choice < 1 || choice > ${#disks[@]})); then
      echo "Choose one of the listed disk numbers."
      continue
    fi
    SELECTED_DISK="${disks[choice - 1]}"
    break
  done

  printf '\nSelected disk:\n'
  show_disk_overview "$SELECTED_DISK"
  echo
  read -rp "Type the full disk path to confirm destructive wipe ($SELECTED_DISK): " choice
  [[ "$choice" == "$SELECTED_DISK" ]] || die "Confirmation did not match. Aborting."
}

prompt_nonempty() {
  local prompt="$1"
  local value=""

  while true; do
    read -rp "$prompt" value
    [[ -n "$value" ]] && {
      printf '%s\n' "$value"
      return
    }
    echo "This value cannot be empty."
  done
}

prompt_password() {
  local prompt="$1"
  local first second

  while true; do
    read -rsp "$prompt" first
    echo
    [[ -n "$first" ]] || {
      echo "Password cannot be empty."
      continue
    }
    read -rsp "Confirm: " second
    echo
    if [[ "$first" != "$second" ]]; then
      echo "Values did not match. Try again."
      continue
    fi
    printf '%s\n' "$first"
    return
  done
}

prompt_hostname() {
  while true; do
    HOSTNAME_VALUE="$(prompt_nonempty 'Hostname: ')"
    if [[ "$HOSTNAME_VALUE" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]; then
      return
    fi
    echo "Use only letters, digits, dots, and hyphens."
  done
}

prompt_username() {
  while true; do
    USERNAME_VALUE="$(prompt_nonempty 'Username: ')"
    if [[ "$USERNAME_VALUE" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      return
    fi
    echo "Use a lowercase Linux username, starting with a letter or underscore."
  done
}

prompt_root_policy() {
  local answer

  while true; do
    read -rp "Set a root password? [y/N]: " answer
    answer="${answer,,}"
    case "$answer" in
      y|yes)
        ROOT_POLICY="password"
        ROOT_PASSWORD="$(prompt_password 'Root password: ')"
        return
        ;;
      ""|n|no)
        ROOT_POLICY="lock"
        ROOT_PASSWORD=""
        return
        ;;
      *)
        echo "Answer y or n."
        ;;
    esac
  done
}

collect_identity_inputs() {
  echo "Installer prompts:"
  prompt_hostname
  prompt_username
  prompt_root_policy
  LUKS_PASSPHRASE="$(prompt_password 'LUKS passphrase: ')"
}

wipe_and_partition_disk() {
  EFI_PART="$(partition_path "$SELECTED_DISK" 1)"
  ROOT_PART="$(partition_path "$SELECTED_DISK" 2)"

  log "Wiping partition table on $SELECTED_DISK"
  sgdisk --zap-all "$SELECTED_DISK"
  wipefs -af "$SELECTED_DISK"

  log "Creating GPT layout"
  sgdisk -n 1:0:+"${EFI_SIZE_MIB}MiB" -t 1:ef00 -c 1:EFI "$SELECTED_DISK"
  sgdisk -n 2:0:0 -t 2:8309 -c 2:cryptroot "$SELECTED_DISK"

  partprobe "$SELECTED_DISK"
  udevadm settle
}

format_and_mount() {
  local mapper_path="/dev/mapper/$CRYPT_NAME"
  local btrfs_opts="defaults,noatime,compress=zstd,ssd,discard=async"

  log "Formatting EFI partition"
  mkfs.fat -F32 "$EFI_PART"

  log "Creating LUKS2 container"
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat --batch-mode --type luks2 --key-file - "$ROOT_PART"
  printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open --key-file - "$ROOT_PART" "$CRYPT_NAME"

  log "Creating Btrfs filesystem"
  mkfs.btrfs -f -L archlinux "$mapper_path"

  mount "$mapper_path" "$TARGET_MOUNT"
  btrfs subvolume create "$TARGET_MOUNT/@"
  btrfs subvolume create "$TARGET_MOUNT/@home"
  btrfs subvolume create "$TARGET_MOUNT/@log"
  btrfs subvolume create "$TARGET_MOUNT/@pkg"
  btrfs subvolume create "$TARGET_MOUNT/@snapshots"
  umount "$TARGET_MOUNT"

  mount -o "$btrfs_opts,subvol=@" "$mapper_path" "$TARGET_MOUNT"
  mkdir -p \
    "$TARGET_MOUNT/home" \
    "$TARGET_MOUNT/var/log" \
    "$TARGET_MOUNT/var/cache/pacman/pkg" \
    "$TARGET_MOUNT/.snapshots" \
    "$TARGET_MOUNT/boot"

  mount -o "$btrfs_opts,subvol=@home" "$mapper_path" "$TARGET_MOUNT/home"
  mount -o "$btrfs_opts,subvol=@log" "$mapper_path" "$TARGET_MOUNT/var/log"
  mount -o "$btrfs_opts,subvol=@pkg" "$mapper_path" "$TARGET_MOUNT/var/cache/pacman/pkg"
  mount -o "$btrfs_opts,subvol=@snapshots" "$mapper_path" "$TARGET_MOUNT/.snapshots"
  mount "$EFI_PART" "$TARGET_MOUNT/boot"
}

pacstrap_base() {
  local packages=(
    base
    btrfs-progs
    cryptsetup
    curl
    efibootmgr
    linux-firmware
    man-db
    man-pages
    mkinitcpio
    nano
    networkmanager
    openssl
    snap-pac
    snapper
    sudo
    tar
    texinfo
    vim
    zram-generator
    "$MICROCODE_PACKAGE"
  )

  log "Installing base packages with pacstrap"
  pacstrap -K "$TARGET_MOUNT" "${packages[@]}"
  genfstab -U "$TARGET_MOUNT" >> "$TARGET_MOUNT/etc/fstab"
}

configure_target_system() {
  local root_part_uuid
  local hostname_b64 username_b64 luks_b64 timezone_b64

  root_part_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
  [[ -n "$root_part_uuid" ]] || die "Failed to read UUID for $ROOT_PART"

  hostname_b64="$(printf '%s' "$HOSTNAME_VALUE" | base64 -w 0)"
  username_b64="$(printf '%s' "$USERNAME_VALUE" | base64 -w 0)"
  luks_b64="$(printf '%s' "$LUKS_PASSPHRASE" | base64 -w 0)"
  timezone_b64="$(printf '%s' "$LIVE_TIMEZONE" | base64 -w 0)"

  log "Configuring the installed system inside arch-chroot"
  arch-chroot "$TARGET_MOUNT" /usr/bin/env \
    ROOT_PART_UUID="$root_part_uuid" \
    HOSTNAME_B64="$hostname_b64" \
    USERNAME_B64="$username_b64" \
    ROOT_POLICY="$ROOT_POLICY" \
    LUKS_PASSPHRASE_B64="$luks_b64" \
    MICROCODE_PACKAGE="$MICROCODE_PACKAGE" \
    MICROCODE_IMAGE="$MICROCODE_IMAGE" \
    DEFAULT_LOCALE="$DEFAULT_LOCALE" \
    DEFAULT_KEYMAP="$DEFAULT_KEYMAP" \
    DEFAULT_ZRAM_SIZE_EXPR="$DEFAULT_ZRAM_SIZE_EXPR" \
    LIVE_TIMEZONE_B64="$timezone_b64" \
    bash -se <<'CHROOT_EOF'
set -euo pipefail

decode_b64() {
  printf '%s' "$1" | base64 -d
}

HOSTNAME_VALUE="$(decode_b64 "$HOSTNAME_B64")"
USERNAME_VALUE="$(decode_b64 "$USERNAME_B64")"
LUKS_PASSPHRASE="$(decode_b64 "$LUKS_PASSPHRASE_B64")"
LIVE_TIMEZONE="$(decode_b64 "$LIVE_TIMEZONE_B64")"

configure_locale_and_time() {
  sed -i "s/^#${DEFAULT_LOCALE} UTF-8/${DEFAULT_LOCALE} UTF-8/" /etc/locale.gen
  locale-gen

  cat > /etc/locale.conf <<EOF
LANG=${DEFAULT_LOCALE}
EOF

  cat > /etc/vconsole.conf <<EOF
KEYMAP=${DEFAULT_KEYMAP}
EOF

  if [[ -e "/usr/share/zoneinfo/${LIVE_TIMEZONE}" ]]; then
    ln -sf "/usr/share/zoneinfo/${LIVE_TIMEZONE}" /etc/localtime
  else
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
  fi
  hwclock --systohc
}

configure_identity() {
  echo "$HOSTNAME_VALUE" > /etc/hostname

  cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME_VALUE}.localdomain ${HOSTNAME_VALUE}
EOF
}

install_cachyos_kernel() {
  local temp_dir
  temp_dir="$(mktemp -d)"

  curl -fsSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o "${temp_dir}/cachyos-repo.tar.xz"
  tar -xf "${temp_dir}/cachyos-repo.tar.xz" -C "$temp_dir"
  pushd "${temp_dir}/cachyos-repo" >/dev/null
  set +o pipefail
  yes | ./cachyos-repo.sh
  set -o pipefail
  popd >/dev/null
  rm -rf "$temp_dir"

  pacman -S --noconfirm --needed linux-cachyos linux-cachyos-headers
}

configure_initramfs() {
  sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
  mkinitcpio -P
}

configure_bootloader() {
  bootctl install

  mkdir -p /boot/loader/entries
  cat > /boot/loader/loader.conf <<EOF
default arch-cachyos.conf
timeout 3
editor no
EOF

  cat > /boot/loader/entries/arch-cachyos.conf <<EOF
title   Arch Linux (linux-cachyos)
linux   /vmlinuz-linux-cachyos
initrd  /${MICROCODE_IMAGE}
initrd  /initramfs-linux-cachyos.img
options rd.luks.name=${ROOT_PART_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet
EOF

  cat > /boot/loader/entries/arch-cachyos-fallback.conf <<EOF
title   Arch Linux (linux-cachyos fallback)
linux   /vmlinuz-linux-cachyos
initrd  /${MICROCODE_IMAGE}
initrd  /initramfs-linux-cachyos-fallback.img
options rd.luks.name=${ROOT_PART_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
EOF
}

configure_user_accounts() {
  useradd -m -G wheel -s /bin/bash "$USERNAME_VALUE"
  echo "Set password for user '$USERNAME_VALUE':" > /dev/tty
  passwd "$USERNAME_VALUE" < /dev/tty > /dev/tty 2>&1

  if [[ "$ROOT_POLICY" == "password" ]]; then
    echo "Set password for root:" > /dev/tty
    passwd root < /dev/tty > /dev/tty 2>&1
  else
    passwd -l root
  fi

  install -Dm440 /dev/null /etc/sudoers.d/10-wheel
  cat > /etc/sudoers.d/10-wheel <<EOF
%wheel ALL=(ALL:ALL) ALL
EOF
  chmod 440 /etc/sudoers.d/10-wheel
  visudo -cf /etc/sudoers >/dev/null
}

configure_services() {
  mkdir -p /etc/systemd
  cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${DEFAULT_ZRAM_SIZE_EXPR}
compression-algorithm = zstd
swap-priority = 100
EOF

  systemctl enable NetworkManager.service
  systemctl enable systemd-timesyncd.service
}

configure_locale_and_time
configure_identity
install_cachyos_kernel
configure_initramfs
configure_bootloader
configure_user_accounts
configure_services
CHROOT_EOF
}

print_completion_notes() {
  local root_uuid
  root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
  cat <<EOF

Install finished.

Disk:            $SELECTED_DISK
EFI partition:   $EFI_PART
Encrypted root:  $ROOT_PART
Root UUID:       $root_uuid
Hostname:        $HOSTNAME_VALUE
Username:        $USERNAME_VALUE
Timezone:        $LIVE_TIMEZONE

Before rebooting:
  1. Review /mnt/etc/fstab and /mnt/boot/loader/entries if you want.
  2. Exit the live environment cleanly.
  3. Reboot and unlock the LUKS volume with the passphrase you just set.
EOF
}

main() {
  require_root
  require_commands
  require_clean_mountpoint
  require_uefi
  require_network
  detect_timezone
  detect_microcode
  select_disk
  collect_identity_inputs
  wipe_and_partition_disk
  format_and_mount
  pacstrap_base
  configure_target_system
  print_completion_notes
}

main "$@"
