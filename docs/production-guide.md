# Production Deployment Guide

> **Audience:** NixOS system administrators and Azure Arc Product Group engineers.
> If you're new to NixOS, see the callouts marked 🔰 throughout this guide.

---

## 1. Prerequisites

### NixOS Host

- **NixOS 24.05+** (tested on 26.05) with flakes enabled:
  ```nix
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  ```
- **Supported architectures:** `x86_64-linux`, `aarch64-linux`

> 🔰 **For Azure engineers:** NixOS is a declarative Linux distribution. System
> configuration lives in `.nix` files and is applied atomically with
> `nixos-rebuild switch`. There is no `apt install` or `yum install` — packages
> and services are declared in config and built from source definitions.

### Network

The agent requires **outbound HTTPS (443)** to Azure endpoints. No inbound ports
are needed — Arc uses outbound websocket connections.

| Cloud | Key Endpoints |
|---|---|
| **AzureCloud** | `*.his.arc.azure.com`, `*.guestconfiguration.azure.com`, `management.azure.com`, `login.microsoftonline.com`, `packages.microsoft.com` |
| **AzureUSGovernment** | `*.his.arc.azure.us`, `*.guestconfiguration.azure.us`, `management.usgovcloudapi.net`, `login.microsoftonline.us`, `packages.microsoft.com` |

Full endpoint list: [Azure Arc network requirements](https://learn.microsoft.com/en-us/azure/azure-arc/servers/network-requirements)

### Azure Resources

- An Azure subscription with the **Azure Connected Machine Onboarding** role assigned
- A **service principal** (app registration) with a client secret for automated enrollment
- A **resource group** in a [supported region](https://learn.microsoft.com/en-us/azure/azure-arc/servers/overview#supported-regions)

### Cloud Differences: AzureCloud vs AzureUSGovernment

| | AzureCloud (Commercial) | AzureUSGovernment (GCC-High) |
|---|---|---|
| `cloud` setting | `"AzureCloud"` | `"AzureUSGovernment"` |
| Portal | portal.azure.com | portal.azure.us |
| Login endpoint | login.microsoftonline.com | login.microsoftonline.us |
| Region examples | `eastus`, `westus2` | `usgovvirginia`, `usgovarizona` |
| DSCForLinux | Available | ⛔ Not available |
| Extension availability | Full catalog | Subset — verify per extension |

---

## 2. Adding the Flake

### flake.nix

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-arc.url = "github:jasonrbenson/nixos-flake-arc";
  };

  outputs = { nixpkgs, nixos-arc, ... }: {
    nixosConfigurations.my-server = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";  # or "aarch64-linux"
      modules = [
        ./hardware-configuration.nix
        ./configuration.nix

        # Azure Arc module
        nixos-arc.nixosModules.azure-arc

        # Overlay: makes `pkgs.azcmagent` available
        { nixpkgs.overlays = [ nixos-arc.overlays.default ]; }
      ];
    };
  };
}
```

> 🔰 **For Azure engineers:** A "flake" is a Nix project with pinned
> dependencies (like a lock file). `nixosModules` provides the systemd services
> and config options. The `overlay` injects the `azcmagent` package into the
> package set.

---

## 3. Basic Configuration

### Minimal (`configuration.nix`)

```nix
{ config, pkgs, ... }:
{
  services.azure-arc = {
    enable = true;

    # Azure resource identifiers
    tenantId       = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
    subscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
    resourceGroup  = "rg-arc-nixos";
    location       = "eastus";            # or "usgovvirginia"

    # Cloud environment
    cloud = "AzureCloud";                 # or "AzureUSGovernment"

    # Authentication
    authMethod         = "servicePrincipal";
    servicePrincipalId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";

    # Secret — see Section 4 for secure approaches
    servicePrincipalSecretFile = "/run/secrets/arc-sp-secret";

    # Optional: extension and guest configuration control
    extensions.enable        = true;
    guestConfiguration.enable = true;
  };
}
```

### All Module Options

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the Azure Arc agent |
| `tenantId` | string | — | Azure AD tenant ID |
| `subscriptionId` | string | — | Azure subscription ID |
| `resourceGroup` | string | — | Resource group name |
| `location` | string | `"eastus"` | Azure region |
| `cloud` | enum | `"AzureCloud"` | `AzureCloud`, `AzureUSGovernment`, `AzureChinaCloud` |
| `authMethod` | enum | `"servicePrincipal"` | `servicePrincipal`, `interactiveBrowser`, `deviceCode` |
| `servicePrincipalId` | string | `null` | App (client) ID of the service principal |
| `servicePrincipalSecretFile` | path | `null` | Path to file containing the client secret |
| `proxy.url` | string | `null` | HTTP(S) proxy URL |
| `proxy.bypass` | list | `[]` | Addresses/CIDRs to bypass proxy |
| `extensions.enable` | bool | `true` | Enable extension manager (extd) |
| `extensions.allowList` | list | `[]` | Allowed extension names (empty = all) |
| `extensions.blockList` | list | `[]` | Blocked extension names |
| `guestConfiguration.enable` | bool | `true` | Enable guest config agent (gcad) |
| `extraConfig` | attrs | `{}` | Additional azcmagent key-value config |

---

## 4. Secrets Management

The `servicePrincipalSecretFile` option expects a path to a file containing
**only** the client secret value. Never put secrets directly in `.nix` files —
they end up in the world-readable Nix store.

### sops-nix (Recommended)

[sops-nix](https://github.com/Mic92/sops-nix) encrypts secrets with age keys
and decrypts them at activation time into `/run/secrets/`.

**1. Add sops-nix to your flake:**

```nix
inputs.sops-nix.url = "github:Mic92/sops-nix";

