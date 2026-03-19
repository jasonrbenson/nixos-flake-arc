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
  # cd to the binary's directory first so RPATH "." resolves co-located .so files
  execWrapper = writeShellScript "azcmagent-exec" ''
    export SYSTEMD_IGNORE_CHROOT=1
    cd "$(dirname "$1")" 2>/dev/null || true
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

      # State directories (/var) are NOT placed here because the bwrap
      # rootfs is read-only. Instead, the host's /var is auto-mounted
      # read-write, and systemd.tmpfiles.rules (in the NixOS module)
      # create the needed directories on the host filesystem.
      mkdir -p $out/etc/bash_completion.d

      # Agent needs systemctl/journalctl for service health checks.
      # targetPkgs provides systemd libs but not the binaries in PATH.
      # The systemctl wrapper adds --runtime to enable/disable so that
      # symlinks land in /run/systemd/system/ (writable) instead of
      # /etc/systemd/system/ (read-only nix store on the host).
      mkdir -p $out/usr/bin
      ln -sf ${systemd}/bin/journalctl $out/usr/bin/journalctl
      cat > $out/usr/bin/systemctl <<'WRAPPER'
#!/bin/bash
REAL_SYSTEMCTL="${systemd}/bin/systemctl"
case "$1" in
  enable|disable)
    cmd="$1"; shift
    exec "$REAL_SYSTEMCTL" "$cmd" --runtime "$@"
    ;;
  *)
    exec "$REAL_SYSTEMCTL" "$@"
    ;;
esac
WRAPPER
      chmod +x $out/usr/bin/systemctl
    '';

    # Bind writable host directories over the read-only /opt paths.
    # The NixOS module creates these dirs and pre-populates from the package.
    # bwrap processes args in order; these --bind args come AFTER the
    # --ro-bind of /opt from the rootfs, so they overlay correctly.
    extraBwrapArgs = [
      "--bind /var/opt/azcmagent/opt-azcmagent /opt/azcmagent"
      "--bind /var/opt/azcmagent/opt-gc-ext /opt/GC_Ext"
      "--bind /var/opt/azcmagent/opt-gc-service /opt/GC_Service"
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
