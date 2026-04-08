# Personal Arch Installer

This repo contains a single guided installer script for running from the Arch Linux live ISO. It is designed for a personal one-disk setup with:

- UEFI only
- GPT partitioning
- EFI System Partition + one LUKS2 root partition
- Btrfs with `@`, `@home`, `@log`, `@pkg`, and `@snapshots`
- `systemd-boot`
- `mkinitcpio` with encrypted-root boot
- zram swap
- CachyOS kernel

## Files

- `install-arch.sh`: interactive installer script intended to be copied to or executed from your Ventoy USB while booted into the Arch live environment

## What The Script Prompts For

- Target disk selection
- Destructive disk confirmation by full path
- Hostname
- Username
- User password
- Root password policy
- LUKS passphrase

## What The Script Does

1. Verifies root access, UEFI boot, a clean `/mnt`, required tools, and working network.
2. Lists detected disks with size, model, transport, and current partitions.
3. Wipes the selected disk and creates:
   - `p1`: 1 GiB EFI System Partition
   - `p2`: LUKS2 encrypted root
4. Creates a Btrfs filesystem and mounts subvolumes at:
   - `/`
   - `/home`
   - `/var/log`
   - `/var/cache/pacman/pkg`
   - `/.snapshots`
5. Installs a minimal Arch base with encryption, Btrfs, networking, sudo, zram, and snapshot tooling.
6. Enters `arch-chroot` from the same script and finishes the installed system configuration.
7. Downloads the current official CachyOS repo bootstrap tarball, runs its repo setup script, and installs `linux-cachyos`.
8. Configures `mkinitcpio`, `systemd-boot`, NetworkManager, `systemd-timesyncd`, sudo, users, and zram.

## Usage

Boot the Arch ISO, get online, then run:

```bash
chmod +x ./install-arch.sh
sudo ./install-arch.sh
```

## Notes

- The script intentionally does not hardcode any disk names. You must choose the disk each run.
- Root is locked by default unless you choose to set a root password.
- The script uses the official CachyOS repo bootstrap script at install time so repo and keyring setup can stay current.
- The script currently defaults locale to `en_US.UTF-8`, keymap to `us`, and timezone to the live environment timezone if available, otherwise `UTC`.
- The script installs snapshot-related tooling, but it does not build a full snapper policy or automatic rollback workflow yet.

## Suggested Validation

- Test in a UEFI VM on both a SATA-style disk name and an NVMe-style disk name.
- Confirm the system boots into `linux-cachyos`.
- Confirm LUKS unlock works, Btrfs subvolumes mount correctly, NetworkManager starts, and zram is active.

## Source Notes

The CachyOS repository bootstrap and package naming were based on the current official documentation and repositories:

- CachyOS optimized repositories: https://wiki.cachyos.org/features/optimized_repos/
- CachyOS kernel documentation: https://wiki.cachyos.org/features/kernel/
- CachyOS repo bootstrap project: https://github.com/CachyOS/cachyos-repo-add-script
