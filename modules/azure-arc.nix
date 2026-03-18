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
      description = "The azcmagent package to use.";
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
      enable = mkEnableOption "Azure Arc VM extension management";

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

    # --- State directories ---
    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/azure-arc";
      description = "Directory for Azure Arc agent state data.";
    };

    logDir = mkOption {
      type = types.path;
      default = "/var/log/azure-arc";
      description = "Directory for Azure Arc agent logs.";
    };

    # --- Advanced ---
    extraConfig = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional azcmagent configuration key-value pairs.";
    };
  };

  config = mkIf cfg.enable {

    # Create state and log directories
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 root root -"
      "d ${cfg.logDir} 0750 root root -"
    ];

    # --- Core Agent Service ---
    systemd.services.azure-arc-agent = {
      description = "Azure Arc Connected Machine Agent";
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
        ExecStart = "${cfg.package}/bin/azcmagent";
        Restart = "on-failure";
        RestartSec = 15;

        # Security hardening
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.stateDir
          cfg.logDir
          "/opt/azcmagent"
          "/opt/GC_Ext"
          "/opt/GC_Service"
          "/var/lib/waagent"
        ];
        PrivateTmp = true;
        NoNewPrivileges = false; # Agent may need to spawn extension processes
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

        exec sudo ${cfg.package}/bin/azcmagent connect "''${CONNECT_ARGS[@]}"
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
