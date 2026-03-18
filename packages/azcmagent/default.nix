{ lib
, stdenv
, fetchurl
, dpkg
, buildFHSEnv
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
    ];

    extraBuildCommands = ''
      # Core agent → /opt/azcmagent/
      mkdir -p opt/azcmagent
      cp -r ${azcmagent-unwrapped}/azcmagent/* opt/azcmagent/

      # Extension Manager → /opt/GC_Ext/
      mkdir -p opt/GC_Ext
      cp -r ${azcmagent-unwrapped}/GC_Ext/* opt/GC_Ext/

      # Guest Configuration → /opt/GC_Service/
      mkdir -p opt/GC_Service
      cp -r ${azcmagent-unwrapped}/GC_Service/* opt/GC_Service/

      # State directories the agent expects
      mkdir -p var/opt/azcmagent/{certs,log,socks,tokens}
      mkdir -p var/lib/GuestConfig
      mkdir -p var/lib/waagent
      mkdir -p lib/systemd/system
      mkdir -p lib/systemd/system.conf.d
      mkdir -p etc/bash_completion.d
    '';

    runScript = "/opt/azcmagent/bin/azcmagent";
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
