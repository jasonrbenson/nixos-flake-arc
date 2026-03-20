#!/usr/bin/env bash
# hyperv-install.sh — Automated NixOS installation for Hyper-V VMs
#
# Run this from the NixOS minimal ISO booted in a Hyper-V Generation 2 VM.
# It partitions /dev/sda (the default Hyper-V disk), formats it, and runs
# nixos-install with the Arc test flake configuration.
#
# Usage (from the ISO root shell):
#   curl -L https://raw.githubusercontent.com/jasonrbenson/nixos-flake-arc/main/tests/hyperv-install.sh | bash
#   # Or if you've cloned the repo:
#   bash /path/to/tests/hyperv-install.sh
#
# Prerequisites:
#   - Hyper-V Generation 2 VM (UEFI) with Secure Boot DISABLED
#   - At least 20 GB virtual hard disk
#   - Network connectivity (Default Switch or external)

set -euo pipefail

DISK="${1:-/dev/sda}"
FLAKE_URL="${2:-github:jasonrbenson/nixos-flake-arc}"
FLAKE_CONFIG="arc-test-hyperv-x86_64"

echo "============================================="
echo "  NixOS Hyper-V Installation for Azure Arc"
echo "============================================="
echo ""
echo "  Disk:   ${DISK}"
echo "  Flake:  ${FLAKE_URL}#${FLAKE_CONFIG}"
echo ""

# Confirm
read -rp "This will ERASE ${DISK}. Continue? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo "--- Step 1: Partitioning ${DISK} (GPT + EFI) ---"
parted "${DISK}" -- mklabel gpt
parted "${DISK}" -- mkpart ESP fat32 1MiB 512MiB
parted "${DISK}" -- set 1 esp on
parted "${DISK}" -- mkpart primary ext4 512MiB 100%

# Wait for partition devices
sleep 2

# Determine partition device names (sda1/sda2 or nvme0n1p1/p2)
if [[ "${DISK}" == *"nvme"* ]]; then
  BOOT_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  BOOT_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

echo ""
echo "--- Step 2: Formatting partitions ---"
mkfs.fat -F 32 -n ESP "${BOOT_PART}"
mkfs.ext4 -L nixos "${ROOT_PART}"

echo ""
echo "--- Step 3: Mounting filesystems ---"
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
mount "${BOOT_PART}" /mnt/boot

echo ""
echo "--- Step 4: Installing NixOS ---"
echo "This will download and build the system. It may take 10-30 minutes"
echo "depending on your network speed and hardware."
echo ""

nixos-install --flake "${FLAKE_URL}#${FLAKE_CONFIG}" --no-root-passwd

echo ""
echo "============================================="
echo "  Installation complete!"
echo "============================================="
echo ""
echo "  Next steps:"
echo "  1. Reboot:  reboot"
echo "  2. Remove the ISO from the VM's DVD drive"
echo "  3. Login:   arc-test / arc-test"
echo "  4. Connect: sudo arc-connect"
echo ""
echo "  The arc-connect script will prompt for Azure details."
echo "  Have your tenant ID, subscription, and service principal ready."
echo "============================================="