# In modules list:
sops-nix.nixosModules.sops
```

**2. Generate an age key on the host:**

```bash
mkdir -p /var/lib/sops-nix
age-keygen -o /var/lib/sops-nix/key.txt
# Note the public key from the output
```

**3. Create `.sops.yaml` in your repo root:**

```yaml
keys:
  - &server age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - *server
```

**4. Create and encrypt the secret:**

```bash
mkdir -p secrets
sops secrets/arc.yaml
# In the editor, add:
#   arc-sp-secret: "your-client-secret-value-here"
```

**5. Wire it into NixOS:**

```nix
{
  sops.defaultSopsFile = ./secrets/arc.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  sops.secrets.arc-sp-secret = {
    owner = "root";
    mode = "0400";
  };

  services.azure-arc = {
    enable = true;
    # ... other settings ...
    servicePrincipalSecretFile = config.sops.secrets.arc-sp-secret.path;
    # Resolves to /run/secrets/arc-sp-secret at runtime
  };
}
```

### agenix (Alternative)

[agenix](https://github.com/ryantm/agenix) uses age encryption with SSH host
keys for decryption.

**1. Add agenix to your flake:**

```nix
inputs.agenix.url = "github:ryantm/agenix";

# In modules list:
agenix.nixosModules.default
```

**2. Create `secrets.nix` listing which hosts can decrypt:**

```nix
let
  server = "ssh-ed25519 AAAA...";  # from /etc/ssh/ssh_host_ed25519_key.pub
in {
  "arc-sp-secret.age".publicKeys = [ server ];
}
```

**3. Encrypt the secret:**

```bash
cd secrets/
agenix -e arc-sp-secret.age
# Paste your client secret, save, exit
```

**4. Wire it into NixOS:**

```nix
{
  age.secrets.arc-sp-secret = {
    file = ./secrets/arc-sp-secret.age;
    owner = "root";
    mode = "0400";
  };

  services.azure-arc = {
    enable = true;
    # ... other settings ...
    servicePrincipalSecretFile = config.age.secrets.arc-sp-secret.path;
    # Resolves to /run/agenix/arc-sp-secret at runtime
  };
}
```

---

## 5. Deployment Steps

### 1. Build and activate the configuration

```bash
sudo nixos-rebuild switch --flake .#my-server
```

This creates the FHS sandbox, state directories, systemd services, and helper
scripts in a single atomic operation.

> 🔰 **For Azure engineers:** `nixos-rebuild switch` is roughly equivalent to
> `apt upgrade && systemctl daemon-reload` but atomic — if the build fails,
> nothing changes on the running system.

### 2. Connect to Azure Arc

```bash
sudo arc-connect
```

This wrapper script reads your declarative config and runs `azcmagent connect`
inside the FHS sandbox with the correct arguments. You only need to run this
**once** per machine.

### 3. Verify

```bash
# Local agent status
arc-status

# Expected output includes:
#   Agent Status:     Connected
#   Agent Version:    1.61.xxxxx.xxx
#   Resource Name:    <hostname>
```

Also verify in the Azure portal:
- **AzureCloud:** portal.azure.com → Azure Arc → Servers
- **AzureUSGovernment:** portal.azure.us → Azure Arc → Servers

### 4. Deploy extensions (optional)

```bash
# Example: Custom Script Extension
az connectedmachine extension create \
  --machine-name "$(hostname)" \
  --resource-group "rg-arc-nixos" \
  --name "CustomScript" \
  --publisher "Microsoft.Azure.Extensions" \
  --type "CustomScript" \
  --settings '{"commandToExecute": "echo hello from NixOS"}'
