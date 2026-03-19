# nixos-flake-arc

NixOS flake for running the Azure Arc Connected Machine Agent (`azcmagent`) on NixOS.

## Status

🟢 **Working PoC** — The core agent and extension framework are functional on NixOS.
Machine connects to Azure Arc, heartbeats, and processes extension deployments. This is an
interim proof-of-concept to demonstrate feasibility to the Azure Arc Product Group and
provide a blueprint for native NixOS support.

## Why?

Azure Arc's Connected Machine Agent officially supports only FHS-compliant Linux
distributions (RHEL, Ubuntu, SLES, etc.). NixOS uses `/nix/store` instead of standard
FHS paths, which breaks the agent's assumptions. This project bridges that gap using a
`buildFHSEnv` (bubblewrap) sandbox wrapped in a NixOS-native declarative module.

## Architecture

```
┌───────────────────────────────────────────────┐
│  NixOS Module (services.azure-arc.*)          │
│  ┌─────────────────────────────────────────┐  │
│  │  Declarative config + systemd services  │  │
│  │  himdsd, arcproxyd, gcad, extd          │  │
│  └─────────────┬───────────────────────────┘  │
│                 │                              │
│  ┌─────────────▼───────────────────────────┐  │
│  │  FHS Runtime Sandbox (bubblewrap)       │  │
│  │  /opt/azcmagent  (writable overlay)     │  │
│  │  /opt/GC_Ext     (writable overlay)     │  │
│  │  /opt/GC_Service (writable overlay)     │  │
│  └─────────────────────────────────────────┘  │
│                                               │
│  State: /var/opt/azcmagent/                   │
│  Logs:  /var/opt/azcmagent/log/               │
│  Extensions: /var/lib/waagent/                │
└───────────────────────────────────────────────┘
```

## Quick Start

### 1. Add to your flake inputs

```nix
{
  inputs.nixos-arc.url = "github:jasonrbenson/nixos-flake-arc";
}
```

### 2. Import the NixOS module

```nix
{ config, pkgs, ... }:
{
  imports = [ nixos-arc.nixosModules.azure-arc ];

  services.azure-arc = {
    enable = true;
    tenantId = "your-tenant-id";
    subscriptionId = "your-subscription-id";
    resourceGroup = "your-resource-group";
    location = "eastus";

    # Service principal auth (use sops-nix or agenix for the secret)
    authMethod = "servicePrincipal";
    servicePrincipalId = "your-sp-app-id";
    servicePrincipalSecretFile = "/run/secrets/arc-sp-secret";
  };
}
```

### 3. Connect to Azure Arc

```bash
# After nixos-rebuild switch
sudo arc-connect
```

## Supported Platforms

| Architecture | Status |
|---|---|
| aarch64-linux | ✅ Working (tested on NixOS 26.05 in UTM/QEMU) |
| x86_64-linux | 🔄 Untested (package builds, needs VM validation) |

## Extension Compatibility

Tested on aarch64 NixOS 26.05, Azure Arc agent v1.61, AzureUSGovernment.

| Extension | Install | Enable | Notes |
|---|---|---|---|
| **Custom Script** v2.1.14 | ✅ | ✅ | Full end-to-end success — runs commands, returns output to Azure |
| **MDE** v1.0.10.0 | ✅ | ⚠️ | Handler runs; needs Defender onboarding blob for full config |
| **AMA** v1.40.0 | ❌ | — | Blocked by distro allowlist (`ID=nixos` not recognized) |
| **Key Vault** v3.5.3041.185 | ⚠️ | — | MSI auth fixed; needs re-test of full install flow |
| **Guest Configuration** | ✅ | ✅ | Pulls assignments, runs compliance checks (AzureLinuxBaseline), reports to Azure |
| **DSCForLinux** | — | — | Not available in USGov region (cloud limitation) |

The extension delivery pipeline (download → GPG validate → unzip → execute) works fully.
Both notification-based and poll-based extension delivery are functional. Guest Configuration
pulls assignments, validates GPG signatures, and runs compliance checks. Extension-specific
failures are due to distro allowlist checks in individual extensions — not the NixOS platform.

📄 **[Full gaps analysis and findings →](docs/gaps-and-findings.md)**

## Development

```bash
# Enter development shell
nix develop

# Build the agent package
nix build .#azcmagent

# Run checks
nix flake check
```

## Documentation

- **[Production Deployment Guide](docs/production-guide.md)** — End-to-end setup for NixOS admins and Azure engineers
- [Architecture](docs/architecture.md) — Technical design of the FHS sandbox approach
- [Gaps and Findings](docs/gaps-and-findings.md) — Current gaps, root causes, and recommendations
- [Extension Compatibility](docs/extension-compat.md) — Extension testing matrix
- [Test Environment](docs/test-environment.md) — Setting up a test VM
- [Demo Guide](docs/demo-guide.md) — Walkthrough for demonstrations

## License

This project packages Microsoft's proprietary Azure Arc agent binaries. The Nix
packaging code is MIT licensed. The agent binaries themselves are subject to
[Microsoft's license terms](https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview).
