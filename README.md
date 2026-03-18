# nixos-flake-arc

NixOS flake for running the Azure Arc Connected Machine Agent (`azcmagent`) on NixOS.

## Status

🚧 **Early Development** — This is an interim proof-of-concept to demonstrate that NixOS
can be a first-class citizen for Azure Arc, and to provide a blueprint for the Azure Arc
Product Group to invest in native NixOS support.

## Why?

Azure Arc's Connected Machine Agent officially supports only FHS-compliant Linux
distributions (RHEL, Ubuntu, SLES, etc.). NixOS uses `/nix/store` instead of standard
FHS paths, which breaks the agent's assumptions. This project bridges that gap using a
`buildFHSEnv` sandbox wrapped in a NixOS-native declarative module.

## Architecture

```
┌───────────────────────────────────────────────┐
│  NixOS Module (declarative config)            │
│  ┌─────────────────────────────────────────┐  │
│  │  services.azure-arc.enable = true;      │  │
│  │  services.azure-arc.tenantId = "...";   │  │
│  │  services.azure-arc.extensions = {...}; │  │
│  └─────────────┬───────────────────────────┘  │
│                 │                              │
│  ┌─────────────▼───────────────────────────┐  │
│  │  FHS Runtime Sandbox (buildFHSEnv)      │  │
│  │  Agent binaries + dependencies          │  │
│  │  systemd services run inside sandbox    │  │
│  └─────────────────────────────────────────┘  │
│                                               │
│  State: /var/lib/azure-arc/                   │
│  Logs:  /var/log/azure-arc/                   │
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

## Development

```bash
# Enter development shell
nix develop

# Build the agent package
nix build .#azcmagent

# Run checks
nix flake check
```

## Supported Platforms

| Architecture | Status |
|---|---|
| x86_64-linux | 🔄 In Progress |
| aarch64-linux | 🔄 Planned (pending Microsoft ARM64 binary availability) |

## Extension Support

| Extension | Status |
|---|---|
| Core Agent (connect/heartbeat) | 🔄 In Progress |
| Azure Monitor Agent | 📋 Planned (Phase 2) |
| MDE (Defender for Endpoint) | 📋 Planned (Phase 3) |
| Guest Configuration | 📋 Planned (Phase 3) |
| Custom Script Extension | 📋 Planned |
| Azure Update Manager | 📋 Planned |

## License

This project packages Microsoft's proprietary Azure Arc agent binaries. The Nix
packaging code is MIT licensed. The agent binaries themselves are subject to
[Microsoft's license terms](https://learn.microsoft.com/en-us/azure/azure-arc/servers/agent-overview).
