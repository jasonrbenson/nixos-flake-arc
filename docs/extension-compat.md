# Azure Arc Extension Compatibility Matrix for NixOS

## Overview

Azure Arc extensions are managed by the Extension Manager (extd) component of the
Connected Machine Agent. Extensions are downloaded to `/var/lib/GuestConfig/downloads/`,
validated via GPG signature, and installed to `/var/lib/waagent/<extension>/`. All of this
runs inside the FHS bubblewrap sandbox.

## Tested Extensions

Testing performed on aarch64 NixOS 26.05, agent v1.61, AzureUSGovernment (usgovvirginia).

| Extension | Publisher | Type | Version | Handler | Result | Details |
|---|---|---|---|---|---|---|
| Custom Script | Microsoft.Azure.Extensions | CustomScript | 2.1.14 | Go binary (arm64) | ✅ **Full Success** | Native Go binary, no OS checks. Ran commands and returned output to Azure. |
| AMA | Microsoft.Azure.Monitor | AzureMonitorLinuxAgent | 1.40.0 | Python/Shell | ✅ **Working** (patched) | Runtime patcher bypasses distro allowlist, adds NixOS to supported distros. 3 AMA services running (mdsd, amacoreagent, mdsdhelper). |
| MDE | Microsoft.Azure.AzureDefenderForServers | MDE.Linux | 1.0.10.0 | Python/Bash | ⏳ **Patched** | 7 runtime patches: distro detection, repo mapping, SSL certs, debug mode, 4× Python None guards. Reaches apt package installation step. |
| Key Vault | Microsoft.Azure.KeyVault | KeyVaultForLinux | 3.5.3041.185 | Go binary (amd64+arm64) | ✅ **Full Success** | Ships both amd64 and arm64 binaries. Install/enable handlers succeed. Extension service binary (`akvvm_service`) automatically wrapped to run inside FHS sandbox via the extension wrapping framework. Service exits 1 due to empty `observedCertificates` — a config issue, not a platform issue. |
| ChangeTracking | Microsoft.Azure.ChangeTrackingAndInventory | ChangeTracking-Linux | 2.35.0.0 | Go binary (amd64 only) | ❌ **Arch Mismatch** | Ships only x86_64 binaries (`cta_linux_handler`, .deb, .rpm). Fails with `Exec format error` on aarch64. **Not a NixOS issue** — Microsoft doesn't ship arm64 binaries. Would need testing on x86_64 hardware. |
| Guest Configuration | Microsoft.GuestConfiguration | ConfigurationforLinux | — | Go binary | ✅ **Working** | Pulls assignments from Azure GAS, validates GPG signatures, runs compliance checks (AzureLinuxBaseline tested), sends heartbeats. Requires `gc.config` with `{"ServiceType": "GCArc"}` — see [Gap 10](gaps-and-findings.md#gap-10-guest-configuration-agent-servicetype-configuration--resolved). Logs to `arc_policy_logs/gc_agent.log` in GCArc mode. |
| DSCForLinux | Microsoft.OSTCExtensions | DSCForLinux | — | — | ⛔ **Unavailable** | Not available in USGov Virginia (cloud/region limitation, not NixOS-related). |

## Extension Handler Types

| Handler Type | Architecture Dependent? | NixOS Patcher Strategy |
|---|---|---|
| **Shell/Python scripts** | No — runs on any arch | Runtime patcher modifies scripts after download to fix distro checks, paths, SSL |
| **Go binary (multi-arch)** | Ships both amd64+arm64 | Auto-wrapped via extension wrapping framework to run in FHS sandbox |
| **Go binary (amd64 only)** | x86_64 only | ❌ Cannot run on aarch64 — Microsoft must ship arm64 binaries |

## Untested Extensions

| Extension | Publisher | Type | Expected Outcome | Notes |
|---|---|---|---|---|
| Azure Update Manager | Microsoft.SoftwareUpdateConfiguration | LinuxOsUpdateExtension | ❓ Unknown | Fundamentally incompatible with NixOS declarative updates |

## Extension Pipeline Validation

The full extension delivery pipeline has been validated on NixOS:

1. ✅ Azure notification → himds receives extension event
2. ✅ extd polls for pending extensions
3. ✅ Extension package downloaded from Azure blob storage
4. ✅ GPG signature validation (requires `gnupg` in sandbox)
5. ✅ SHA256 checksum verification
6. ✅ Package unzipped to `/var/lib/GuestConfig/downloads/`
7. ✅ Extension copied to `/var/lib/waagent/<name>-<version>/`
8. ✅ Install handler executed via `systemd-run --scope`
9. ✅ Enable handler executed
10. ✅ Status reported back to Azure (GC agent service reports)

## Known Challenges

### AMA (Azure Monitor Agent) — ✅ Working (Runtime Patcher)
- **Previously blocked by distro allowlist** — `agent.py` checks `ID` from `/etc/os-release`
  against `supported_distros.py`. NixOS is not listed.
- **Resolved**: `arc-ama-patcher` systemd timer (10s interval) patches the downloaded extension
  to add NixOS to the supported distros list and force dpkg-based installation. Patches:
  1. Distro allowlist: adds `'nixos': ['26.05']` to supported_dists_aarch64
  2. dpkg install override: forces dpkg fallback instead of package manager checks
  3. Enable handler: uses `mdsd` binary directly (skips `systemctl start` pattern)
- All 3 AMA services running: mdsd, amacoreagent, mdsdhelper
- Recommendation to PG: Add NixOS to the allowlist natively

### MDE (Microsoft Defender for Endpoint) — ⏳ Patched, Testing
- **7 runtime patches** applied via `arc-mde-patcher` systemd timer (10s interval):
  1. Distro detection: maps `nixos` → `debian` family in `mde_installer.sh`
  2. Repo URL mapping: maps nixos to `ubuntu/24.04` for PMC packages
  3. SSL certs + debug mode: exports SSL_CERT_FILE, SSL_CERT_DIR, MdeExtensionDebugMode=true
  4a-4d. Python None guards: fixes TypeError in publicSettings/protectedSettings handling
- **Key finding**: MDE downloads newer scripts from GitHub at runtime, bypassing patches.
  Fixed by setting `MdeExtensionDebugMode=true` which forces use of bundled (patched) script.
- **Key finding**: `install.status` lock file prevents re-enable for 36 minutes after first attempt.
- MDE installer reaches package installation step and needs `apt` for prerequisites.
- `pkgs.apt` added to FHS sandbox for MDE package installation.
- Additional blocker expected: mdatp .deb package installation and service startup

### ChangeTracking — ❌ Architecture Mismatch (Not NixOS-Related)
- **Not a NixOS issue** — the ChangeTracking extension ships only x86_64 binaries:
  - `cta_linux_handler`: ELF x86_64 Go binary
  - `change-tracking-retail_0.1.03151.216-1_amd64.deb`
  - `change_tracking_retail-0.1.03151.216-1.x86_64.rpm`
- Fails with `Exec format error` (exit 126) on our aarch64 test VM
- Unlike KeyVault (which ships both amd64 and arm64 binaries), ChangeTracking has no arm64 support
- **Requires x86_64 hardware to test NixOS compatibility**
- Recommendation to PG: Ship arm64 binaries for ChangeTracking extension

### Key Vault (KeyVaultForLinux)
- ✅ Extension install and enable handlers both succeed (exit code 0)
- **Fix applied**: `/etc/systemd/system` inside bwrap is symlinked to `/run/systemd/system`
  so the install script can write the `akvvm_service.service` unit file to a host-writable
  location that systemd's unit search path already includes
- **Fix applied**: `systemctl` wrapper adds `--runtime` to `enable`/`disable`, writing
  symlinks to `/run/systemd/system/` instead of read-only `/etc/systemd/system/`
- ✅ **Resolved**: Extension service wrapping framework automatically patches the unit file's
  `ExecStart` to run the binary through the `azcmagent-fhs` wrapper. The `akvvm_service`
  binary now runs inside the FHS sandbox.
- Service exits 1 due to empty `observedCertificates` — a config issue, not a platform issue

### Guest Configuration (gcad)
- ✅ Fully working on Arc-connected machines with `gc.config` ServiceType set to `"GCArc"`
- Pulls policy assignments from Azure GAS, validates GPG signatures, runs compliance checks
- Logs to `arc_policy_logs/gc_agent.log` (not `gc_agent_logs/`) in GCArc mode

### Azure Update Manager
- Fundamentally incompatible with NixOS's declarative update model
- Would need a shim that translates update requests to `nixos-rebuild`
- Low priority — NixOS has its own superior update story

## Extension Service Wrapping Framework

Extensions that create long-running systemd services (e.g., KeyVault's `akvvm_service`)
ship dynamically linked binaries that cannot run directly on NixOS outside the FHS sandbox.
A generic wrapping framework automatically patches these services:

### How It Works

1. **systemctl wrapper (bwrap-side, primary mechanism)**: When an extension's install script
   calls `systemctl daemon-reload` inside the bwrap sandbox, the wrapper intercepts the call.
   Before invoking the real `daemon-reload`, it scans all `*.service` files in
   `/run/systemd/system/` for units whose `ExecStart` points to a binary under
   `/var/lib/waagent/` (the extension install directory). For each match, it prepends
   `/run/current-system/sw/bin/azcmagent-fhs` to the `ExecStart` line, ensuring the binary
   runs inside the FHS sandbox when systemd starts the unit.

2. **arc-ext-fhs-wrapper timer (host-side, safety net)**: A systemd timer fires every
   5 minutes and performs the same scan/patch. This catches any units that may have been
   created or recreated outside the normal install flow (e.g., extension updates, manual
   restarts).

### Result

Any extension that creates a systemd unit with binaries in `/var/lib/waagent/` is
automatically wrapped — no per-extension configuration required. The patched unit looks like:

```ini
ExecStart=/run/current-system/sw/bin/azcmagent-fhs /var/lib/waagent/<extension>/<version>/<binary>
```

### Validated Extensions

| Extension | Service Unit | Status |
|---|---|---|
| Key Vault (KeyVaultForLinux) | `akvvm_service.service` | ✅ Auto-wrapped, runs in FHS sandbox |

## Testing Protocol

For each extension:
1. Deploy via `az connectedmachine extension create`
2. Monitor `/var/lib/GuestConfig/ext_mgr_logs/gc_ext.log` for delivery progress
3. Check state at `/var/lib/GuestConfig/extension_logs/<name>-<version>/state.json`
4. Check stderr/stdout in the same directory
5. Verify portal status via `az connectedmachine extension list`
6. Document any missing sandbox dependencies
7. Test extension removal
