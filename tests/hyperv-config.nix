# Hyper-V specific NixOS configuration for x86_64 Azure Arc testing.
#
# Extends the shared VM config with Hyper-V Generation 2 (UEFI) boot,
# guest integration services, and filesystem layout compatible with
# both ISO installation and VHDX image generation.
#
# Install from ISO:
#   nixos-install --flake /path/to/repo#arc-test-hyperv-x86_64
#
# Build VHDX image (requires x86_64-linux builder):
#   nix build .#nixosConfigurations.arc-test-hyperv-x86_64.config.system.build.hypervImage

{ config, pkgs, lib, ... }:

{
  imports = [ ./vm-config.nix ];

  # --- Hyper-V Guest Integration ---
  virtualisation.hypervGuest.enable = true;

  # Override boot loader: Hyper-V Gen2 needs GRUB with UEFI
  # (systemd-boot from vm-config.nix doesn't work with VHDX image builder)
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.grub = {
    device = lib.mkForce "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

  # Filesystem layout matching Hyper-V image conventions
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };
  fileSystems."/boot" = lib.mkForce {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  # Dynamic disk growth on first boot
  boot.growPartition = true;

  # NTP — ensure clock stays synced (critical for Azure Arc JWT auth)
  services.timesyncd.enable = true;

  # Hyper-V enhanced session mode tools (optional, for GUI console)
  # Uncomment if you want RDP-based enhanced session:
  # services.xrdp.enable = true;
  # services.xrdp.defaultWindowManager = "startplasma-x11";
}
