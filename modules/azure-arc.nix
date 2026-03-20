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

    # MDE (mdatp) daemon runs as the mdatp user (created by dpkg preinst).
    # Pre-creating in NixOS because useradd fails inside read-only bwrap sandbox.
    users.users.mdatp = {
      isSystemUser = true;
      group = "mdatp";
      home = "/var/opt/microsoft/mdatp";
      shell = "/usr/sbin/nologin";
      description = "Microsoft Defender for Endpoint service user";
    };
    users.groups.mdatp = { };

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

      # APT support: top-level writable directories for MDE's apt-based mdatp
      # installation. Subdirectories are created by arc-mde-patcher (runs as root)
      # because tmpfiles refuses to traverse the himds→root ownership boundary.
      "d /var/opt/azcmagent/etc-apt 0755 root root -"
      "d /var/opt/azcmagent/usr-share-keyrings 0755 root root -"
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
        TimeoutStartSec = 45;
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
        TimeoutStartSec = 45;
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
              # Without WALinuxAgent, HUtilObject._context is None on Arc, causing
              # AttributeError at the seq_no access. Use flexible patterns that
              # match regardless of whitespace around + operators.
              if [ -f "$AGENT_FILE" ] && grep -q 'HUtilObject\._context\._seq_no' "$AGENT_FILE" && \
                 ! grep -q 'HUtilObject and HUtilObject._context' "$AGENT_FILE"; then
                # Replace all occurrences of HUtilObject._context._seq_no with a safe accessor
                sed -i 's/HUtilObject\._context\._seq_no/(HUtilObject._context._seq_no if HUtilObject and HUtilObject._context else "N\/A")/g' "$AGENT_FILE"
                find "$amadir" -name 'agent*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched agent.py HUtilObject._context._seq_no guards in $amadir"
              fi
              if [ -f "$AGENT_FILE" ] && grep -qP '^\s+HUtilObject\.save_seq\(\)' "$AGENT_FILE"; then
                sed -i 's/^\(\s*\)HUtilObject\.save_seq()/\1if HUtilObject: HUtilObject.save_seq()/' "$AGENT_FILE"
                find "$amadir" -name 'agent*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched agent.py HUtilObject.save_seq() guard in $amadir"
              fi
              # Patch 6c: Redirect IMDS endpoint config path.
              # AMA reads /lib/systemd/system.conf.d/azcmagent.conf for the Arc IMDS proxy.
              # In the FHS sandbox, /lib is a symlink and that path doesn't exist.
              # Redirect to /opt/azcmagent/datafiles/azcmagent.conf which already has the
              # correct IMDS_ENDPOINT and IDENTITY_ENDPOINT values from the agent package.
              if [ -f "$AGENT_FILE" ] && grep -q "/lib/systemd/system.conf.d/azcmagent.conf" "$AGENT_FILE"; then
                sed -i "s|/lib/systemd/system.conf.d/azcmagent.conf|/opt/azcmagent/datafiles/azcmagent.conf|g" "$AGENT_FILE"
                find "$amadir" -name 'agent*.pyc' -delete 2>/dev/null || true
                PATCHED=1
                echo "Patched IMDS endpoint config path in $amadir"
              fi
            done

            # Patch 7: Set SSL cert paths in /etc/default/azuremonitoragent
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

            # Auto-retry: If we applied patches and the extension is in a failed state,
            # reset the state file so the extension manager will retry the enable.
            if [ "$PATCHED" = "1" ]; then
              for statefile in /var/lib/GuestConfig/extension_logs/Microsoft.Azure.Monitor.AzureMonitorLinuxAgent-*/state.json; do
                [ -f "$statefile" ] || continue
                if grep -q '"ExtensionState":"INSTALLED"' "$statefile" && grep -q '"ErrorMsg"' "$statefile"; then
                  # Reset SequenceNumberFinished to allow re-enable
                  sed -i 's/"SequenceNumberFinished":[0-9-]*/"SequenceNumberFinished":-1/' "$statefile"
                  # Clear the error to unblock
                  sed -i 's/"EnableEndTelemetrySent":true/"EnableEndTelemetrySent":false/' "$statefile"
                  echo "Reset AMA state file for retry: $statefile"
                fi
              done
              echo "AMA patches applied — extension should retry on next poll"
            else
              echo "No AMA patches needed"
            fi
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

            # Ensure apt directory structure exists on host (tmpfiles can't
            # create children under himds-owned /var/opt/azcmagent/).
            mkdir -p /var/opt/azcmagent/etc-apt/{sources.list.d,apt.conf.d,trusted.gpg.d,preferences.d}
            touch /var/opt/azcmagent/etc-apt/sources.list
            mkdir -p /var/opt/azcmagent/usr-share-keyrings
            mkdir -p /var/cache/apt/archives/partial
            mkdir -p /var/lib/apt/lists/partial
            mkdir -p /var/log/apt

            # MDE (mdatp) needs writable dirs for install scripts
            mkdir -p /etc/opt/microsoft/mdatp/tmp
            mkdir -p /var/opt/microsoft/mdatp
            mkdir -p /var/log/microsoft/mdatp

            # Force dpkg to continue past script errors (e.g., postinst ln -sf to
            # read-only /usr/bin/ fails). The mdatp binary is installed to
            # /opt/microsoft/mdatp/ which IS writable.
            if [ ! -f /var/opt/azcmagent/etc-apt/apt.conf.d/99force-scripts.conf ]; then
              cat > /var/opt/azcmagent/etc-apt/apt.conf.d/99force-scripts.conf <<'APTCONF'
