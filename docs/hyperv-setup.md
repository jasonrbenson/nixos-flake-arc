# Hyper-V Setup Guide — NixOS x86_64 for Azure Arc Testing

This guide walks through setting up a NixOS x86_64 VM on Hyper-V (Windows)
for Azure Arc Connected Machine Agent testing.

## Prerequisites

- Windows 10/11 Pro, Enterprise, or Education (Hyper-V requires Pro+)
- At least 8 GB RAM (4 GB allocated to VM)
- 25+ GB free disk space
- Internet connectivity

## Step 1: Enable Hyper-V

Open PowerShell **as Administrator** and run:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Reboot when prompted.

## Step 2: Download NixOS ISO

Download the **NixOS Minimal ISO (x86_64)**:

- Go to: https://nixos.org/download/#nixos-iso
- Select **Minimal ISO image** for **64-bit Intel/AMD**
- Or direct: https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso

Save the ISO somewhere accessible (e.g., `C:\ISOs\nixos-minimal.iso`).

## Step 3: Create the Hyper-V VM

### Option A: PowerShell (recommended)

Open PowerShell **as Administrator**:

```powershell
# Create a Gen2 VM with 4GB RAM, 4 vCPUs, 20GB disk
$VMName = "NixOS-Arc-Test"
$ISOPath = "C:\ISOs\nixos-minimal-x86_64-linux.iso"  # Adjust path

New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 4GB -NewVHDPath "C:\Hyper-V\$VMName.vhdx" -NewVHDSizeBytes 20GB -SwitchName "Default Switch"
Set-VM -Name $VMName -ProcessorCount 4 -DynamicMemory -MemoryMinimumBytes 2GB -MemoryMaximumBytes 8GB

# CRITICAL: Disable Secure Boot (NixOS ISO is not signed for Hyper-V)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Attach the ISO
Add-VMDvdDrive -VMName $VMName -Path $ISOPath

# Set boot order: DVD first, then hard disk
$dvd = Get-VMDvdDrive -VMName $VMName
$hdd = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -BootOrder $dvd, $hdd

# Start the VM
Start-VM -Name $VMName
vmconnect.exe localhost $VMName
```

### Option B: Hyper-V Manager GUI

1. Open **Hyper-V Manager**
2. **Action → New → Virtual Machine**
3. Name: `NixOS-Arc-Test`
4. **Generation: 2** (UEFI — this is critical)
5. Memory: **4096 MB**, enable dynamic memory
6. Networking: **Default Switch** (or an external switch with internet)
7. Hard disk: **20 GB** (or more)
8. Installation: **Install from ISO**, browse to the NixOS ISO
9. **Before starting**, edit VM Settings:
   - **Security → Uncheck "Enable Secure Boot"**
   - **Processor → 4 virtual processors**

## Step 4: Install NixOS

Connect to the VM console and boot from the ISO. You'll get a root shell.

### Automated Install (recommended)

```bash
# Enable flakes in the ISO environment
export NIX_CONFIG="experimental-features = nix-command flakes"

# Run the install script
nix run nixpkgs#curl -- -L \
  https://raw.githubusercontent.com/jasonrbenson/nixos-flake-arc/main/tests/hyperv-install.sh \
  | bash
```

### Manual Install

```bash
# 1. Partition the disk (GPT + EFI)
parted /dev/sda -- mklabel gpt
parted /dev/sda -- mkpart ESP fat32 1MiB 512MiB
parted /dev/sda -- set 1 esp on
parted /dev/sda -- mkpart primary ext4 512MiB 100%

# 2. Format
mkfs.fat -F 32 -n ESP /dev/sda1
mkfs.ext4 -L nixos /dev/sda2

# 3. Mount
mount /dev/sda2 /mnt
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot

# 4. Install
nixos-install --flake github:jasonrbenson/nixos-flake-arc#arc-test-hyperv-x86_64 --no-root-passwd

# 5. Reboot
reboot
```

After reboot, remove the ISO from the VM's DVD drive in Hyper-V settings.

## Step 5: First Boot

1. Login: **arc-test** / **arc-test**
2. Verify networking: `ip addr` (should have an IP from Default Switch)
3. Verify Arc agent package: `azcmagent version`

## Step 6: Connect to Azure Arc

```bash
# Create the service principal secret file
echo "your-sp-secret" | sudo tee /run/secrets/arc-sp-secret

# Edit the Arc configuration (update placeholder values)
sudo nano /etc/nixos/configuration.nix
# Or, if using the flake directly, edit tests/vm-config.nix

# Connect
sudo arc-connect
```

If using the default `vm-config.nix` placeholders, you'll need to update
the tenant ID, subscription ID, resource group, and service principal
before connecting. You can either:

- Edit `tests/vm-config.nix` in the repo and rebuild
- Create a local override: `sudo nixos-rebuild switch --flake .#arc-test-hyperv-x86_64`

## Step 7: Verify Extensions

After Arc connects, enable extensions from the Azure portal or CLI:

```bash
# Check agent status
sudo /opt/azcmagent/bin/azcmagent show

# Check extension services
systemctl status gcad extd

# View extension logs
sudo journalctl -u extd -f
```

## Troubleshooting

### VM won't boot from ISO
- Ensure **Generation 2** was selected (cannot be changed after creation)
- Ensure **Secure Boot is disabled**
- Check boot order: DVD should be before hard disk

### No network in the VM
- Verify the VM is connected to **Default Switch** or an external switch
- Inside NixOS: `systemctl restart NetworkManager`
- Check: `ip link` — the interface should be `eth0` (Hyper-V synthetic NIC)

### Clock skew / Azure auth failures
NTP should auto-sync. If not:
```bash
sudo systemctl restart systemd-timesyncd
timedatectl status
```

### Slow boot / Extension install
First boot may take a few minutes as the system initializes.
Extension installs (especially MDE) can take 5-10 minutes.

## Alternative: Pre-built VHDX Image

If you have access to an x86_64 Linux builder (WSL2, another Linux machine,
or CI), you can build a ready-to-boot VHDX image:

```bash
# On an x86_64-linux machine with Nix:
nix build github:jasonrbenson/nixos-flake-arc#nixosConfigurations.arc-test-hyperv-x86_64.config.system.build.hypervImage

# Copy the VHDX to your Windows machine
ls result/  # → nixos-hyperv-image.vhdx
```

Then in Hyper-V, create a Gen2 VM and attach the existing VHDX instead of
creating a new disk. Remember to **disable Secure Boot**.
