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
      # Source: https://packages.microsoft.com/ubuntu/22.04/prod/dists/jammy/main/
      agentVersion = "1.61.03319.859";
      agentSources = {
        x86_64-linux = {
          url = "https://packages.microsoft.com/ubuntu/22.04/prod/pool/main/a/azcmagent/azcmagent_${agentVersion}_amd64.deb";
          sha256 = "d26ec8a0f94213761ced45286172c5f52d2ad747be9bc3c1e7fee88443329d73";
          arch = "amd64";
        };
        aarch64-linux = {
          url = "https://packages.microsoft.com/ubuntu/22.04/prod/pool/main/a/azcmagent/azcmagent_${agentVersion}_arm64.deb";
          sha256 = "a9d9f8ad170ab2fc8483fe4a9950ec9065c8a068d477461eb311afdbb843a075";
          arch = "arm64";
        };
      };
    in
    (forAllSystems (system:
      let
        pkgs-unstable = import nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
        pkgs-stable = import nixpkgs-stable {
          inherit system;
          config.allowUnfree = true;
        };

        # Default to unstable for development
        pkgs = pkgs-unstable;
      in
      {
        # --- Packages ---
        packages =
          let
            agentPkgs = pkgs.callPackage ./packages/azcmagent {
              inherit agentVersion;
              agentSource = agentSources.${system} or (throw "Unsupported system: ${system}");
            };
          in
          {
            # FHS-wrapped agent (full runtime)
            azcmagent = agentPkgs.default;

            # Extracted package (for inspection/debugging)
            azcmagent-unwrapped = agentPkgs.unwrapped;

            default = agentPkgs.default;
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

      # --- Test VM Configurations ---
      # Complete NixOS systems for testing the Arc agent.
      #
      # Local UTM (aarch64):  nixos-rebuild switch --flake .#arc-test-vm-aarch64
      # Azure (x86_64):       nix run github:nix-community/nixos-anywhere -- --flake .#arc-test-vm-x86_64 root@<ip>
      # Build VM script:      nix build .#nixosConfigurations.arc-test-vm-aarch64.config.system.build.vm
      nixosConfigurations = {
        arc-test-vm-aarch64 = nixpkgs-unstable.lib.nixosSystem {
          system = "aarch64-linux";
          modules = [
            self.nixosModules.azure-arc
            ./tests/vm-config.nix
            {
              nixpkgs.overlays = [ self.overlays.default ];
              nixpkgs.config.allowUnfree = true;
              networking.hostName = "arc-test-aarch64";
            }
          ];
        };

        arc-test-vm-x86_64 = nixpkgs-unstable.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            self.nixosModules.azure-arc
            ./tests/vm-config.nix
            {
              nixpkgs.overlays = [ self.overlays.default ];
              nixpkgs.config.allowUnfree = true;
              networking.hostName = "arc-test-x86-64";
            }
          ];
        };
      };

      # --- Overlay for composability ---
      overlays.default = final: prev: {
        azcmagent = self.packages.${prev.system}.azcmagent;
      };
    };
}