Dpkg::Options { "--force-confnew"; "--force-overwrite"; };
APTCONF
            fi

            if [ -f "$DPKG_STATUS" ]; then
              for pkg in curl gnupg apt-transport-https libc6 ucf debianutils logrotate iptables; do
                if ! grep -q "^Package: $pkg$" "$DPKG_STATUS" 2>/dev/null; then
                  # Use a high version number so apt dependency checks pass
                  # (e.g., azuremonitoragent Depends: libc6 (>= 2.9))
                  cat >> "$DPKG_STATUS" <<DPKG_EOF

Package: $pkg
Status: install ok installed
Priority: optional
Section: utils
Maintainer: NixOS FHS Sandbox
Architecture: all
Version: 99.0.0-nixos
Description: Provided by NixOS FHS sandbox

DPKG_EOF
                  echo "Registered $pkg in dpkg database"
                  PATCHED=1
                fi
              done

              # Fix azureotelcollector half-installed state (AMA leftover)
              if grep -q 'Status: install reinstreq half-installed' "$DPKG_STATUS" 2>/dev/null; then
                sed -i 's/Status: install reinstreq half-installed/Status: purge ok not-installed/' "$DPKG_STATUS"
                echo "Fixed azureotelcollector half-installed state"
                PATCHED=1
              fi
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

            # Patch 5: Replace apt install mdatp with NixOS-safe install
            # The mdatp postinst is 3000+ lines and writes to many read-only FHS paths
            # (/usr/bin/, /lib/systemd/system/, /etc/rsyslog.d/, etc).
            # Instead: dpkg --unpack (extract files only) + manual essential setup.
            for mdedir in "$WAAGENT"/Microsoft.Azure.AzureDefenderForServers.MDE.Linux-*/; do
              [ -d "$mdedir" ] || continue
              INSTALLER="$mdedir/src/mde_installer.sh"
              [ -f "$INSTALLER" ] || continue

              if ! grep -q '# --- NixOS Patch 5:' "$INSTALLER"; then
                NEED_PATCH5=1
              elif grep -q 'dpkg --unpack' "$INSTALLER"; then
                # Upgrade: old patcher used dpkg --unpack which fails on x86_64
                # Remove old function so we can re-inject with dpkg-deb -x
                sed -i '/# --- NixOS Patch 5:/,/# --- End NixOS Patch 5 ---/d' "$INSTALLER"
                NEED_PATCH5=1
                echo "Upgrading MDE install function (dpkg --unpack -> dpkg-deb -x) in $mdedir"
              elif ! grep -q 'Waiting for mdatp daemon' "$INSTALLER"; then
                # Upgrade: add daemon readiness wait loop
                sed -i '/# --- NixOS Patch 5:/,/# --- End NixOS Patch 5 ---/d' "$INSTALLER"
                NEED_PATCH5=1
                echo "Upgrading MDE install function (adding daemon readiness wait) in $mdedir"
              else
                NEED_PATCH5=0
              fi

              if [ "$NEED_PATCH5" = "1" ]; then
                # Define the NixOS install function near the top of the file
                sed -i '2i\
# --- NixOS Patch 5: custom mdatp install function ---\
nixos_install_mdatp() {\
    echo "[NixOS] Downloading mdatp package..."\
    apt-get -d -y install mdatp 2>&1 || true\
    local deb=$(find /var/cache/apt/archives -name "mdatp_*.deb" -type f | head -1)\
    if [ -z "$deb" ]; then\
        echo "[NixOS] ERROR: mdatp .deb not found in cache"\
        return 1\
    fi\
    echo "[NixOS] Extracting $deb (bypassing preinst/postinst scripts)..."\
    dpkg-deb -x "$deb" / 2>&1 || true\
    if [ ! -f /opt/microsoft/mdatp/sbin/wdavdaemon ]; then\
        echo "[NixOS] ERROR: dpkg-deb extraction failed — wdavdaemon not found"\
        return 1\
    fi\
    echo "[NixOS] Extraction verified — wdavdaemon present"\
    echo "[NixOS] Manual setup..."\
    mkdir -p /opt/microsoft/mdatp/bin\
    mkdir -p /var/opt/microsoft/mdatp/{definitions.noindex/00000000-0000-0000-0000-000000000000,crash,quarantine,signatures.noindex}\
    mkdir -p /etc/opt/microsoft/mdatp/{managed,tmp}\
    mkdir -p /var/log/microsoft/mdatp\
    ln -sf /opt/microsoft/mdatp/sbin/wdavdaemonclient /opt/microsoft/mdatp/bin/mdatp\
    cp /opt/microsoft/mdatp/definitions/libmpengine.so /var/opt/microsoft/mdatp/definitions.noindex/00000000-0000-0000-0000-000000000000/ 2>/dev/null || true\
    cp /opt/microsoft/mdatp/definitions/libmpengine.so.sig /var/opt/microsoft/mdatp/definitions.noindex/00000000-0000-0000-0000-000000000000/ 2>/dev/null || true\
    cp /opt/microsoft/mdatp/definitions/mp*.vdm /var/opt/microsoft/mdatp/definitions.noindex/00000000-0000-0000-0000-000000000000/ 2>/dev/null || true\
    chmod 755 /opt/microsoft/mdatp/sbin/wdavdaemon /opt/microsoft/mdatp/sbin/wdavdaemonclient\
    chown -R mdatp:mdatp /var/opt/microsoft/mdatp 2>/dev/null || true\
    chmod -R 755 /var/opt/microsoft/mdatp\
    cp /opt/microsoft/mdatp/conf/mdatp.service /run/systemd/system/mdatp.service\
    sed -i "s|^WorkingDirectory=.*|WorkingDirectory=/|" /run/systemd/system/mdatp.service\
    chmod 0644 /run/systemd/system/mdatp.service\
    cp /opt/microsoft/mdatp/conf/mde_netfilter_v2.socket /run/systemd/system/ 2>/dev/null || true\
    cp /opt/microsoft/mdatp/conf/mde_netfilter_v2.service /run/systemd/system/ 2>/dev/null || true\
    local mdatp_ver=$(dpkg-deb -f "$deb" Version 2>/dev/null || echo "0.0.0")\
    if grep -q "^Package: mdatp$" /var/lib/dpkg/status 2>/dev/null; then\
        sed -i "/^Package: mdatp$/,/^$/s/^Status:.*/Status: install ok installed/" /var/lib/dpkg/status\
        sed -i "/^Package: mdatp$/,/^$/s/^Version:.*/Version: $mdatp_ver/" /var/lib/dpkg/status\
        echo "[NixOS] Updated mdatp dpkg status to installed ($mdatp_ver)"\
    else\
        cat >> /var/lib/dpkg/status <<MDATP_REG\
\
Package: mdatp\
Status: install ok installed\
Priority: optional\
Section: utils\
Maintainer: Microsoft Corporation\
Architecture: amd64\
Version: $mdatp_ver\
Description: Microsoft Defender for Endpoint\
\
MDATP_REG\
        echo "[NixOS] Registered mdatp $mdatp_ver in dpkg status"\
    fi\
    systemctl daemon-reload\
    systemctl enable --runtime mdatp.service 2>/dev/null || true\
    systemctl start mdatp.service 2>/dev/null || true\
    echo "[NixOS] Waiting for mdatp daemon to start..."\
    local ready=0\
    for i in $(seq 1 30); do\
        if mdatp health > /dev/null 2>&1; then\
            ready=1\
            break\
        fi\
        sleep 2\
    done\
    if [ "$ready" = "1" ]; then\
        echo "[NixOS] mdatp daemon is ready"\
    else\
        echo "[NixOS] mdatp daemon not ready yet (may need more time)"\
    fi\
    echo "[NixOS] mdatp install complete"\
    return 0\
}\
# --- End NixOS Patch 5 ---' "$INSTALLER"

                # Replace all $PKG_MGR_INVOKER install mdatp lines with our function
                sed -i 's|run_quietly "$PKG_MGR_INVOKER install mdatp$version"|nixos_install_mdatp|g' "$INSTALLER"
                sed -i 's|run_quietly "$PKG_MGR_INVOKER -t $VERSION_NAME install mdatp$version"|nixos_install_mdatp|g' "$INSTALLER"
                sed -i 's|run_quietly "$PKG_MGR_INVOKER -t $CHANNEL install mdatp$version"|nixos_install_mdatp|g' "$INSTALLER"

                PATCHED=1
                echo "Patched mde_installer.sh with NixOS mdatp install function in $mdedir"
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