```

For GCC-High, add `--cloud AzureUSGovernment` or configure `az cloud set`.

See [extension-compat.md](extension-compat.md) for the tested compatibility matrix.

---

## 6. Platform-Specific Setup

### aarch64 (ARM64) — UTM/QEMU VM

Best for development and testing on Apple Silicon Macs.

**1. Install UTM:**
```bash
brew install --cask utm
```

**2. Create the VM:**
- Download the NixOS **aarch64** minimal ISO from [nixos.org/download](https://nixos.org/download/#nixos-iso)
- In UTM: **Create New VM → Virtualize → Linux**
- Settings: 8 GB RAM, 4+ CPU cores, 40 GB disk
- Boot from the ISO and install NixOS with your preferred disk layout

**3. Post-install — clone and activate:**
```bash
git clone https://github.com/jasonrbenson/nixos-flake-arc.git
cd nixos-flake-arc

# Use the pre-built test configuration
sudo nixos-rebuild switch --flake .#arc-test-vm-aarch64
```

**4. Edit test config for your environment:**

Update the placeholder values in `tests/vm-config.nix` or override them in your
own configuration module before running `arc-connect`.

### x86_64 — Azure VM via nixos-anywhere

Best for production-like validation against Azure infrastructure.

**1. Create an Azure VM (Ubuntu base — will be replaced):**
```bash
az group create -n rg-arc-nixos -l eastus

az vm create \
  --resource-group rg-arc-nixos \
  --name nixos-arc-test \
  --image Ubuntu2204 \
  --size Standard_B2s \
  --admin-username azureuser \
  --generate-ssh-keys \
  --public-ip-sku Standard
```

**2. Inject NixOS with nixos-anywhere:**

> Requires Nix installed on your local machine (macOS or Linux).

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#arc-test-vm-x86_64 \
  root@<vm-public-ip>
```

This replaces Ubuntu with NixOS in ~5–10 minutes via kexec. The VM reboots into
NixOS with the Arc agent module pre-configured.

**3. Post-deployment:**
```bash
ssh root@<vm-public-ip>
# Edit /etc/nixos/ or the flake config with real Azure values
sudo nixos-rebuild switch --flake .#arc-test-vm-x86_64
sudo arc-connect
```

See [test-environment.md](test-environment.md) for detailed setup instructions.

---

## 7. Monitoring and Troubleshooting

### Systemd Services

| Service | Purpose | Check |
|---|---|---|
| `himdsd` | Core agent (identity, heartbeat) | `systemctl status himdsd` |
| `arcproxyd` | Arc proxy for outbound connections | `systemctl status arcproxyd` |
| `gcad` | Guest Configuration agent | `systemctl status gcad` |
| `extd` | Extension manager | `systemctl status extd` |
| `azure-arc-init` | One-shot: initializes writable overlays | `systemctl status azure-arc-init` |

### Key Log Locations

```bash
# Agent logs (inside the FHS sandbox, mapped to host paths)
/var/opt/azcmagent/log/himds.log          # Core agent
/var/opt/azcmagent/log/azcmagent.log      # CLI operations

# Guest Configuration / Extension logs
/var/lib/GuestConfig/ext_mgr_logs/gc_ext.log    # Extension manager
/var/lib/GuestConfig/gc_agent_logs/gc_agent.log  # Guest config agent

# Journald
journalctl -u himdsd -f          # Live agent log
journalctl -u extd -f            # Live extension log
journalctl -u gcad -f            # Live guest config log
journalctl -u arcproxyd -f       # Live proxy log
```

### Extension Debugging

Extensions install to `/var/lib/waagent/` inside the sandbox. Each extension has:

```
/var/lib/waagent/<Publisher>.<Type>-<version>/
├── status/          # *.status JSON files reported to Azure
├── config/          # *.settings from Azure
├── bin/             # Extension handler scripts
├── state.json       # Handler internal state — check this first
└── enable.log       # stdout/stderr from the enable command
```

Useful commands:
```bash
# List installed extensions (runs inside FHS sandbox)
sudo azcmagent-fhs ls /var/lib/waagent/

# Check extension state
sudo azcmagent-fhs cat /var/lib/waagent/Microsoft.Azure.Extensions.CustomScript-2.1.14/state.json

# Check extension enable output
sudo azcmagent-fhs cat /var/lib/waagent/Microsoft.Azure.Extensions.CustomScript-2.1.14/enable.log
```

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| `arc-connect` fails with auth error | Wrong SP credentials or expired secret | Verify `servicePrincipalId` and rotate the secret file |
| Services fail to start | FHS sandbox missing dependencies | Check `journalctl -u himdsd` for library errors; may need flake update |
| Agent shows "Disconnected" | Network issue or token expiry | Check outbound HTTPS to `*.his.arc.azure.com` (or `.azure.us`); run `sudo arc-connect` again |
| 503 errors on service restart | Transient race during simultaneous restarts | Services auto-recover — wait 30s and check again |
| Extension install stuck | extd service not running or crashed | `systemctl restart extd && journalctl -u extd -f` |
| `azcmagent extension list` fails | CLI tries `systemctl disable/enable` which conflicts with declarative NixOS | Known limitation — use Azure portal or `az connectedmachine extension list` instead |
| Permission denied in `/opt/` paths | Writable overlay not initialized | `systemctl restart azure-arc-init && systemctl restart himdsd` |

