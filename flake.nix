{
  description = "Azure Arc Connected Machine Agent for NixOS";

  inputs = {
    # Unstable for latest packages and features
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Stable channel for production deployments
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Flake utilities
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs-unstable, nixpkgs-stable, flake-utils }:
    let
      # Systems we target
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Helper to generate per-system outputs
      forAllSystems = flake-utils.lib.eachSystem supportedSystems;

      # Microsoft package source metadata — update these when upgrading
      agentVersion = "1.48";
      agentSources = {
        x86_64-linux = {
          url = "https://packages.microsoft.com/ubuntu/22.04/prod/pool/main/a/azcmagent/azcmagent_${agentVersion}.02646.952-ubuntu22.04_amd64.deb";
          sha256 = "0000000000000000000000000000000000000000000000000000"; # TODO: replace after fetching
          arch = "amd64";
        };
        aarch64-linux = {
          url = "https://packages.microsoft.com/ubuntu/22.04/prod/pool/main/a/azcmagent/azcmagent_${agentVersion}.02646.952-ubuntu22.04_arm64.deb";
          sha256 = "0000000000000000000000000000000000000000000000000000"; # TODO: replace after fetching
          arch = "arm64";
        };
      };
    in
    (forAllSystems (system:
      let
        pkgs-unstable = import nixpkgs-unstable { inherit system; };
        pkgs-stable = import nixpkgs-stable { inherit system; };

        # Default to unstable for development
        pkgs = pkgs-unstable;
      in
      {
        # --- Packages ---
        packages = {
          azcmagent = pkgs.callPackage ./packages/azcmagent {
            inherit agentVersion;
            agentSource = agentSources.${system} or (throw "Unsupported system: ${system}");
          };

          default = self.packages.${system}.azcmagent;
        };

        # --- Development shell ---
        devShells.default = pkgs.mkShell {
          name = "nixos-arc-dev";
          packages = with pkgs; [
            nix
            nixpkgs-fmt
            statix        # Nix linter
            deadnix       # Dead code finder for Nix
            binutils      # readelf, strings for binary analysis
            patchelf      # ELF patching
            file          # File type detection
            dpkg          # DEB extraction
          ];
          shellHook = ''
            echo "nixos-flake-arc development shell"
            echo "  nix build .#azcmagent  — build the agent package"
            echo "  nix flake check        — run all checks"
          '';
        };

        # --- Checks ---
        checks = {
          # Format check
          format = pkgs.runCommand "check-format" {
            nativeBuildInputs = [ pkgs.nixpkgs-fmt ];
          } ''
            nixpkgs-fmt --check ${self}/*.nix ${self}/packages/**/*.nix ${self}/modules/*.nix 2>/dev/null || true
            touch $out
          '';
        };
      }
    )) // {
      # --- NixOS Modules (system-independent) ---
      nixosModules = {
        azure-arc = import ./modules/azure-arc.nix;
        default = self.nixosModules.azure-arc;
      };

      # --- Overlay for composability ---
      overlays.default = final: prev: {
        azcmagent = self.packages.${prev.system}.azcmagent;
      };
    };
}
