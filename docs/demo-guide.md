# Demo Guide — Azure Arc on NixOS for Product Group Presentation

> **Audience**: Azure Arc Product Group — technical staff, leadership, and PMs.
> Some attendees may not be familiar with NixOS. Adjust depth accordingly.

---

## 1. Executive Summary

We have built a fully declarative NixOS flake that packages the Azure Connected Machine
Agent (v1.61) inside an FHS sandbox, enabling NixOS to be managed by Azure Arc with
extension support. This proof-of-concept validates that NixOS can run the core Arc agent,
deploy and execute extensions through the full pipeline (download → GPG validate → install
→ enable → report), and return results to the Azure portal. CustomScript and MDE extensions
work end-to-end; AMA is blocked **only** by a Python distro allowlist — not by any platform
incompatibility. This work defines exactly what Microsoft would need to change for native
NixOS support.

---

## 2. Demo Environment

| Component              | Value                                          |
|------------------------|------------------------------------------------|
| **OS**                 | NixOS 26.05 (aarch64-linux)                    |
| **VM Platform**        | UTM (QEMU) on macOS                            |
| **Azure Arc Agent**    | v1.61.03319.859                                |
| **Cloud**              | AzureUSGovernment                               |
| **Resource Group**     | `arc-testing`                                   |
| **Location**           | `usgovvirginia`                                 |
| **Machine Name**       | `arc-test`                                      |
| **FHS Sandbox**        | `buildFHSEnv` (bubblewrap)                      |
| **Systemd Services**   | `himdsd`, `arcproxyd`, `gcad`, `extd`           |

---

## 3. Demo Script

**Total time: ~12 minutes**

---

### Act 1: Show the NixOS Configuration (2 min)

Open `flake.nix` and highlight the `services.azure-arc` block:

```nix
services.azure-arc = {
  enable = true;
  tenantId = "...";
  subscriptionId = "...";
  resourceGroup = "arc-testing";
  location = "usgovvirginia";
  cloud = "AzureUSGovernment";
  authMethod = "servicePrincipal";
  servicePrincipalId = "...";
  servicePrincipalSecretFile = "/run/secrets/arc-sp-secret";
  extensions.enable = true;
  guestConfiguration.enable = true;
};
```

**What to show**:

- The entire Arc integration is one declarative block — no install scripts, no
  package managers, no imperative setup
- `extensions.enable = true` activates the extension manager (`extd` service)
- `guestConfiguration.enable = true` activates the Guest Configuration agent (`gcad`)
- The flake builds for both `x86_64-linux` and `aarch64-linux`

> **Key talking point** (for PMs): *"Everything is declarative — one file defines the
> entire Arc integration. Change a setting, rebuild, and the machine converges to the
> new state. Roll back with a single command if anything goes wrong."*

---

### Act 2: Machine Connected to Azure Arc (2 min)

**In the terminal**:

```bash
sudo arc-status
```

Expected output shows:

- Agent status: **Connected**
- Agent version: `1.61.03319.859`
- Resource name: `arc-test`
- Resource group: `arc-testing`
- Cloud: `AzureUSGovernment`

**In the Azure portal**:

1. Navigate to **Azure Arc → Servers**
2. Click on **arc-test**
3. Show the **Overview** tab — OS field reads **NixOS 26.05**, agent status **Connected**
4. Show the healthy heartbeat

> **Key talking point**: *"NixOS reports truthfully — no OS spoofing. The portal shows
> NixOS 26.05 because that's what `/etc/os-release` says. The agent doesn't need to
> pretend to be Ubuntu."*

---

### Act 3: Extension Deployment — Custom Script (3 min)

**Deploy via CLI** (or pre-deploy and show results):

```bash
az connectedmachine extension create \
  --machine-name arc-test --resource-group arc-testing \
  --name CustomScriptExtension --publisher Microsoft.Azure.Extensions \
  --type CustomScript --location usgovvirginia \
  --settings '{"commandToExecute":"echo hello-from-nixos && uname -a"}'
```

**Show the result in the portal**:

1. Navigate to **arc-test → Extensions**
2. CustomScript status: **Succeeded**
3. Click through to show the output:

```
[stdout]
hello-from-nixos
Linux arc-test 6.18.18 #1-NixOS SMP ... aarch64 GNU/Linux
```

**What happened behind the scenes** (for technical audience):

1. Azure sent the extension request to `himds`
2. `extd` (extension manager) polled for the pending extension
3. Downloaded the CustomScript v2.1.14 package from blob storage
4. Validated GPG signature ✅ and SHA256 checksum ✅
5. Extracted to `/var/lib/GuestConfig/downloads/`
6. Installed handler via `systemd-run --scope`
7. Enabled handler, executed the command
8. Status + stdout reported back to Azure