---

## 8. Known Limitations

### AMA Blocked by Distro Allowlist

Azure Monitor Agent (AMA) rejects NixOS because `ID=nixos` in `/etc/os-release`
is not in AMA's hardcoded `supported_distros.py` allowlist. This is an upstream
issue, not a NixOS packaging issue.

**Impact:** No Azure Monitor metrics/log collection via AMA.
**Tracking:** See [gaps-and-findings.md](gaps-and-findings.md) for the root cause
analysis and recommendation to the Azure Monitor team.

### Services Run as Root

The Arc services currently run as `root` instead of the intended `himds` user.
This is because `azcmagent connect` creates root-owned files that the `himds`
user cannot modify. Security hardening to restore proper user separation is
planned.

### NixOS Update Model vs Azure Update Manager

NixOS uses declarative, atomic system updates (`nixos-rebuild switch`), not
in-place package mutation. Azure Update Manager's patching model does not apply.
System updates should be managed through the normal NixOS flake update workflow
(see [Section 9](#9-upgrading)).

### Agent Auto-Update Disabled

The flake pins a specific agent version. Microsoft's auto-update mechanism is
intentionally disabled — version changes go through `nix flake update` for
reproducibility.

### Guest Configuration Non-Functional on Non-Azure VMs

The Guest Configuration agent (`gcad`) requires the Azure Instance Metadata
Service (IMDS) at `169.254.169.254:80` for VM metadata and MSI tokens. On
non-Azure Arc-connected machines (e.g., on-premises, UTM/QEMU, other clouds),
IMDS does not exist and gcad times out on every refresh cycle (2 min × 3
attempts = 6 min per cycle). Guest Configuration assignments are never pulled
and policy compliance is never reported.

**Impact:** Guest Configuration policies and audit assignments do not function
on non-Azure Arc machines. This is a limitation of the GC agent, not NixOS.
**Tracking:** See [Gap 10](gaps-and-findings.md#gap-10-guest-configuration-agent-requires-azure-imds).

### GC Poll-Based Extension Refresh Requires Auth Key Registration

The GC components authenticate to himds's internal MSI endpoint (port 40341)
using a pre-shared key established during `install.sh`. Our Nix packaging
doesn't fully replicate this key exchange, so poll-based extension refresh
fails with `Failed to get the msi authentication key`. Notification-based
delivery works for most extensions, but extensions requested during a
notification gap may not be delivered.

**Impact:** Extensions like Key Vault that rely on poll-based refresh may
get stuck in "Creating" state.
**Tracking:** See [Gap 9](gaps-and-findings.md#gap-9-gchimds-msi-auth-key-registration-not-replicated).

### Extension Compatibility

Not all extensions work on NixOS. See [extension-compat.md](extension-compat.md)
for the full testing matrix. The extension delivery pipeline itself is fully
functional — failures are due to individual extensions' OS-specific checks,
IMDS dependencies, or GC auth gaps.

---

## 9. Upgrading

### Updating the Agent Version

The agent version is pinned in `flake.nix` at the repository level. To pick up
a new version:

```bash
# Update the flake lock to pull latest changes (including version bumps)
nix flake update nixos-arc

# Rebuild
sudo nixos-rebuild switch --flake .#my-server
```

If you maintain a fork, update `agentVersion` and the `sha256` hashes in
`flake.nix`.

### What Happens on Rebuild

- The FHS sandbox is rebuilt with the new agent binaries
- `azure-arc-init` re-runs **only if** `/var/opt/azcmagent/opt-azcmagent/bin/`
  is empty (i.e., first boot). Existing extension state in
  `/var/opt/azcmagent/opt-*` is **preserved**
- Systemd services restart with the new binary paths
- The Arc connection and resource identity in Azure are **not affected** — no
  re-enrollment needed

To force a clean re-initialization of the writable overlays (e.g., after a major
version jump):

```bash
sudo rm -rf /var/opt/azcmagent/opt-azcmagent/bin
sudo systemctl restart azure-arc-init
sudo systemctl restart himdsd extd gcad arcproxyd
```

---

## Further Reading

- [Architecture](architecture.md) — FHS sandbox design, binary analysis, ADRs
- [Gaps and Findings](gaps-and-findings.md) — Current gaps, root causes, product group recommendations
- [Extension Compatibility](extension-compat.md) — Extension testing matrix
- [Test Environment](test-environment.md) — VM setup for development and testing
- [Demo Guide](demo-guide.md) — Presentation walkthrough for stakeholders
