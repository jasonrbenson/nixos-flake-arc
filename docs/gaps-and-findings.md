# NixOS Azure Arc — Gaps and Findings

## Summary

This document captures the current state of Azure Arc extension compatibility on NixOS,
known gaps, root causes, and recommendations for the Azure Arc Product Group.

Testing was performed on an aarch64 NixOS 26.05 VM running in UTM on macOS, connected to
Azure Arc in AzureUSGovernment (usgovvirginia).

**Date**: 2026-03-19 (updated — Gaps 9 & 10 resolved)
**Agent Version**: 1.61.03319.859
**Architecture**: aarch64-linux

---

## Extension Compatibility Matrix

| Extension | Publisher | Download | GPG Validate | Install | Enable | Portal State | Root Cause of Failure |
|---|---|---|---|---|---|---|---|
| **Custom Script** v2.1.14 | Microsoft.Azure.Extensions | ✅ | ✅ | ✅ | ✅ | **Succeeded** | — |
| **MDE** v1.0.10.0 | Microsoft.Azure.AzureDefenderForServers | ✅ | ✅ | ✅ | ⚠️ | **Enabled** | Needs onboarding blob (config issue, not platform) |
| **AMA** v1.40.0 | Microsoft.Azure.Monitor | ✅ | ✅ | ❌ Exit 51 | — | **Failed** | Distro allowlist rejects `ID=nixos` |
| **Key Vault** v3.5.3041.185 | Microsoft.Azure.KeyVault | — | — | — | — | ⚠️ **Needs re-test** | MSI auth fixed; token dir permissions corrected. Needs re-test of full install flow. |
| **Guest Configuration** (AzureLinuxBaseline) | Microsoft.GuestConfiguration | ✅ | ✅ | ✅ | ✅ | **Working** | Pulls assignments, validates GPG signatures, runs compliance checks, reports to Azure GAS |
| **DSCForLinux** | Microsoft.OSTCExtensions | — | — | — | — | — | Not available in USGov region |

## What Works

### Core Agent
- `azcmagent connect` — machine registers and appears in Azure portal
- `azcmagent show` — reports NixOS 26.05, arm64, full machine inventory
- Heartbeat — continuous, visible in portal
- All 4 systemd services run inside bwrap FHS sandbox (himdsd, arcproxyd, gcad, extd)
- systemctl works inside the sandbox (`SYSTEMD_IGNORE_CHROOT=1`)
- Notification pipeline — himds receives extension events from Azure

### Extension Framework
- Extension download from Azure blob storage
- GPG signature validation of extension packages
- Extension unzip and extraction
- Extension install/enable script execution via `systemd-run --scope`
- Status reporting back to Azure (GC reports, telemetry)
- Extension lifecycle (install → enable → status reporting)

### Custom Script Extension (Full Success)
The Custom Script Extension works end-to-end on NixOS. It is a native Go binary
(`custom-script-extension-arm64`) with no OS-specific checks.

```
Enable succeeded:
[stdout]
hello-from-nixos
Linux arc-test 6.18.18 #1-NixOS SMP ... aarch64 GNU/Linux
```

### MDE Extension (Partial Success)
MDE's install/enable handlers run successfully. The Python handler executes, retrieves
the Azure Resource ID from the local IMDS endpoint, and attempts configuration. The
"failure" is purely a configuration issue — we deployed without a Defender for Endpoint
onboarding blob. **MDE does not perform a distro check.**

---

## Known Gaps

### Gap 1: AMA Distro Allowlist (BLOCKING)

**Severity**: High — blocks AMA deployment on NixOS
**Extension**: Azure Monitor Agent (AMA) v1.40.0
**Error**: Exit code 51 — `UnsupportedOperatingSystem`

**Root Cause**: AMA's `agent.py` reads `/etc/os-release`, extracts `ID=nixos`, and checks
it against a hardcoded allowlist in `ama_tst/modules/install/supported_distros.py`:

