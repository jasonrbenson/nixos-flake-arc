{ lib
, stdenv
, fetchurl
, dpkg
, buildFHSEnv
, writeShellScript
, openssl
, zlib
, glibc
, icu
, curl
, lttng-ust
, systemd
, libgcc
, apt
, agentVersion
, agentSource
}:

let
  # Extract the agent from the DEB package
  azcmagent-unwrapped = stdenv.mkDerivation rec {
    pname = "azcmagent-unwrapped";
    version = agentVersion;

    src = fetchurl {
      inherit (agentSource) url sha256;
    };

    nativeBuildInputs = [ dpkg ];

    dontBuild = true;
    dontConfigure = true;

    unpackPhase = ''
      dpkg-deb -x $src .
    '';

    installPhase = ''
      mkdir -p $out

      # Core agent binaries (statically linked Go — no patching needed)
      cp -r opt/azcmagent $out/azcmagent

      # Guest Configuration service (dynamically linked — needs FHS or patching)
      cp -r opt/GC_Ext $out/GC_Ext
      cp -r opt/GC_Service $out/GC_Service

      # Simple manifest
      find $out -type f | sort > $out/MANIFEST.txt
    '';

    meta = with lib; {
      description = "Azure Arc Connected Machine Agent (extracted, unwrapped)";
      homepage = "https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview";
      license = licenses.unfree;
      platforms = [ "x86_64-linux" "aarch64-linux" ];
    };
  };

  # Passthrough wrapper: exec whatever command is passed as arguments.
  # This lets systemd services and users run arbitrary binaries inside the
  # FHS namespace, e.g.  azcmagent-fhs /opt/azcmagent/bin/himds
  # For agent binaries: cd to binary's dir so RPATH "." resolves co-located .so files
  # For extension binaries (/var/lib/waagent/...): preserve systemd WorkingDirectory
  # (bwrap --chdir already set CWD to the extension root via systemd's WorkingDirectory)
  execWrapper = writeShellScript "azcmagent-exec" ''
    export SYSTEMD_IGNORE_CHROOT=1
    # Ensure /usr/bin is first in PATH so our sudo wrapper (no-PAM passthrough)
    # is found before /run/wrappers/bin/sudo (NixOS setuid wrapper that needs PAM)
    export PATH="/usr/bin:/usr/sbin:$PATH"
    case "$1" in
      /var/lib/waagent/*) ;; # extension binary — keep CWD from systemd WorkingDirectory
      *) cd "$(dirname "$1")" 2>/dev/null || true ;;
    esac
    exec "$@"
  '';

  # FHS environment for the full agent stack
  #
  # Why FHS? The core agent binaries (himds, arcproxy, azcmagent_executable) are
  # statically linked Go and could run without FHS. However:
  #   1. The GC components (gc_worker, gc_linux_service) are dynamically linked
  #   2. Extensions download and execute inside /opt/GC_Ext/
  #   3. Shell scripts reference /opt/azcmagent/ paths
  #   4. The postinst scripts write systemd units to /lib/systemd/system/
  #
  # The FHS env provides a consistent runtime for all components.
  azcmagent-fhs = buildFHSEnv {
    name = "azcmagent-fhs";

    targetPkgs = pkgs: [
      # Required by GC components (dynamically linked C/C++/.NET)
      pkgs.openssl
      pkgs.zlib
      pkgs.glibc
      pkgs.icu
      pkgs.curl
      pkgs.lttng-ust
      pkgs.systemd
      pkgs.libgcc.lib
      # libstdc++.so.6 needed by gc_linux_service and gc_worker
      pkgs.stdenv.cc.cc.lib
      # libpam.so.0 needed by GC components
      pkgs.linux-pam
      # gpg needed by extension package signature validation
      pkgs.gnupg
      # Python 3 needed by extensions (AMA, etc.)
      pkgs.python3
      # dpkg needed by AMA to install its internal azuremonitoragent package
      pkgs.dpkg
      # apt needed by MDE installer to set up Microsoft repo and install mdatp
      pkgs.apt
      # iptables needed by mdatp (Microsoft Defender) for network filtering
      pkgs.iptables
      # util-linux needed by mdatp's dpkg scripts (logger, mount commands)
      pkgs.util-linux
      # Libraries needed by mdatp daemon (wdavdaemon)
      pkgs.libcap       # libcap.so.2
      pkgs.pcre2        # libpcre2-8.so.0, libpcre2-posix.so.3
      pkgs.acl          # libacl.so.1
      pkgs.sqlite       # libsqlite3.so.0
    ];

    extraBuildCommands = ''
      # extraBuildCommands runs in a temp build dir, not $out.
      # All paths must be prefixed with $out to land in the rootfs.

      # Core agent → /opt/azcmagent/
      mkdir -p $out/opt/azcmagent
      cp -r ${azcmagent-unwrapped}/azcmagent/* $out/opt/azcmagent/

      # Extension Manager → /opt/GC_Ext/
      mkdir -p $out/opt/GC_Ext
      cp -r ${azcmagent-unwrapped}/GC_Ext/* $out/opt/GC_Ext/

      # Guest Configuration → /opt/GC_Service/
      mkdir -p $out/opt/GC_Service
      cp -r ${azcmagent-unwrapped}/GC_Service/* $out/opt/GC_Service/

      # AMA install target — empty directory, filled by dpkg at runtime
      mkdir -p $out/opt/microsoft

      # AMA config directory (bwrap has tmpfs /etc, so this is writable)
      mkdir -p $out/etc/opt/microsoft/azuremonitoragent
      mkdir -p $out/etc/default
      mkdir -p $out/etc/logrotate.d

      # Mount point for writable /usr/share/lintian (AMA's deb installs overrides here)
      mkdir -p $out/usr/share/lintian

      # APT infrastructure for MDE package installation.
      # The rootfs provides the skeleton; writable bind-mounts overlay these
      # paths so MDE can add Microsoft's repo, GPG keys, and install mdatp.
      mkdir -p $out/etc/apt/sources.list.d
      mkdir -p $out/etc/apt/apt.conf.d
      mkdir -p $out/etc/apt/trusted.gpg.d
      mkdir -p $out/etc/apt/preferences.d
      touch $out/etc/apt/sources.list

      # GPG keyrings directory (MDE stores microsoft-prod.gpg here)
      mkdir -p $out/usr/share/keyrings

      # Override apt/apt-get/apt-cache with wrappers that redirect compiled-in
      # nix store paths to standard FHS locations. Nix's apt binary hardcodes
      # Dir::Etc to /nix/store/...-apt/etc/apt/ which is empty; we override
      # to /etc/apt/ (bind-mounted writable from host).
      for cmd in apt apt-get apt-cache apt-key; do
        if [ -e "$out/usr/bin/$cmd" ]; then
          rm -f "$out/usr/bin/$cmd"
          tee "$out/usr/bin/$cmd" > /dev/null <<APT_WRAPPER
#!/usr/bin/env bash
exec ${apt}/bin/$cmd \
  -o Dir::Etc="/etc/apt" \
  -o Dir::State="/var/lib/apt" \
  -o Dir::Cache="/var/cache/apt" \
  -o Dir::Log="/var/log/apt" \
  -o Dir::Bin::dpkg="/usr/bin/dpkg" \
  "\$@"
APT_WRAPPER
          chmod 755 "$out/usr/bin/$cmd"
        fi
      done

      # State directories (/var) are NOT placed here because the bwrap
      # rootfs is read-only. Instead, the host's /var is auto-mounted
      # read-write, and systemd.tmpfiles.rules (in the NixOS module)
      # create the needed directories on the host filesystem.
      mkdir -p $out/etc/bash_completion.d

      # sudo wrapper: inside bwrap, processes run as root already.
      # Extensions use sudo (e.g. 'sudo gpg --dearmor') which fails because
      # PAM is not configured in the sandbox. This wrapper just exec's the cmd.
      cat > $out/usr/bin/sudo <<'SUDO_WRAPPER'
#!/usr/bin/env bash
# NixOS FHS sandbox: already running as root, skip PAM auth
# Handle common sudo flags
while [ $# -gt 0 ]; do
  case "$1" in
    -E|-H|-n|-S|--preserve-env) shift ;;
    -u) shift; shift ;;  # skip -u <user>
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
SUDO_WRAPPER
      chmod 755 $out/usr/bin/sudo

      # Agent needs systemctl/journalctl for service health checks.
      # targetPkgs provides systemd libs but not the binaries in PATH.
      # The systemctl wrapper adds --runtime to enable/disable so that
      # symlinks land in /run/systemd/system/ (writable) instead of
      # /etc/systemd/system/ (read-only nix store on the host).
      mkdir -p $out/usr/bin
      ln -sf ${systemd}/bin/journalctl $out/usr/bin/journalctl
      ln -sf ${systemd}/bin/systemctl $out/usr/bin/systemctl

      # Override systemctl: remove the symlink, replace with wrapper script.
      # This wrapper handles two NixOS-specific issues for extensions:
      #
      # 1. enable/disable: Adds --runtime so symlinks go to /run/systemd/system/
      #    instead of /etc/systemd/system/ (read-only nix store on NixOS).
      #
      # 2. daemon-reload: Before reloading, scans /run/systemd/system/ for
      #    extension-created unit files whose ExecStart points at a dynamically
      #    linked binary in /var/lib/waagent/. These binaries need the FHS
      #    sandbox to run, so the wrapper prepends azcmagent-fhs to ExecStart.
      #    This is the generalized fix for Gap 11 — any extension that creates
      #    a long-running systemd service will automatically be FHS-wrapped.
      rm $out/usr/bin/systemctl
      tee $out/usr/bin/systemctl > /dev/null <<'SYSTEMCTL_WRAPPER'
#!/usr/bin/env bash
REAL=REAL_SYSTEMCTL_PLACEHOLDER
FHS=/run/current-system/sw/bin/azcmagent-fhs

patch_extension_units() {
  for unit in /run/systemd/system/*.service; do
    [ -f "$unit" ] || continue
    # Patch units with ExecStart in /var/lib/waagent/ or /opt/microsoft/ (extension binaries)
    grep -qE '^ExecStart=(/var/lib/waagent/|/opt/microsoft/)' "$unit" || continue
    # Skip if already wrapped
    grep -q 'azcmagent-fhs' "$unit" || {
      # Create a temp file with patched ExecStart and WorkingDirectory
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          ExecStart=/var/lib/waagent/*|ExecStart=/opt/microsoft/*)
            echo "ExecStart=$FHS ''${line#ExecStart=}" ;;
          WorkingDirectory=/opt/*|WorkingDirectory=/var/lib/waagent/*)
            # Paths inside bwrap don't exist on host; use / instead
            echo "WorkingDirectory=/" ;;
          *)
            echo "$line" ;;
        esac
      done < "$unit" > "$unit.tmp"
      mv "$unit.tmp" "$unit"
    }
  done
}

case "$1" in
  enable|disable)
    cmd="$1"; shift
    exec "$REAL" "$cmd" --runtime "$@"
    ;;
  daemon-reload)
    patch_extension_units
    exec "$REAL" daemon-reload
    ;;
  *)
    exec "$REAL" "$@"
    ;;
esac
SYSTEMCTL_WRAPPER
      # The heredoc is single-quoted so bash doesn't expand variables.
      # Replace the placeholder with the actual nix store path.
      sed -i "s|REAL_SYSTEMCTL_PLACEHOLDER|${systemd}/bin/systemctl|" $out/usr/bin/systemctl
      chmod 755 $out/usr/bin/systemctl
    '';

    # Bind writable host directories over the read-only /opt paths.
    # The NixOS module creates these dirs and pre-populates from the package.
    # bwrap processes args in order; these --bind args come AFTER the
    # --ro-bind of /opt from the rootfs, so they overlay correctly.
    extraBwrapArgs = [
      "--bind /var/opt/azcmagent/opt-azcmagent /opt/azcmagent"
      "--bind /var/opt/azcmagent/opt-gc-ext /opt/GC_Ext"
      "--bind /var/opt/azcmagent/opt-gc-service /opt/GC_Service"
      # Writable /opt/microsoft/ for AMA dpkg install (azuremonitoragent package)
      "--bind /var/opt/azcmagent/opt-microsoft /opt/microsoft"
      # Writable dpkg database — AMA's install runs dpkg -i inside the sandbox
      "--bind /var/opt/azcmagent/dpkg-db /var/lib/dpkg"
      # Writable /etc/opt/microsoft/ for AMA config files installed by dpkg.
      # The rootfs creates /etc/opt/microsoft/ which bwrap bind-mounts read-only
      # from the nix store. This explicit --bind (appended AFTER auto-generated
      # args) shadows the read-only mount with a writable host directory.
      "--bind /etc/opt/microsoft /etc/opt/microsoft"
      # Writable /etc/default/ and /etc/logrotate.d/ — AMA's dpkg writes config
      # files here and the postinst script uses sed -i on /etc/default/azuremonitoragent.
      "--bind /var/opt/azcmagent/etc-default /etc/default"
      "--bind /var/opt/azcmagent/etc-logrotate-d /etc/logrotate.d"
      # Writable /usr/share/lintian/ — AMA's deb installs a lintian overrides file.
      "--bind /var/opt/azcmagent/usr-share-lintian /usr/share/lintian"
      # Writable /etc/apt/ — MDE installer adds Microsoft repo and GPG keys here.
      "--bind /var/opt/azcmagent/etc-apt /etc/apt"
      # Writable /usr/share/keyrings/ — MDE stores microsoft-prod.gpg here.
      "--bind /var/opt/azcmagent/usr-share-keyrings /usr/share/keyrings"
      # Extensions (e.g. KeyVault) write systemd units to /etc/systemd/system.
      # NixOS /etc/systemd/system is read-only (nix store). Redirect writes to
      # /run/systemd/system which is writable AND in systemd's unit search path,
      # so daemon-reload + enable work correctly through D-Bus to host PID 1.
      "--dir /etc/systemd"
      "--symlink /run/systemd/system /etc/systemd/system"
    ];

    runScript = execWrapper;
  };

in
{
  # The unwrapped extracted package (for inspection / debugging)
  unwrapped = azcmagent-unwrapped;

  # The full FHS-wrapped package (for running the agent)
  fhs = azcmagent-fhs;

  # Default: expose the FHS-wrapped agent with passthru for module access
  default = azcmagent-fhs // {
    passthru = { unwrapped = azcmagent-unwrapped; };
  };
}