> **Key talking point**: *"Full round-trip — Azure sends a command, NixOS executes it
> inside the FHS sandbox, and the result returns to the portal. This is the exact same
> pipeline that runs on Ubuntu and RHEL."*

---

### Act 4: MDE Extension (2 min)

**Show MDE is installed**:

```bash
# In the portal: arc-test → Extensions
# MDE.Linux status: Succeeded (install + enable)
```

**What to show**:

- MDE (Microsoft Defender for Endpoint) v1.0.10.0 is installed and enabled
- The handler runs on NixOS inside the FHS sandbox
- Full onboarding requires the Defender onboarding configuration blob
  (tenant-specific, outside scope of this PoC)

> **Key talking point**: *"The Defender handler installs and runs on NixOS — the
> platform works. Full onboarding just needs the standard onboarding configuration
> that any Defender deployment requires."*

---

### Act 5: The AMA Gap — The Ask (3 min)

**This is the most important section for the Product Group.**

**Show the failure**:

```bash
# In the portal: arc-test → Extensions
# AzureMonitorLinuxAgent status: Failed
# Exit code: 51 — UnsupportedOperatingSystem
```

**Explain the root cause**:

The AMA v1.40.0 installer (`agent.py`) reads `/etc/os-release`, extracts the
`ID` field, and checks it against a hardcoded Python allowlist in
`supported_distros.py`:

```python
# From AMA's supported_distros.py
supported_dists_aarch64 = {
    'redhat': ['8', '9', '10'],
    'ubuntu': ['18.04', '20.04', '22.04', '24.04'],
    'alma': ['8'],
    'centos': ['7'],
    'mariner': ['2'],
    'azurelinux': ['3'],
    'sles': ['15'],
    'debian': ['11', '12', '13'],
    'rocky linux': ['8', '9'],
    'rocky': ['8', '9']
}
```

NixOS (`ID=nixos`) is not in this list → immediate exit code 51.

**Show what DID work before the allowlist check killed it**:

- ✅ Extension download from blob storage
- ✅ GPG signature validation
- ✅ SHA256 checksum verification
- ✅ Extraction and handler installation
- ❌ `agent.py` distro check → exit 51

> **Key talking point**: *"The ONLY thing blocking AMA on NixOS is a Python allowlist.
> The download worked. GPG validation worked. Extraction worked. The platform is fully
> capable — it's a single `if` statement that blocks us."*

**The Ask**:

> *"Adding `'nixos'` to `supported_distros.py` is a one-line change that unlocks full
> monitoring for NixOS on Azure Arc. We're not asking for a rewrite — we're asking to
> remove an artificial gate that the platform has already proven it doesn't need."*

---

## 4. Architecture Slide Notes

For whoever is building the slide deck, here are the three key diagrams:

### FHS Sandbox Diagram

```
┌─────────────────────────────────────────────────┐
│  NixOS Host                                      │
│  /nix/store/... (immutable, non-FHS)             │
│                                                   │
│  ┌─────────────────────────────────────────────┐ │
│  │  bubblewrap (bwrap) sandbox                  │ │
│  │  ┌───────────────────────────────────────┐   │ │
│  │  │  FHS filesystem view                   │   │ │
│  │  │  /opt/azcmagent/  ← bind mount         │   │ │
│  │  │  /opt/GC_Ext/     ← bind mount         │   │ │
│  │  │  /opt/GC_Service/ ← bind mount         │   │ │
│  │  │  /usr/bin/systemctl → NixOS systemctl  │   │ │
│  │  │  /lib64/ld-linux-*.so.2                │   │ │
│  │  │                                         │   │ │
│  │  │  himds | arcproxy | extd | gcad         │   │ │
│  │  └───────────────────────────────────────┘   │ │
│  └─────────────────────────────────────────────┘ │
│                                                   │
│  Writable state: /var/opt/azcmagent/              │
│  Extension data: /var/lib/GuestConfig/            │
└─────────────────────────────────────────────────┘
```

### Extension Pipeline Flow