```python
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

NixOS is not in this list. The check happens before any actual installation logic, so
the extension never gets a chance to run.

**Impact**: AMA is the primary monitoring extension for Azure Arc. Without it, NixOS
machines cannot send metrics/logs to Azure Monitor via the standard Arc pipeline.

**Recommendation to Product Group**:
1. Add `'nixos'` to the supported distros list (simplest fix)
2. Or: Make the distro check a warning rather than a hard block for Arc machines,
   since the FHS sandbox provides all required dependencies
3. Or: Allow a `--force-install` flag or extension setting to bypass the check

**Workaround**: Modify the downloaded extension's `supported_distros.py` to include
`'nixos': ['26.05']` after download. This is fragile and breaks on extension updates.

### Gap 2: Missing Tools in FHS Sandbox

Several tools that extensions expect were missing from the initial FHS sandbox
configuration. These have been resolved but are documented for reference:

| Tool | Required By | Error | Resolution |
|---|---|---|---|
| `gpg` | Extension package validator | `gpg: command not found` during SHA256 signature verification | Added `gnupg` to `targetPkgs` |
| `python3` | AMA, MDE handlers | `No Python interpreter found` | Added `python3` to `targetPkgs` |
| `libstdc++.so.6` | gc_linux_service | Shared library load failure | Added `stdenv.cc.cc.lib` to `targetPkgs` |
| `libpam.so.0` | GC components | Shared library load failure | Added `linux-pam` to `targetPkgs` |
| `lsof` | CustomScript shim | `lsof: command not found` (non-fatal warning) | Not yet added; optional |

### Gap 3: Read-Only /opt Inside bwrap

**Severity**: Medium — resolved via bind-mount overlay
**Root Cause**: `buildFHSEnv` mounts the rootfs `/opt` as `--ro-bind`. Extensions need to
write to `/opt/GC_Ext/` for downloads, config, and sockets.

**Resolution**: Created writable host directories at `/var/opt/azcmagent/opt-{azcmagent,gc-ext,gc-service}/`
and used `extraBwrapArgs` to `--bind` mount them over the read-only rootfs paths.

### Gap 4: Missing GC Initialization Files

**Severity**: High — blocked extension processing entirely
**Root Cause**: The `install.sh` script that Microsoft's DEB/RPM packages run creates:
- `gc.config` file with `{"ServiceType": "Extension"}` or `{"ServiceType": "GCArc"}`
- `sockets/` directory for IPC between GC components

Our FHS sandbox skipped `install.sh`, so these were never created.

**Resolution**: The `azure-arc-init` oneshot service now creates these files and sets
proper permissions after populating writable overlays from the nix store.

### Gap 5: File Permissions from Nix Store

**Severity**: Medium — resolved in init service
**Root Cause**: Files copied from the nix store via `rsync` retain read-only permissions
(e.g., `r--r--r--`). GC binaries need execute permission; config files need write access.

**Resolution**: `chmod -R u+w` after rsync in the init service.

### Gap 6: MDE Onboarding Configuration

**Severity**: Low — configuration issue, not platform gap
**Root Cause**: MDE requires a Defender for Endpoint onboarding blob passed via
`protectedSettings` during extension creation. Without it, the handler fails with:
```
Protected Settings did not decoded
Failed to configure Microsoft Defender for Endpoint: argument of type 'NoneType' is not iterable
```

**Resolution**: Deploy MDE with onboarding settings from a Defender for Endpoint workspace.
See [MDE Onboarding](#mde-onboarding-instructions) below.

### Gap 7: Service Startup Race Condition — ✅ MITIGATED

**Severity**: ~~Low~~ → Mitigated
**Root Cause**: When all services restart simultaneously (e.g., during `nixos-rebuild switch`),
gcad and extd may start before himdsd has loaded its config, causing 503 "Service Unavailable"
errors on the first timer cycle.

**Mitigation**: Added `ExecStartPre` readiness checks to gcad and extd that poll
`https://localhost:40341/metadata/instance` for up to 30 seconds before starting.
Also added `requires = ["himdsd.service"]` dependency for gcad (extd already had this).
The first poll cycle now succeeds reliably.

### Gap 8: `azcmagent extension list` Fails

**Severity**: Low — cosmetic
**Root Cause**: The `extension list` subcommand attempts to `systemctl disable/enable`
services, which fails on NixOS because systemd units are managed declaratively. This
doesn't affect actual extension operations — only the CLI query.

### Gap 9: GC↔himds MSI Auth Key — ✅ RESOLVED

**Severity**: ~~Medium~~ → Resolved
**Extension**: Key Vault for Linux (KeyVaultForLinux) v3.5.3041.185
**Error**: `Failed to get the msi authentication key`

**Root Cause**: The `/var/opt/azcmagent/tokens/` directory was owned by `root:himds` with
mode `0750`. himds could read existing key files but could **not create** new ones. The MSI
token flow uses challenge-response authentication: when a GC component requests a token,
himds creates a temporary `.key` file in the tokens directory as a challenge. The component
reads the key, sends it back as proof of local access, and receives the token. With the old
permissions, himds couldn't create the challenge key file, breaking the entire flow.

**Fix**: Changed token directory to `himds:himds 0770` and updated `ExecStartPre` to
chown the tokens directory and any existing `.key` files to `himds:himds`. Both extd and
gcad can now successfully authenticate and receive MSI tokens from himds.

**Previous incorrect hypothesis**: We initially believed a pre-shared key established
during `install.sh` was needed. This was wrong — the auth mechanism is challenge-response
using the tokens directory, and only required correct file permissions.

### Gap 10: Guest Configuration Agent ServiceType Configuration — ✅ RESOLVED

**Severity**: ~~High~~ → Resolved
**Component**: gcad (Guest Configuration agent daemon)

