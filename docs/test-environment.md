# Test Environment Setup Guide

## Overview

You need a NixOS Linux environment to build and test the Azure Arc agent flake.
This guide covers three approaches, from fastest to most realistic.

---

## Option A: Local UTM VM on macOS (Fastest Iteration)

Best for: rapid development, build testing, quick agent smoke tests.

### Prerequisites
- macOS with Apple Silicon (M1/M2/M3/M4)
- ~50GB free disk space

### Steps

#### 1. Install UTM
```bash
brew install --cask utm
```

#### 2. Download NixOS ISO
```bash
# aarch64 minimal ISO (matches your Mac's ARM architecture)
curl -L -o ~/Downloads/nixos-aarch64.iso \
  "https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-aarch64-linux.iso"
```

#### 3. Create VM in UTM
1. Open UTM → "Create a New Virtual Machine"
2. Select **Virtualize** (not Emulate — native speed on ARM)
3. Operating System: **Linux**
4. Boot ISO Image: select the downloaded ISO
5. Hardware:
   - Memory: **8192 MB** (8GB minimum for Nix builds)
   - CPU Cores: **4+**
6. Storage: **40 GB** (NixOS store can be large)
7. Shared Directory: optionally share your repo folder
8. Network: **Shared Network** (NAT — allows outbound internet for Azure Arc)
9. Name it "NixOS Arc Test" and save

#### 4. Install NixOS
```bash
# Boot the VM from ISO, then in the NixOS installer:

# Partition disk (simple layout)
sudo parted /dev/vda -- mklabel gpt
sudo parted /dev/vda -- mkpart ESP fat32 1MB 512MB
sudo parted /dev/vda -- set 1 esp on
sudo parted /dev/vda -- mkpart primary 512MB 100%

sudo mkfs.fat -F 32 -n boot /dev/vda1
sudo mkfs.ext4 -L nixos /dev/vda2

sudo mount /dev/disk/by-label/nixos /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/disk/by-label/boot /mnt/boot

# Generate initial config
sudo nixos-generate-config --root /mnt

# Edit configuration to add our flake
sudo nano /mnt/etc/nixos/configuration.nix
```

Add to the configuration:
```nix
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Minimal user for initial access
  users.users.arc-test = {
    isNormalUser = true;
    initialPassword = "arc-test";
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = true;
}
```

```bash
# Install
sudo nixos-install
sudo reboot
```

#### 5. After Reboot — Switch to the Flake

```bash
# Log in as arc-test / arc-test

# Clone the repo (or use shared folder)
git clone https://github.com/jasonrbenson/nixos-flake-arc.git
cd nixos-flake-arc

# Edit tests/vm-config.nix with your Azure details
vim tests/vm-config.nix

# Switch to the flake configuration
sudo nixos-rebuild switch --flake .#arc-test-vm-aarch64
```

#### 6. Test Azure Arc Connection
```bash
# Create the service principal secret file
echo "your-sp-secret" | sudo tee /run/secrets/arc-sp-secret

# Connect to Azure Arc
sudo arc-connect

# Check status
arc-status
```

### Port Forwarding for SSH (optional)
In UTM VM settings → Network → Port Forward:
- Host: 2222 → Guest: 22

Then from your Mac:
```bash
ssh -p 2222 arc-test@localhost
```

---

## Option B: Azure VM + nixos-anywhere (Most Realistic)

Best for: final validation, demo prep, testing Azure-native networking.

### Prerequisites
- Azure subscription with Contributor access
- Azure CLI (`brew install azure-cli`)
- Nix installed on your Mac (`curl -L https://nixos.org/nix/install | sh`)

### Steps

#### 1. Create an Ubuntu VM in Azure
```bash
az login

# Create resource group
az group create --name arc-nixos-test --location eastus

# Create VM (Ubuntu base — nixos-anywhere will replace it)
az vm create \
  --resource-group arc-nixos-test \
  --name nixos-arc-test \
  --image Ubuntu2204 \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --security-type TrustedLaunch \
  --public-ip-sku Standard

# Note the publicIpAddress from output
```

#### 2. Install Nix on your Mac (if not already)
```bash
curl -L https://nixos.org/nix/install | sh
# Enable flakes
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

#### 3. Deploy NixOS with nixos-anywhere
```bash
cd /path/to/nixos-flake-arc

# Edit tests/vm-config.nix with your Azure details first!

# Replace Ubuntu with NixOS (takes ~5-10 minutes)
nix run github:nix-community/nixos-anywhere -- \
  --flake .#arc-test-vm-x86_64 \
  root@<AZURE-VM-PUBLIC-IP>
```

#### 4. SSH In and Test
```bash
ssh arc-test@<AZURE-VM-PUBLIC-IP>

# Set up the SP secret
echo "your-sp-secret" | sudo tee /run/secrets/arc-sp-secret

# Connect
sudo arc-connect
arc-status
```

#### 5. Clean Up When Done
```bash
az group delete --name arc-nixos-test --yes
```

---

## Option C: Both (Recommended for Full Coverage)

1. Use **Option A** (UTM) for daily development:
   - Fast `nix build` / `nixos-rebuild` cycle
   - Tests aarch64-linux agent
   - No cloud costs

2. Use **Option B** (Azure) for validation milestones:
   - Tests x86_64-linux agent (most common production arch)
   - Real Azure networking (no NAT issues)
   - Can demo directly from this VM

---

## Quick Reference

| Task | Command |
|------|---------|
| Build agent package | `nix build .#azcmagent` |
| Build unwrapped (inspect) | `nix build .#azcmagent-unwrapped` |
| Enter dev shell | `nix develop` |
| Switch VM to flake | `sudo nixos-rebuild switch --flake .#arc-test-vm-aarch64` |
| Connect to Arc | `sudo arc-connect` |
| Check Arc status | `arc-status` |
| View agent logs | `journalctl -u himdsd -f` |
| View proxy logs | `journalctl -u arcproxyd -f` |
| View extension logs | `journalctl -u extd -f` |
| View GC logs | `journalctl -u gcad -f` |

## Troubleshooting

### "azcmagent package not found"
Make sure the overlay is applied. The flake's nixosConfigurations already include it,
but if using a standalone config, add:
```nix
nixpkgs.overlays = [ nixos-arc.overlays.default ];
```

### Build fails with hash mismatch
Microsoft may have updated the package. Check the latest version:
```bash
curl -s "https://packages.microsoft.com/ubuntu/22.04/prod/dists/jammy/main/binary-amd64/Packages" \
  | grep -A5 "^Package: azcmagent$" | head -10
```
Update `agentVersion` and `sha256` in `flake.nix`.

### Services fail to start
Check that the FHS environment has all required libraries:
```bash
# Inside the VM:
journalctl -u himdsd --no-pager | tail -30
journalctl -u gcad --no-pager | tail -30
```
