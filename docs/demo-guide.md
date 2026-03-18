# Demo Guide — Azure Arc on NixOS for Product Group Presentation

## Demo Narrative

> "We've built a NixOS flake that packages the Azure Arc Connected Machine Agent and its
> extension ecosystem, proving that NixOS can be a first-class Azure Arc citizen. Here's
> what it looks like in practice."

## Prerequisites

- Azure subscription with Contributor access
- Service principal with Azure Connected Machine Onboarding role
- NixOS VM (local or Azure) with this flake applied

## Demo Flow

### 1. Show the NixOS Configuration (Declarative!)

```nix
# /etc/nixos/configuration.nix
services.azure-arc = {
  enable = true;
  tenantId = "contoso-tenant-id";
  subscriptionId = "sub-id";
  resourceGroup = "arc-nixos-demo";
  location = "eastus";
  authMethod = "servicePrincipal";
  servicePrincipalId = "sp-app-id";
  servicePrincipalSecretFile = "/run/secrets/arc-sp-secret";
  extensions.enable = true;
};
```

**Talking point**: "One declarative block. No install scripts, no package managers,
no imperative setup. This is the NixOS way."

### 2. Connect to Azure Arc

```bash
sudo arc-connect
azcmagent show
```

**Talking point**: "Machine is connected. Let's see it in the Azure portal."

### 3. Show in Azure Portal

- Navigate to Azure Arc → Servers
- Show the NixOS machine with healthy heartbeat
- Show machine properties (OS: NixOS, agent version)

### 4. Deploy Extensions

From the Azure portal, deploy:
- Azure Monitor Agent
- MDE (Defender for Endpoint)
- Guest Configuration

```bash
azcmagent extension list
```

**Talking point**: "Extensions deploy and run just like on Ubuntu or RHEL."

### 5. Show Extension Telemetry

- Azure Monitor: Show logs/metrics flowing
- MDE: Show machine in Defender for Cloud
- Guest Config: Show compliance assessment results

### 6. The Ask

**Key messages for the Product Group:**

1. **Feasibility proven**: NixOS can run the full Arc stack today via FHS sandboxing
2. **What we need from you**: Official NixOS package, or at minimum:
   - Document all hardcoded FHS paths in agent binaries
   - Provide a "portable" agent build without FHS assumptions
   - Add NixOS to the CI matrix for smoke tests
3. **The opportunity**: NixOS adoption is growing in enterprise security and infrastructure.
   Supporting it positions Arc as the truly universal hybrid management platform.
4. **Low cost to you**: We've done the hard work. A few path abstractions in the agent
   would eliminate the need for the FHS sandbox entirely.
