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
      mkdir -p $out/usr/bin
      ln -sf ${pkgs.systemd}/bin/systemctl $out/usr/bin/systemctl
      ln -sf ${pkgs.systemd}/bin/journalctl $out/usr/bin/journalctl
    '';

    runScript = execWrapper;
  };

in
{
  # The unwrapped extracted package (for inspection / debugging)
  unwrapped = azcmagent-unwrapped;

  # The full FHS-wrapped package (for running the agent)
  fhs = azcmagent-fhs;

  # Default: expose the FHS-wrapped agent
  default = azcmagent-fhs;
}