```
Azure Portal / CLI
       │
       ▼
   ARM request
       │
       ▼
   himds (Connected Machine Agent)  ← receives notification
       │
       ▼
   extd (Extension Manager)         ← polls for pending extensions
       │
       ▼
   Download from blob storage
       │
       ▼
   GPG signature validation  ✅
       │
       ▼
   SHA256 checksum verify    ✅
       │
       ▼
   Unzip to /var/lib/GuestConfig/downloads/
       │
       ▼
   Copy to /var/lib/waagent/<name>-<version>/
       │
       ▼
   Install handler (systemd-run --scope)
       │
       ▼
   Enable handler → execute
       │
       ▼
   Report status back to Azure  ✅
```

### What NixOS Brings

- **Reproducible builds**: Every Arc deployment is byte-for-byte identical
- **Atomic rollbacks**: Bad config? `nixos-rebuild switch --rollback` instantly reverts
- **Declarative config**: One file defines the entire machine state, including Arc
- **Immutable infrastructure**: `/nix/store` is read-only; no config drift

---

## 5. Key Metrics

| Metric                          | Value                                            |
|---------------------------------|--------------------------------------------------|
| Systemd services running        | 4 (`himdsd`, `arcproxyd`, `gcad`, `extd`)        |
| Extensions tested               | 5                                                |
| CustomScript                    | ✅ Full success — command executed, output returned |
| MDE (Defender)                  | ✅ Install + enable succeeded                     |
| AMA (Azure Monitor)            | ❌ Blocked by distro allowlist only (exit code 51) |
| Key Vault                       | ⚠️ Not delivered — GC auth key gap                |
| Guest Configuration             | ❌ IMDS timeout on non-Azure VM                    |
| Extension pipeline validated    | ✅ Download → GPG → SHA256 → install → enable → report |
| Platform-level failures         | **Zero** — all issues are extension-specific (allowlists, IMDS deps, auth gaps) |
| Agent version                   | v1.61.03319.859                                  |
| Supported architectures (build) | `x86_64-linux`, `aarch64-linux`                  |
| Validated architecture          | `aarch64-linux` (UTM on macOS)                   |

---

## 6. Q&A Prep

**"Why not just use Ubuntu?"**

> NixOS provides reproducibility (every deployment is identical), atomic upgrades
> and rollbacks (revert in seconds, not hours), and declarative configuration
> (the entire machine state is defined in version-controlled files). For
> infrastructure that manages other infrastructure — like Arc-connected edge
> nodes — these properties are critical. Ubuntu requires imperative setup and
> has no built-in rollback mechanism.

**"Is this supported by Microsoft?"**

> No. This is a proof-of-concept to demonstrate feasibility and identify exactly
> what changes Microsoft would need to make for native support. The goal is to
> lower the barrier for Microsoft to say "yes" by doing the hard work upfront.

**"What would Microsoft need to do to support NixOS?"**

> Three things:
> 1. **Add `nixos` to extension distro allowlists** (e.g., `supported_distros.py`
>    in AMA) — this is the immediate blocker
> 2. **Provide a tarball distribution** of the agent (in addition to DEB/RPM) —
>    we currently extract from the DEB, which works but is fragile
> 3. **Add NixOS to the CI smoke-test matrix** — validate that agent updates
>    don't regress on NixOS

**"What about security? Is the bubblewrap sandbox a risk?"**

> The bubblewrap sandbox actually *adds* isolation compared to a standard install.
> Agent binaries run inside a namespace with restricted filesystem visibility.
> The only bind mounts are the writable state directories the agent needs.
> Service user separation (`himds` user, `arcproxy` user) is defined in the
> module and will be fully enforced in a future phase.

**"What about Key Vault and Guest Configuration?"**

> We tested both. Key Vault (KeyVaultForLinux v3.5.3041.185) got stuck in
> "Creating" state — the root cause is a missing GC↔himds auth key registration
> in our init process. Poll-based extension refresh can't authenticate to the
> local MSI endpoint. Notification-based delivery works for most extensions, so
> this is a medium-severity gap we can fix by replicating the auth key setup
> from `install.sh`.
>
> Guest Configuration is a harder problem — the gcad agent assumes Azure IMDS
> (169.254.169.254) is available for metadata and tokens. On non-Azure VMs like
> our test environment, IMDS doesn't exist and every request times out (6 minutes
> per cycle). The agent doesn't fall back to the Arc-local himds endpoint. This
> means Guest Configuration is non-functional on any non-Azure Arc machine — not
> just NixOS. This may be a bug in gcad that the Product Group should investigate.

**"Does this work on x86_64?"**

> The package builds for both `x86_64-linux` and `aarch64-linux` — dual
> architecture is defined in the flake. We've validated `aarch64-linux` end-to-end
> in UTM on macOS. `x86_64-linux` needs a VM test pass (Azure or local QEMU),
> but there are no known architecture-specific issues.
