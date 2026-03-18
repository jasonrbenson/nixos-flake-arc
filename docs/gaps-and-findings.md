# NixOS Azure Arc — Gaps and Findings

## Summary

This document captures the current state of Azure Arc extension compatibility on NixOS,
known gaps, root causes, and recommendations for the Azure Arc Product Group.

Testing was performed on an aarch64 NixOS 26.05 VM running in UTM on macOS, connected to
Azure Arc in AzureUSGovernment (usgovvirginia).

**Date**: 2026-03-18
**Agent Version**: 1.61.03319.859
**Architecture**: aarch64-linux

---

## Extension Compatibility Matrix

| Extension | Publisher | Download | GPG Validate | Install | Enable | Portal State | Root Cause of Failure |
|---|---|---|---|---|---|---|---|
| **Custom Script** v2.1.14 | Microsoft.Azure.Extensions | ✅ | ✅ | ✅ | ✅ | **Succeeded** | — |
| **MDE** v1.0.10.0 | Microsoft.Azure.AzureDefenderForServers | ✅ | ✅ | ✅ | ⚠️ | **Enabled** | Needs onboarding blob (config issue, not platform) |
| **AMA** v1.40.0 | Microsoft.Azure.Monitor | ✅ | ✅ | ❌ Exit 51 | — | **Failed** | Distro allowlist rejects `ID=nixos` |
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
- `gc.config` file with `{"ServiceType": "Extension"}` or `{"ServiceType": "GuestConfiguration"}`
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

### Gap 7: Service Startup Race Condition

**Severity**: Low — transient
**Root Cause**: When all services restart simultaneously (e.g., during `nixos-rebuild switch`),
extd may start before himdsd is ready, causing 503 errors from the local IMDS endpoint.
These resolve on the next polling cycle (typically within 5 minutes).

### Gap 8: `azcmagent extension list` Fails

**Severity**: Low — cosmetic
**Root Cause**: The `extension list` subcommand attempts to `systemctl disable/enable`
services, which fails on NixOS because systemd units are managed declaratively. This
doesn't affect actual extension operations — only the CLI query.

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
3. **Document the GC initialization requirements** — The need for `gc.config` and `sockets/`
   isn't documented outside of `install.sh`. This makes non-DEB/RPM packaging difficult.
4. **Provide a tarball distribution** — A `.tar.gz` with a simple `setup.sh` (instead of
   DEB/RPM only) would make packaging for Nix, Guix, Alpine, etc. much easier.

### Long Term (Native NixOS Support)
5. **Publish agent binaries to a neutral registry** — OCI images, static tarballs, or a
   GitHub release would enable community packaging.
6. **Test on NixOS in CI** — Add NixOS to the Arc agent's test matrix.
7. **Consider declarative extension config** — NixOS users expect declarative configuration.
   An extension manifest format (instead of imperative portal/CLI operations) would be
   more natural.
