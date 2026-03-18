{ lib
, stdenv
, fetchurl
, dpkg
, autoPatchelfHook
, buildFHSEnv
, writeShellScriptBin
, openssl
, zlib
, glibc
, icu
, curl
, krb5
, lttng-ust
, systemd
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

    unpackPhase = ''
      dpkg-deb -x $src .
    '';

    installPhase = ''
      runHook preInstall

      # Copy the full agent tree preserving structure
      mkdir -p $out

      # Core agent binaries
      if [ -d opt/azcmagent ]; then
        cp -r opt/azcmagent $out/opt-azcmagent
      fi

      # Guest Configuration extension service
      if [ -d opt/GC_Ext ]; then
        cp -r opt/GC_Ext $out/opt-gc-ext
      fi
      if [ -d opt/GC_Service ]; then
        cp -r opt/GC_Service $out/opt-gc-service
      fi
      if [ -d opt/DSC ]; then
        cp -r opt/DSC $out/opt-dsc
      fi

      # Systemd service units
      if [ -d lib/systemd ] || [ -d usr/lib/systemd ]; then
        mkdir -p $out/lib/systemd
        cp -r lib/systemd/* $out/lib/systemd/ 2>/dev/null || true
        cp -r usr/lib/systemd/* $out/lib/systemd/ 2>/dev/null || true
      fi

      # Configuration files
      if [ -d etc ]; then
        mkdir -p $out/etc
        cp -r etc/* $out/etc/ 2>/dev/null || true
      fi

      runHook postInstall
    '';

    # Catalog what we extracted for analysis
    postInstall = ''
      echo "=== Extracted agent contents ===" > $out/MANIFEST.txt
      find $out -type f | sort >> $out/MANIFEST.txt
      echo "=== ELF binaries ===" >> $out/MANIFEST.txt
      find $out -type f -executable | while read f; do
        file "$f" 2>/dev/null | grep -q ELF && echo "$f" >> $out/MANIFEST.txt || true
      done
    '';

    meta = with lib; {
      description = "Azure Arc Connected Machine Agent (extracted, unwrapped)";
      homepage = "https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview";
      license = licenses.unfree;
      platforms = [ "x86_64-linux" "aarch64-linux" ];
      maintainers = [ ];
    };
  };

  # FHS environment that simulates the filesystem layout the agent expects
  azcmagent-fhs = buildFHSEnv {
    name = "azcmagent";
    version = agentVersion;

    targetPkgs = pkgs: [
      openssl
      zlib
      glibc
      icu
      curl
      krb5
      lttng-ust
      systemd
    ];

    # Bind-mount the agent binaries into FHS-expected locations
    extraBuildCommands = ''
      # Core agent
      if [ -d ${azcmagent-unwrapped}/opt-azcmagent ]; then
        mkdir -p opt/azcmagent
        cp -r ${azcmagent-unwrapped}/opt-azcmagent/* opt/azcmagent/
      fi

      # Guest Configuration
      if [ -d ${azcmagent-unwrapped}/opt-gc-ext ]; then
        mkdir -p opt/GC_Ext
        cp -r ${azcmagent-unwrapped}/opt-gc-ext/* opt/GC_Ext/
      fi
      if [ -d ${azcmagent-unwrapped}/opt-gc-service ]; then
        mkdir -p opt/GC_Service
        cp -r ${azcmagent-unwrapped}/opt-gc-service/* opt/GC_Service/
      fi
      if [ -d ${azcmagent-unwrapped}/opt-dsc ]; then
        mkdir -p opt/DSC
        cp -r ${azcmagent-unwrapped}/opt-dsc/* opt/DSC/
      fi
    '';

    runScript = "/opt/azcmagent/bin/azcmagent";

    meta = with lib; {
      description = "Azure Arc Connected Machine Agent (FHS environment)";
      homepage = "https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview";
      license = licenses.unfree;
      platforms = [ "x86_64-linux" "aarch64-linux" ];
    };
  };

in
azcmagent-fhs
