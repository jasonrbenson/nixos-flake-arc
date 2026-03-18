{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.azure-arc;
in
{
  options.services.azure-arc = {
    enable = mkEnableOption "Azure Arc Connected Machine Agent";

    package = mkOption {
      type = types.package;
      default = pkgs.azcmagent or (throw "azcmagent package not found. Add the nixos-flake-arc overlay to your nixpkgs.");
      description = "The azcmagent FHS-wrapped package to use.";
    };

    # --- Connection settings ---
    tenantId = mkOption {
      type = types.str;
      description = "Azure Active Directory tenant ID for Arc enrollment.";
    };

    subscriptionId = mkOption {
      type = types.str;
      description = "Azure subscription ID for the Arc-enabled server resource.";
    };

    resourceGroup = mkOption {
      type = types.str;
      description = "Azure resource group for the Arc-enabled server resource.";
    };

    location = mkOption {
      type = types.str;
      default = "eastus";
      description = "Azure region for the Arc-enabled server resource.";
    };

    cloud = mkOption {
      type = types.enum [ "AzureCloud" "AzureUSGovernment" "AzureChinaCloud" ];
      default = "AzureCloud";
      description = "Azure cloud environment.";
    };

    # --- Authentication ---
    authMethod = mkOption {
      type = types.enum [ "servicePrincipal" "interactiveBrowser" "deviceCode" ];
      default = "servicePrincipal";
      description = "Authentication method for connecting to Azure Arc.";
    };

    servicePrincipalId = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Service principal application (client) ID. Required when authMethod is 'servicePrincipal'.";
    };

    servicePrincipalSecretFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a file containing the service principal client secret.
        The file should contain only the secret value.
        Consider using sops-nix or agenix for secret management.
      '';
    };

    # --- Network settings ---
    proxy = {
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "HTTP(S) proxy URL for agent communication.";
        example = "http://proxy.example.com:8080";
      };

      bypass = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "List of addresses/CIDRs that should bypass the proxy.";
      };
    };

    # --- Extension settings ---
    extensions = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Azure Arc VM extension management (extd service).";
      };

      allowList = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "List of allowed extension names. Empty means all extensions are allowed.";
        example = [ "Microsoft.Azure.Monitor" "Microsoft.Azure.AzureDefenderForServers" ];
      };

      blockList = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "List of blocked extension names.";
      };
    };

    # --- Guest Configuration ---
    guestConfiguration = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Azure Arc Guest Configuration agent (gcad service).";
      };
    };

    # --- Advanced ---
    extraConfig = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional azcmagent configuration key-value pairs.";
    };
  };

  config = mkIf cfg.enable {

    # System users matching what the official postinst creates
    users.users.himds = {
      isSystemUser = true;
      group = "himds";
      description = "Azure Arc Connected Machine Agent";
    };
    users.groups.himds = { };

    users.users.arcproxy = {
      isSystemUser = true;
      group = "himds";
      description = "Azure Arc Proxy Service";
    };

    # State directories
    # State directories — using root ownership for PoC simplicity.
    # The real DEB postinst uses himds:himds, but azcmagent connect (run as
    # root) creates root-owned files that himds can't modify. Running
    # services as root for now avoids permission issues; proper user
    # separation is a Phase 4 hardening task.
    systemd.tmpfiles.rules = [
      "d /var/opt/azcmagent 0755 root root -"
      "d /var/opt/azcmagent/certs 0755 root root -"
      "d /var/opt/azcmagent/log 0755 root root -"
      "d /var/opt/azcmagent/socks 0755 root root -"
      "d /var/opt/azcmagent/tokens 0755 root root -"
      "d /var/lib/GuestConfig 0700 root root -"
      "d /var/lib/waagent 0700 root root -"

      # Writable directories for extension installs and GC state.
      # These get bind-mounted OVER the read-only /opt paths inside bwrap,
      # giving extensions write access while preserving the base binaries.
      "d /var/opt/azcmagent/opt-azcmagent 0755 root root -"
      "d /var/opt/azcmagent/opt-gc-ext 0755 root root -"
      "d /var/opt/azcmagent/opt-gc-service 0755 root root -"
    ];

    # Pre-populate writable /opt overlays from the package.
    # This runs once after tmpfiles creates the directories. On subsequent boots,
    # the existing state (with installed extensions) is preserved.
    systemd.services.azure-arc-init = {
      description = "Initialize Azure Arc writable overlays";
      wantedBy = [ "multi-user.target" ];
      before = [ "himdsd.service" "gcad.service" "extd.service" ];
      unitConfig.ConditionDirectoryNotEmpty = "!/var/opt/azcmagent/opt-azcmagent/bin";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = let
          initScript = pkgs.writeShellScript "azure-arc-init" ''
            set -euo pipefail
            echo "Initializing Azure Arc writable overlays from package..."
            ${pkgs.rsync}/bin/rsync -a --ignore-existing ${cfg.package.passthru.unwrapped}/azcmagent/ /var/opt/azcmagent/opt-azcmagent/
            ${pkgs.rsync}/bin/rsync -a --ignore-existing ${cfg.package.passthru.unwrapped}/GC_Ext/ /var/opt/azcmagent/opt-gc-ext/
            ${pkgs.rsync}/bin/rsync -a --ignore-existing ${cfg.package.passthru.unwrapped}/GC_Service/ /var/opt/azcmagent/opt-gc-service/

            # Fix permissions (nix store copies are read-only)
            chmod -R u+w /var/opt/azcmagent/opt-azcmagent/
            chmod -R u+w /var/opt/azcmagent/opt-gc-ext/
            chmod -R u+w /var/opt/azcmagent/opt-gc-service/

            # Create gc.config files that tell gc_linux_service its mode
            # (the install.sh scripts normally do this)
            echo '{"ServiceType" : "Extension"}' > /var/opt/azcmagent/opt-gc-ext/GC/gc.config
            echo '{"ServiceType" : "GuestConfiguration"}' > /var/opt/azcmagent/opt-gc-service/GC/gc.config

            # Create sockets directories for GC IPC
            mkdir -p /var/opt/azcmagent/opt-gc-ext/GC/sockets
            mkdir -p /var/opt/azcmagent/opt-gc-service/GC/sockets

            echo "Azure Arc writable overlays initialized."
          '';
        in "${initScript}";
      };
    };

    # --- HIMDS: Core Agent Service ---
    # Based on actual himdsd.service from the DEB package
    systemd.services.himdsd = {
      description = "Azure Connected Machine Agent Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        IDENTITY_ENDPOINT = "http://localhost:40342/metadata/identity/oauth2/token";
        IMDS_ENDPOINT = "http://localhost:40342";
      } // (optionalAttrs (cfg.proxy.url != null) {
        HTTPS_PROXY = cfg.proxy.url;
        HTTP_PROXY = cfg.proxy.url;
        NO_PROXY = concatStringsSep "," cfg.proxy.bypass;
      });

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/azcmagent-fhs /opt/azcmagent/bin/himds";
        TimeoutStartSec = 5;
        Restart = "on-failure";
        RestartSec = "5s";

        # PoC: running as root to avoid permission conflicts between
        # azcmagent connect (root) and himds service. Phase 4 will
        # restore User=himds with proper ownership setup.

        # Note: bwrap (used by buildFHSEnv) requires mount + user namespaces,
        # so we cannot use RestrictNamespaces or ProtectSystem here.
        PrivateTmp = false;
      };
    };

    # --- Arc Proxy Service ---
    # Based on actual arcproxyd.service from the DEB package
    systemd.services.arcproxyd = {
      description = "Azure Arc Proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/azcmagent-fhs /opt/azcmagent/bin/arcproxy";
        TimeoutStartSec = 5;
        Restart = "on-failure";
        RestartSec = "5s";

        PrivateTmp = false;
      };
    };

    # --- Guest Configuration Agent Service ---
    systemd.services.gcad = mkIf cfg.guestConfiguration.enable {
      description = "GC Arc Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        HOME = "/var/lib/GuestConfig";
        LD_LIBRARY_PATH = "/opt/GC_Service/GC";
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/azcmagent-fhs /opt/GC_Service/GC/gc_linux_service";
        TimeoutStartSec = 5;
        Restart = "always";
        RestartSec = "10s";
        TimeoutStopSec = 600;
        CPUQuota = "5%";
      };
    };

    # --- Extension Manager Service ---
    systemd.services.extd = mkIf cfg.extensions.enable {
      description = "Extension Service";
      wantedBy = [ "multi-user.target" "himdsd.service" ];
      after = [ "network.target" "himdsd.service" ];
      requires = [ "himdsd.service" ];

      environment = {
        LD_LIBRARY_PATH = "/opt/GC_Ext/GC";
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/azcmagent-fhs /opt/GC_Ext/GC/gc_linux_service";
        TimeoutStartSec = 5;
        Restart = "always";
        RestartSec = "10s";
        TimeoutStopSec = 600;
        CPUQuota = "5%";
        KillMode = "process";
      };
    };

    # Agent package + connection helper script
    environment.systemPackages = [
      cfg.package
      (pkgs.writeShellScriptBin "arc-connect" ''
        set -euo pipefail

        echo "Connecting this NixOS machine to Azure Arc..."
        echo "  Tenant:       ${cfg.tenantId}"
        echo "  Subscription: ${cfg.subscriptionId}"
        echo "  Resource Group: ${cfg.resourceGroup}"
        echo "  Location:     ${cfg.location}"
        echo ""

        CONNECT_ARGS=(
          "--tenant-id" "${cfg.tenantId}"
          "--subscription-id" "${cfg.subscriptionId}"
          "--resource-group" "${cfg.resourceGroup}"
          "--location" "${cfg.location}"
          "--cloud" "${cfg.cloud}"
        )

        ${optionalString (cfg.authMethod == "servicePrincipal" && cfg.servicePrincipalId != null) ''
          CONNECT_ARGS+=("--service-principal-id" "${cfg.servicePrincipalId}")
          ${optionalString (cfg.servicePrincipalSecretFile != null) ''
            CONNECT_ARGS+=("--service-principal-secret" "$(cat ${cfg.servicePrincipalSecretFile})")
          ''}
        ''}

        ${optionalString (cfg.proxy.url != null) ''
          export HTTPS_PROXY="${cfg.proxy.url}"
        ''}

        exec sudo ${cfg.package}/bin/azcmagent-fhs /opt/azcmagent/bin/azcmagent connect "''${CONNECT_ARGS[@]}"
      '')

      (pkgs.writeShellScriptBin "arc-status" ''
        exec ${cfg.package}/bin/azcmagent-fhs /opt/azcmagent/bin/azcmagent show
      '')
    ];

    # --- Assertions ---
    assertions = [
      {
        assertion = cfg.authMethod != "servicePrincipal" || cfg.servicePrincipalId != null;
        message = "services.azure-arc.servicePrincipalId must be set when using servicePrincipal auth method.";
      }
    ];
  };
}
