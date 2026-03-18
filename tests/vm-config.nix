# Shared NixOS configuration for Azure Arc test VMs.
#
# This module is used by both the aarch64 (UTM/local) and x86_64 (Azure)
# test VM configurations. It provides a minimal but functional NixOS system
# with the Azure Arc agent enabled in a "ready to connect" state.
#
# After booting, run `sudo arc-connect` to enroll with Azure Arc.

{ config, pkgs, lib, ... }:

{
  # --- Boot ---
  # Works for both UTM (virtio) and Azure (Hyper-V) VMs
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Generic kernel with virtio support
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "virtio_net"
    "hv_vmbus"      # Hyper-V (Azure)
    "hv_storvsc"
    "hv_netvsc"
  ];

  # Root filesystem — override in VM-specific config or use disko
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = lib.mkDefault {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  # --- Networking ---
  networking.networkmanager.enable = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    # Port 40342 is local-only (IMDS endpoint), no firewall rule needed
  };

  # --- Users ---
  # Test user with sudo access
  users.users.arc-test = {
    isNormalUser = true;
    initialPassword = "arc-test";
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      # Add your SSH public key here for key-based access
      # "ssh-ed25519 AAAA... you@machine"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  # --- SSH ---
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = true; # For initial access; disable after adding keys
    };
  };

  # --- Azure Arc Agent ---
  services.azure-arc = {
    enable = true;

    # !! Fill these in with your Azure details before connecting !!
    tenantId = "CHANGE-ME-tenant-id";
    subscriptionId = "CHANGE-ME-subscription-id";
    resourceGroup = "CHANGE-ME-resource-group";
    location = "eastus";

    # Authentication — use service principal for non-interactive connect
    authMethod = "servicePrincipal";
    servicePrincipalId = "CHANGE-ME-sp-app-id";
    # Create this file on the VM with your SP secret:
    #   echo "your-secret" | sudo tee /run/secrets/arc-sp-secret
    servicePrincipalSecretFile = "/run/secrets/arc-sp-secret";

    # Enable all sub-services
    extensions.enable = true;
    guestConfiguration.enable = true;
  };

  # --- Helpful packages for testing ---
  environment.systemPackages = with pkgs; [
    vim
    curl
    wget
    jq
    htop
    git
    tmux
  ];

  # --- VM-specific settings ---
  # When built as a QEMU VM via `nixos-rebuild build-vm`, these apply
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 20480; # 20GB
      forwardPorts = [
        { from = "host"; host.port = 2222; guest.port = 22; }
      ];
    };
  };

  # Timezone
  time.timeZone = "UTC";

  # Nix settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "arc-test" ];
  };

  system.stateVersion = "24.11";
}
