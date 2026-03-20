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
        The file should contain only the secret value, with no trailing newline.

        Recommended: use sops-nix or agenix to manage this secret.

        With sops-nix:
          sops.secrets.arc-sp-secret = { };
          services.azure-arc.servicePrincipalSecretFile =
            config.sops.secrets.arc-sp-secret.path;

        With agenix:
          age.secrets.arc-sp-secret.file = ./secrets/arc-sp-secret.age;
          services.azure-arc.servicePrincipalSecretFile =
            config.age.secrets.arc-sp-secret.path;
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

    # AMA runs its agent as the syslog user (created by postinst)
    users.users.syslog = {
      isSystemUser = true;
      group = "syslog";
      description = "Azure Monitor Agent service user";
    };
    users.groups.syslog = { };

    # State directories — himds-owned for the core agent, root for GC/extensions.
    # The ExecStartPre in himdsd fixes ownership after azcmagent connect (root).
    systemd.tmpfiles.rules = [
      "d /var/opt/azcmagent 0755 himds himds -"
      "d /var/opt/azcmagent/certs 0750 himds himds -"
      "d /var/opt/azcmagent/log 0775 himds himds -"
      "d /var/opt/azcmagent/socks 0750 himds himds -"
      "d /var/opt/azcmagent/tokens 0770 himds himds -"
      "d /var/lib/GuestConfig 0700 root root -"
      "d /var/lib/waagent 0700 root root -"

      # Writable directories for extension installs and GC state.
      # These get bind-mounted OVER the read-only /opt paths inside bwrap,
      # giving extensions write access while preserving the base binaries.
      "d /var/opt/azcmagent/opt-azcmagent 0755 root root -"
      "d /var/opt/azcmagent/opt-gc-ext 0755 root root -"
      "d /var/opt/azcmagent/opt-gc-service 0755 root root -"

      # AMA support: writable /opt/microsoft/ for dpkg-installed AMA binaries,
      # dpkg database, and AMA log/state directories.
      "d /var/opt/azcmagent/opt-microsoft 0755 root root -"
      "d /var/opt/azcmagent/dpkg-db 0755 root root -"
      "d /var/opt/azcmagent/dpkg-db/info 0755 root root -"
      "d /var/opt/azcmagent/dpkg-db/updates 0755 root root -"
      "d /var/opt/microsoft 0755 root root -"
      "d /var/opt/microsoft/azuremonitoragent 0755 root root -"
      "d /var/opt/microsoft/azuremonitoragent/log 0775 syslog syslog -"
      "d /run/azuremonitoragent 0755 root root -"
      "d /etc/opt/microsoft 0755 root root -"
      "d /etc/opt/microsoft/azuremonitoragent 0755 root root -"
      # Writable backing dirs for /etc/default and /etc/logrotate.d inside bwrap.
      # AMA's dpkg writes config files here; postinst uses sed -i on them.
      "d /var/opt/azcmagent/etc-default 0755 root root -"
      "d /var/opt/azcmagent/etc-logrotate-d 0755 root root -"
      "d /var/opt/azcmagent/usr-share-lintian 0755 root root -"

      # APT support: writable directories for MDE's apt-based mdatp installation.
      "d /var/opt/azcmagent/etc-apt 0755 root root -"
      "d /var/opt/azcmagent/etc-apt/sources.list.d 0755 root root -"
      "d /var/opt/azcmagent/etc-apt/apt.conf.d 0755 root root -"
      "d /var/opt/azcmagent/etc-apt/trusted.gpg.d 0755 root root -"
      "d /var/opt/azcmagent/etc-apt/preferences.d 0755 root root -"
      "f /var/opt/azcmagent/etc-apt/sources.list 0644 root root -"
      "d /var/opt/azcmagent/usr-share-keyrings 0755 root root -"
      "d /var/cache/apt 0755 root root -"
      "d /var/cache/apt/archives 0755 root root -"
      "d /var/cache/apt/archives/partial 0755 root root -"
      "d /var/lib/apt 0755 root root -"
      "d /var/lib/apt/lists 0755 root root -"
      "d /var/lib/apt/lists/partial 0755 root root -"
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
            echo '{"ServiceType" : "GCArc"}' > /var/opt/azcmagent/opt-gc-service/GC/gc.config

            # Create sockets directories for GC IPC
            mkdir -p /var/opt/azcmagent/opt-gc-ext/GC/sockets
            mkdir -p /var/opt/azcmagent/opt-gc-service/GC/sockets

            # Initialize dpkg database for AMA extension support.
            # AMA's install handler runs dpkg -i inside bwrap, which needs a
            # valid dpkg database at /var/lib/dpkg (bind-mounted from host).
            if [ ! -f /var/opt/azcmagent/dpkg-db/status ]; then
              touch /var/opt/azcmagent/dpkg-db/status
              touch /var/opt/azcmagent/dpkg-db/available
            fi

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
      after = [ "network-online.target" "azure-arc-init.service" ];
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

        # Fix ownership after azcmagent connect (which runs as root).
        # This ensures himds can read config files and write logs.
        ExecStartPre = let
          fixPerms = pkgs.writeShellScript "fix-arc-perms" ''
            chown -R himds:himds /var/opt/azcmagent/certs /var/opt/azcmagent/log /var/opt/azcmagent/socks /var/opt/azcmagent/tokens 2>/dev/null || true
            # agentconfig.json and other config files in the state dir
            find /var/opt/azcmagent -maxdepth 1 -type f -exec chown himds:himds {} + 2>/dev/null || true
            # Token .key files — himds needs read+write for challenge-response auth
            chown himds:himds /var/opt/azcmagent/tokens/*.key 2>/dev/null || true
          '';
        in "+${fixPerms}";
        ExecStart = "${cfg.package}/bin/azcmagent-fhs /opt/azcmagent/bin/himds";
        TimeoutStartSec = 5;
        Restart = "on-failure";
        RestartSec = "5s";

        User = "himds";
        Group = "himds";

        # Systemd hardening — compatible with bwrap namespaces
        NoNewPrivileges = false; # bwrap needs to create namespaces
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # .NET JIT in GC components needs W+X
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

        # Fix arcproxy.log ownership — may be root/himds-owned from prior runs
        ExecStartPre = let
          fixPerms = pkgs.writeShellScript "fix-arcproxy-perms" ''
            touch /var/opt/azcmagent/log/arcproxy.log
            chown arcproxy:himds /var/opt/azcmagent/log/arcproxy.log /var/opt/azcmagent/log/arcproxy-*.log 2>/dev/null || true
          '';
        in "+${fixPerms}";
        ExecStart = "${cfg.package}/bin/azcmagent-fhs /opt/azcmagent/bin/arcproxy";
        TimeoutStartSec = 5;
        Restart = "on-failure";
        RestartSec = "5s";

        User = "arcproxy";
        Group = "himds";

        # Systemd hardening
        NoNewPrivileges = false;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
      };
    };

    # --- Guest Configuration Agent Service ---
    # Runs as root: manages policy compliance, writes to /var/lib/GuestConfig
    systemd.services.gcad = mkIf cfg.guestConfiguration.enable {
      description = "GC Arc Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "himdsd.service" "azure-arc-init.service" ];
      requires = [ "himdsd.service" ];

      environment = {
        HOME = "/var/lib/GuestConfig";
        LD_LIBRARY_PATH = "/opt/GC_Service/GC";
      };

      serviceConfig = {
        Type = "simple";
        # Wait for himds to load config (avoids 503 race on first timer)
        ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 1 30); do ${pkgs.curl}/bin/curl -sk https://localhost:40341/metadata/instance?api-version=2019-03-11 -H Metadata:true 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q resourceGroup && exit 0; sleep 1; done; echo \"himds not ready after 30s, starting anyway\"'";
        ExecStart = "${cfg.package}/bin/azcmagent-fhs /opt/GC_Service/GC/gc_linux_service";
        TimeoutStartSec = 5;
        Restart = "always";
        RestartSec = "10s";
        TimeoutStopSec = 600;
        CPUQuota = "5%";

        # Systemd hardening
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
      };
    };

    # --- Extension Manager Service ---
    # Runs as root: downloads/installs extensions, writes to /var/lib/waagent
    systemd.services.extd = mkIf cfg.extensions.enable {
      description = "Extension Service";
      wantedBy = [ "multi-user.target" "himdsd.service" ];
      after = [ "network.target" "himdsd.service" "azure-arc-init.service" ];
      requires = [ "himdsd.service" ];

      environment = {
        LD_LIBRARY_PATH = "/opt/GC_Ext/GC";
      };

      serviceConfig = {
        Type = "simple";
        # Wait for himds to load config (avoids 503 race on first timer)
        ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 1 30); do ${pkgs.curl}/bin/curl -sk https://localhost:40341/metadata/instance?api-version=2019-03-11 -H Metadata:true 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q resourceGroup && exit 0; sleep 1; done; echo \"himds not ready after 30s, starting anyway\"'";
        ExecStart = "${cfg.package}/bin/azcmagent-fhs /opt/GC_Ext/GC/gc_linux_service";
        TimeoutStartSec = 5;
        Restart = "always";
        RestartSec = "10s";
        TimeoutStopSec = 600;
        CPUQuota = "5%";
        KillMode = "process";

        # Systemd hardening
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
      };
    };

    # --- Extension Service Wrapper ---
    # Safety net: periodically ensures extension-created systemd units are
    # FHS-wrapped. The primary mechanism is the systemctl daemon-reload
    # interception in the bwrap sandbox, but this catches edge cases (e.g.,
    # units created before the wrapper was in place, or after a reboot where
    # /run/systemd/system/ units need re-patching from boot-time state).
    systemd.services.arc-ext-fhs-wrapper = {
      description = "Wrap Azure Arc extension systemd units for FHS sandbox";
      after = [ "extd.service" ];
      path = [ pkgs.gnugrep pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = let
          wrapScript = pkgs.writeShellScript "arc-ext-fhs-wrap" ''
            FHS=/run/current-system/sw/bin/azcmagent-fhs
            CHANGED=0

            for unit in /run/systemd/system/*.service; do
              [ -f "$unit" ] || continue
              # Patch units with ExecStart in /var/lib/waagent/ or /opt/microsoft/
              grep -qE '^ExecStart=(/var/lib/waagent/|/opt/microsoft/)' "$unit" || continue
              # Skip already-wrapped units
              grep -q 'azcmagent-fhs' "$unit" && continue

              while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                  ExecStart=/var/lib/waagent/*|ExecStart=/opt/microsoft/*)
                    echo "ExecStart=$FHS ''${line#ExecStart=}" ;;
                  *)
                    echo "$line" ;;
                esac
              done < "$unit" > "$unit.tmp"
              mv "$unit.tmp" "$unit"
              CHANGED=1
              echo "Wrapped: $unit"
            done

            [ "$CHANGED" = "1" ] && systemctl daemon-reload || true
          '';
        in wrapScript;
      };
    };

    # Trigger the wrapper when extension manager installs new extensions.
    # Uses a systemd timer (every 5 minutes) as a lightweight safety net.
    systemd.timers.arc-ext-fhs-wrapper = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
      };
    };

    # --- AMA Extension Patcher ---
    # Patches the Azure Monitor Agent extension after download to:
    # 1. Add NixOS to the supported distros allowlist
    # 2. Add NixOS to the dpkg package manager mapping
    # This runs every 30 seconds — first install attempt will fail (exit 51),
    # then the patcher patches the files, and a re-deploy succeeds.
    systemd.services.arc-ama-patcher = {
      description = "Patch AMA extension for NixOS compatibility";
      after = [ "extd.service" ];
      path = [ pkgs.gnused pkgs.gnugrep pkgs.coreutils pkgs.findutils ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = let
          patchScript = pkgs.writeShellScript "arc-ama-patch" ''
            WAAGENT=/var/lib/waagent
            PATCHED=0

            for amadir in "$WAAGENT"/Microsoft.Azure.Monitor.AzureMonitorLinuxAgent-*/; do
              [ -d "$amadir" ] || continue

              # Patch 1: Add NixOS to supported_distros.py (aarch64 and x86_64)
              DISTRO_FILE="$amadir/ama_tst/modules/install/supported_distros.py"
              if [ -f "$DISTRO_FILE" ] && ! grep -q "'nixos'" "$DISTRO_FILE"; then
                # Add nixos to aarch64 dict (after the last rocky entry)
                sed -i "/supported_dists_aarch64/,/^}/ s/'rocky' : \['8', '9'\] # Rocky/'rocky' : ['8', '9'], # Rocky\n                    'nixos' : ['26'] # NixOS/" "$DISTRO_FILE"
                # Add nixos to x86_64 dict (after the amzn entry)
                sed -i "/supported_dists_x86_64/,/^}/ s/'amzn' : \['2', '2023'\] # Amazon Linux 2/'amzn' : ['2', '2023'], # Amazon Linux 2\n                       'nixos' : ['26'] # NixOS/" "$DISTRO_FILE"
                # Remove cached bytecode
                find "$amadir" -name 'supported_distros*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched supported_distros.py in $amadir"
              fi

              # Patch 2: Add NixOS to dpkg_set in agent.py
              AGENT_FILE="$amadir/agent.py"
              if [ -f "$AGENT_FILE" ] && ! grep -q '"nixos"' "$AGENT_FILE"; then
                # Add nixos to the dpkg_set (NixOS can use dpkg via the bwrap sandbox)
                sed -i 's/dpkg_set = set(\["debian", "ubuntu"\])/dpkg_set = set(["debian", "ubuntu", "nixos"])/' "$AGENT_FILE"
                # Remove cached bytecode
                find "$amadir" -name 'agent*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched agent.py dpkg_set in $amadir"
              fi

              # Patch 3: Add --force-depends to dpkg options (skip libc6/ucf/debianutils deps)
              if [ -f "$AGENT_FILE" ] && ! grep -q 'force-depends' "$AGENT_FILE"; then
                sed -i 's/--force-overwrite --force-confnew/--force-overwrite --force-confnew --force-depends/' "$AGENT_FILE"
                find "$amadir" -name 'agent*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched agent.py dpkg --force-depends in $amadir"
              fi

              # Patch 4: Add NixOS to SSL cert path mapping in get_ssl_cert_info()
              # NixOS stores certs at /etc/ssl/certs (same as Debian/Ubuntu)
              if [ -f "$AGENT_FILE" ] && ! grep -q "'ubuntu', 'debian', 'nixos'" "$AGENT_FILE"; then
                sed -i "s/for name in \['ubuntu', 'debian'\]:/for name in ['ubuntu', 'debian', 'nixos']:/" "$AGENT_FILE"
                find "$amadir" -name 'agent*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched agent.py SSL cert mapping for NixOS in $amadir"
              fi

              # Patch 5: Fix KeyError on missing 'protected_settings' in SettingsDict
              # Without WALinux HUtil, SettingsDict may lack the key when no protected settings exist
              # Only patch the READ side (= SettingsDict[...]), not WRITE side (SettingsDict[...] =)
              if [ -f "$AGENT_FILE" ] && grep -q "= SettingsDict\['protected_settings'\]" "$AGENT_FILE"; then
                sed -i "s/= SettingsDict\['protected_settings'\]/= SettingsDict.get('protected_settings')/" "$AGENT_FILE"
                find "$amadir" -name 'agent*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched agent.py SettingsDict protected_settings KeyError in $amadir"
              fi

              # Patch 6: Guard HUtilObject._context._seq_no and .save_seq() against None
              # Without WALinuxAgent, HUtilObject is None; the else branch at enable() line ~935
              # and save_seq() at line ~966 crash with AttributeError
              # Check for unpatched form: "+ HUtilObject._context._seq_no +" (not wrapped in parens)
              if [ -f "$AGENT_FILE" ] && grep -q '"+ HUtilObject\._context\._seq_no +"' "$AGENT_FILE"; then
                sed -i 's/"+ HUtilObject\._context\._seq_no +"/"+ (HUtilObject._context._seq_no if HUtilObject and HUtilObject._context else "N\/A") +"/g' "$AGENT_FILE"
                PATCHED=1
                echo "Patched agent.py HUtilObject._context._seq_no guards in $amadir"
              fi
              if [ -f "$AGENT_FILE" ] && grep -qP '^\s+HUtilObject\.save_seq\(\)' "$AGENT_FILE"; then
                sed -i 's/^\(\s*\)HUtilObject\.save_seq()/\1if HUtilObject: HUtilObject.save_seq()/' "$AGENT_FILE"
                find "$amadir" -name 'agent*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched agent.py HUtilObject.save_seq() guard in $amadir"
              fi
            done

            # Patch 4: Set SSL cert paths in /etc/default/azuremonitoragent
            # AMA needs these to make TLS connections; NixOS stores certs at /etc/ssl/certs/
            AMA_DEFAULT="/var/opt/azcmagent/etc-default/azuremonitoragent"
            if [ -d "/var/opt/azcmagent/etc-default" ] && ! grep -q 'SSL_CERT_DIR=/etc/ssl/certs' "$AMA_DEFAULT" 2>/dev/null; then
              cat > "$AMA_DEFAULT" << 'SSLEOF'
export SSL_CERT_DIR=/etc/ssl/certs
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
SSLEOF
              PATCHED=1
              echo "Set SSL cert paths in $AMA_DEFAULT"
            fi

            [ "$PATCHED" = "1" ] && echo "AMA patches applied" || echo "No AMA patches needed"
          '';
        in patchScript;
      };
    };

    systemd.timers.arc-ama-patcher = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "30s";
      };
    };

    # MDE extension patcher — patches mde_installer.sh for NixOS compatibility
    systemd.services.arc-mde-patcher = {
      description = "Patch MDE extension for NixOS compatibility";
      after = [ "extd.service" ];
      path = [ pkgs.gnused pkgs.gnugrep pkgs.coreutils pkgs.findutils ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = let
          patchScript = pkgs.writeShellScript "arc-mde-patch" ''
            WAAGENT=/var/lib/waagent
            PATCHED=0

            # Register MDE prerequisites in dpkg database so the installer
            # skips 'apt install' for packages already in the FHS sandbox.
            DPKG_STATUS=/var/opt/azcmagent/dpkg-db/status
            if [ -f "$DPKG_STATUS" ]; then
              for pkg in curl gnupg apt-transport-https; do
                if ! grep -q "^Package: $pkg$" "$DPKG_STATUS" 2>/dev/null; then
                  cat >> "$DPKG_STATUS" <<DPKG_EOF

Package: $pkg
Status: install ok installed
Priority: optional
Section: utils
Architecture: all
Version: 1.0.0-nixos
Description: Provided by NixOS FHS sandbox

DPKG_EOF
                  echo "Registered $pkg in dpkg database"
                  PATCHED=1
                fi
              done
            fi

            for mdedir in "$WAAGENT"/Microsoft.Azure.AzureDefenderForServers.MDE.Linux-*/; do
              [ -d "$mdedir" ] || continue
              INSTALLER="$mdedir/src/mde_installer.sh"
              [ -f "$INSTALLER" ] || continue

              # Patch 1: Add nixos to distro family detection
              # Map nixos to debian family (we have dpkg/apt in the FHS sandbox)
              if grep -q '"unsupported distro \$DISTRO \$VERSION"' "$INSTALLER" && \
                 ! grep -q 'DISTRO_FAMILY="debian" # nixos' "$INSTALLER"; then
                sed -i '/elif \[ "\$DISTRO" = "sles" \]/i\    elif [ "$DISTRO" = "nixos" ]; then\n        DISTRO_FAMILY="debian" # nixos' "$INSTALLER"
                PATCHED=1
                echo "Patched mde_installer.sh distro detection in $mdedir"
              fi

              # Patch 2: Map nixos to ubuntu for PMC repo URL
              # The installer fetches packages from packages.microsoft.com/config/$DISTRO/$VERSION
              # NixOS doesn't have a repo there, so we use ubuntu/24.04 (closest match)
              if ! grep -q 'DISTRO="ubuntu" # nixos' "$INSTALLER"; then
                sed -i '/DISTRO_FAMILY="debian" # nixos/a\        DISTRO="ubuntu" # nixos\n        SCALED_VERSION="24.04" # nixos\n        VERSION="24.04" # nixos' "$INSTALLER"
                PATCHED=1
                echo "Patched mde_installer.sh nixos->ubuntu repo mapping in $mdedir"
              fi
            done

            # Patch 3: Set SSL_CERT_FILE and force bundled installer script
            # The MdeInstallerWrapper.py uses urllib which needs SSL certs.
            # Also set MdeExtensionDebugMode=true to use bundled (patched) mde_installer.sh
            # instead of downloading latest from GitHub (which would be unpatched).
            WRAPPER_RUNNER="$WAAGENT"/Microsoft.Azure.AzureDefenderForServers.MDE.Linux-*/PythonRunner.sh
            for runner in $WRAPPER_RUNNER; do
              [ -f "$runner" ] || continue
              if ! grep -q 'SSL_CERT_FILE' "$runner"; then
                sed -i '2i export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt\nexport SSL_CERT_DIR=/etc/ssl/certs\nexport MdeExtensionDebugMode=true' "$runner"
                PATCHED=1
                echo "Patched PythonRunner.sh SSL certs + debug mode in $(dirname "$runner")"
              elif ! grep -q 'MdeExtensionDebugMode' "$runner"; then
                sed -i '/SSL_CERT_FILE/a export MdeExtensionDebugMode=true' "$runner"
                PATCHED=1
                echo "Patched PythonRunner.sh debug mode in $(dirname "$runner")"
              fi
            done

            # Patch 4: Fix publicSettings None check in MdeExtensionHandler.py
            # On Arc (no WALinuxAgent), publicSettings key exists but is None.
            # "in None" throws TypeError. Add None guard in 3 locations.
            for mdedir in "$WAAGENT"/Microsoft.Azure.AzureDefenderForServers.MDE.Linux-*/; do
              [ -d "$mdedir" ] || continue
              HANDLER="$mdedir/src/MdeExtensionHandler.py"
              [ -f "$HANDLER" ] || continue

              # 4a: get_parameter_from_public_settings (line ~86)
              if grep -q 'or parameterName not in handlerSettings\["publicSettings"\]' "$HANDLER" && \
                 ! grep -q 'handlerSettings\["publicSettings"\] is None' "$HANDLER"; then
                sed -i 's|or parameterName not in handlerSettings\["publicSettings"\]|or handlerSettings["publicSettings"] is None or parameterName not in handlerSettings["publicSettings"]|' "$HANDLER"
                PATCHED=1
                echo "Patched MdeExtensionHandler.py publicSettings None guard (get_parameter) in $mdedir"
              fi

              # 4b: get_security_workspace_id (line ~142)
              if grep -q 'or SecurityWorkspaceIdParameterName not in handlerSettings\["publicSettings"\]' "$HANDLER" && \
                 ! grep -q 'handlerSettings\["publicSettings"\] is None or SecurityWorkspaceIdParameterName' "$HANDLER"; then
                sed -i 's|or SecurityWorkspaceIdParameterName not in handlerSettings\["publicSettings"\]|or handlerSettings["publicSettings"] is None or SecurityWorkspaceIdParameterName not in handlerSettings["publicSettings"]|' "$HANDLER"
                PATCHED=1
                echo "Patched MdeExtensionHandler.py publicSettings None guard (workspace_id) in $mdedir"
              fi

              # 4c: get_parameter_from_protected_settings (line ~98)
              if grep -q 'or parameterName not in handlerSettings\["protectedSettings"\]' "$HANDLER" && \
                 ! grep -q 'handlerSettings\["protectedSettings"\] is None' "$HANDLER"; then
                sed -i 's|or parameterName not in handlerSettings\["protectedSettings"\]|or handlerSettings["protectedSettings"] is None or parameterName not in handlerSettings["protectedSettings"]|' "$HANDLER"
                PATCHED=1
                echo "Patched MdeExtensionHandler.py protectedSettings None guard in $mdedir"
              fi

              # 4d: Skip publicSettings empty check in provision_extension (line ~181)
              # On Arc, publicSettings is None but all downstream accessors have defaults.
              # Replace the fatal check with a pass-through so enable proceeds.
              if grep -q 'throw_and_write_log("Public settings configuration is empty")' "$HANDLER"; then
                sed -i 's|logutils.throw_and_write_log("Public settings configuration is empty")|pass  # NixOS: skip, downstream has defaults|' "$HANDLER"
                PATCHED=1
                echo "Patched MdeExtensionHandler.py: disabled publicSettings empty check in $mdedir"
              fi
            done

            [ "$PATCHED" = "1" ] && echo "MDE patches applied" || echo "No MDE patches needed"
          '';
        in patchScript;
      };
    };

    systemd.timers.arc-mde-patcher = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "10s";
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