**Root Cause**: The `gc.config` file for the GC_Service component was set to
`{"ServiceType" : "GuestConfiguration"}` — the mode intended for Azure VMs that have
IMDS access. The correct mode for Arc-connected machines is `{"ServiceType" : "GCArc"}`,
which tells gcad to use the local himds endpoint (localhost:40341) for identity, metadata,
and token operations instead of Azure IMDS (169.254.169.254).

With `"GuestConfiguration"` mode, gcad attempted to reach IMDS for VM tags, resource ID,
and MSI tokens. Since IMDS doesn't exist on non-Azure machines, every request timed out
(~2 min each, 3 per cycle = 6 minutes wasted), and the entire refresh cycle failed.

**Fix**: Changed gc.config to `{"ServiceType" : "GCArc"}`. The install.sh in the DEB
package also writes `"GCArc"` — our original `"GuestConfiguration"` was a misidentification
of the correct value.

**Result after fix**:
- gcad successfully queries himds for metadata and MSI tokens
- AzureLinuxBaseline policy assignment pulled from Azure GAS
- GPG signature validation passes
- Compliance checks run and complete
- Assignment heartbeats sent successfully to `usgovvirginia-gas.guestconfiguration.azure.us`
- gcad writes to `arc_policy_logs/gc_agent.log` (not `gc_agent_logs/`) in GCArc mode

**Note**: The first timer cycle after boot may fail if himds hasn't loaded its config yet
(503 "Service Unavailable"). This is mitigated with an `ExecStartPre` readiness check
that polls himds for up to 30 seconds before starting gcad/extd.

---

## FHS Sandbox Dependencies

The following packages are required in the `buildFHSEnv` `targetPkgs` for full extension
support:

```nix
targetPkgs = pkgs: [
  pkgs.openssl       # TLS for Azure communication
  pkgs.zlib          # Compression
  pkgs.glibc         # C runtime
  pkgs.icu           # Unicode support
  pkgs.curl          # HTTP client
  pkgs.lttng-ust     # Tracing
  pkgs.systemd       # systemctl, journalctl
  pkgs.libgcc.lib    # GCC runtime
  pkgs.stdenv.cc.cc.lib  # libstdc++.so.6
  pkgs.linux-pam     # PAM authentication
  pkgs.gnupg         # GPG signature validation
  pkgs.python3       # Extension handlers (AMA, MDE)
];
```

---

## MDE Onboarding Instructions

To fully enable MDE on the Arc-connected NixOS machine:

1. **Get an onboarding blob** from Microsoft Defender for Endpoint:
   - Go to [Microsoft Defender portal](https://security.microsoft.com) (or security.microsoft.us for GCC-High)
   - Navigate to **Settings** → **Endpoints** → **Onboarding**
   - Select **Linux Server** as the OS
   - Download the onboarding package or copy the workspace ID and key

2. **Deploy with settings**:
   ```bash
   az connectedmachine extension create \
     --machine-name arc-test \
     --resource-group arc-testing \
     --name MDE.Linux \
     --publisher Microsoft.Azure.AzureDefenderForServers \
     --type MDE.Linux \
     --location usgovvirginia \
     --settings '{"azureResourceId":"/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.HybridCompute/machines/arc-test","defenderForServersWorkspaceId":"<workspace-id>","forceReOnboarding":true}'
   ```

3. **Note**: MDE will also need to install its own mdatp daemon package. On NixOS, this
   may require additional FHS sandbox dependencies or a separate systemd service. The
   extension handler itself works — the question is whether mdatp's native binaries will
   run correctly inside the sandbox.

---

## Recommendations for Azure Arc Product Group

### Short Term (Extension-Level Fixes)
1. **Add NixOS to AMA's distro allowlist** — NixOS inside the FHS sandbox provides all
   dependencies AMA needs. The allowlist check is the only blocker.
2. **Make distro checks configurable** — Allow a `--skip-distro-check` flag or extension
   setting for validated non-standard distros.

### Medium Term (Agent-Level Improvements)
3. **Document the GC initialization requirements** — The need for `gc.config` (with correct
   `ServiceType`), `sockets/`, and proper token directory permissions aren't documented
   outside of `install.sh`. This makes non-DEB/RPM packaging difficult.
4. **Provide a tarball distribution** — A `.tar.gz` with a simple `setup.sh` (instead of
   DEB/RPM only) would make packaging for Nix, Guix, Alpine, etc. much easier.
5. **Document gc.config ServiceType values** — `"GCArc"` vs `"Extension"` vs
   `"GuestConfiguration"` behavior should be documented. Using the wrong value causes
   silent failures (IMDS timeouts) with no helpful error message.

### Long Term (Native NixOS Support)
5. **Publish agent binaries to a neutral registry** — OCI images, static tarballs, or a
   GitHub release would enable community packaging.
6. **Test on NixOS in CI** — Add NixOS to the Arc agent's test matrix.
7. **Consider declarative extension config** — NixOS users expect declarative configuration.
   An extension manifest format (instead of imperative portal/CLI operations) would be
   more natural.
