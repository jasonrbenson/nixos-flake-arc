# NixOS Azure Arc — Gaps and Findings

## Summary

This document captures the current state of Azure Arc extension compatibility on NixOS,
known gaps, root causes, and recommendations for the Azure Arc Product Group.

Testing was performed on an aarch64 NixOS 26.05 VM running in UTM on macOS, connected to
Azure Arc in AzureUSGovernment (usgovvirginia).

**Date**: 2026-03-20 (updated — Gaps 9, 10, 11 resolved; Gap 12 added; AMA & MDE patched)
**Agent Version**: 1.61.03319.859
**Architecture**: aarch64-linux

---

## Extension Compatibility Matrix

| Extension | Publisher | Download | GPG Validate | Install | Enable | Portal State | Root Cause of Failure |
|---|---|---|---|---|---|---|---|
| **Custom Script** v2.1.14 | Microsoft.Azure.Extensions | ✅ | ✅ | ✅ | ✅ | **Succeeded** | — |
| **AMA** v1.40.0 | Microsoft.Azure.Monitor | ✅ | ✅ | ✅ | ✅ | **Working** | Runtime patcher bypasses distro allowlist; 3 services running |
| **MDE** v1.0.10.0 | Microsoft.Azure.AzureDefenderForServers | ✅ | ✅ | ✅ | ⏳ | **Patched** | 7 runtime patches applied; reaches apt install step |
| **Key Vault** v3.5.3041.185 | Microsoft.Azure.KeyVault | ✅ | ✅ | ✅ | ✅ | **Succeeded** | Empty `observedCertificates` (config, not platform) |
| **ChangeTracking** v2.35.0.0 | Microsoft.Azure.ChangeTrackingAndInventory | ✅ | ✅ | ❌ Exit 126 | — | **Failed** | x86_64 binary only — `Exec format error` on aarch64. **Not NixOS-related.** |
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

### Gap 1: AMA Distro Allowlist — ✅ RESOLVED (Runtime Patcher)

**Severity**: ~~High~~ → Resolved via runtime patcher
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

NixOS is not in this list.

**Fix**: `arc-ama-patcher` systemd timer (10s interval) patches the downloaded extension
after it's extracted to `/var/lib/waagent/`. Patches applied:
1. Adds `'nixos': ['26.05']` to the distro allowlist
2. Forces dpkg-based installation (bypasses package manager detection)
3. Uses mdsd binary directly for enable handler (skips systemctl start pattern)

**Result**: AMA fully operational with 3 services running (mdsd, amacoreagent, mdsdhelper).

**Recommendation to Product Group**: Add NixOS to the allowlist natively so the patcher
is not needed.

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

### Gap 6: MDE Extension NixOS Compatibility — ⏳ PATCHED (7 Runtime Patches)

**Severity**: Medium — patched via runtime patcher, testing in progress
**Extension**: MDE (Microsoft Defender for Endpoint) v1.0.10.0

**Root Cause**: MDE has multiple NixOS incompatibilities across its Python handler and
bash installer. Unlike AMA (single distro check), MDE needed 7 separate patches:

**Patches applied by `arc-mde-patcher` (10s timer interval)**:

1. **Distro detection** (`mde_installer.sh`): Inserts `nixos` → `debian` family mapping
   before the `sles` elif block, so the installer detects NixOS as debian-family.

2. **Repo URL mapping** (`mde_installer.sh`): Maps nixos to `ubuntu/24.04` for Microsoft
   Package Manager (PMC) repository URLs.

3. **SSL certs + debug mode** (`PythonRunner.sh`): Exports `SSL_CERT_FILE` and
   `SSL_CERT_DIR` (NixOS nix-store paths), and sets `MdeExtensionDebugMode=true`.

4a. **publicSettings None guard** (`MdeExtensionHandler.py`): Adds `is None` check to
    `get_parameter_from_public_settings()` — on Arc (no WALinuxAgent), `publicSettings`
    is None, causing `TypeError: argument of type 'NoneType' is not iterable`.

4b. **workspace_id None guard** (`MdeExtensionHandler.py`): Same None guard for
    `get_security_workspace_id()`.

4c. **protectedSettings None guard** (`MdeExtensionHandler.py`): Same None guard for
    `get_parameter_from_protected_settings()`.

4d. **Skip publicSettings empty check** (`MdeExtensionHandler.py`): Replaces fatal
    `throw_and_write_log` with `pass` when publicSettings is empty/None.

**Key Discovery — GitHub Script Download**:
MDE's `MdeInstallerWrapper.py` downloads a newer `mde_installer.sh` from GitHub at
runtime, saving it as `mde_installer.latest.sh` and using that instead of the bundled
(patched) version. Setting `MdeExtensionDebugMode=true` forces use of the bundled script.

**Key Discovery — install.status Lock**:
MDE creates an `install.status` lock file that prevents re-enable for 36 minutes
(TIMEOUT_INSTALL_ACTION=2100s + 60s) after first attempt. Must be manually deleted
to force re-enable sooner.

**Current Status**: Installer reaches `apt -y install curl apt-transport-https gnupg`
step. `pkgs.apt` added to FHS sandbox. Expected additional blockers: apt repo
configuration, Microsoft GPG key import, mdatp package installation.

**Previous incorrect assessment**: Gap 6 originally stated MDE "does not perform a distro
check." In fact, `mde_installer.sh` has extensive distro detection that fails on NixOS.

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

### Gap 11: Extension Service Binaries Need FHS Wrapping — ✅ RESOLVED

**Severity**: ~~Medium~~ → Resolved
**Extension**: Key Vault for Linux (KeyVaultForLinux) v3.5.3041.185

**Root Cause**: The KeyVault extension install handler creates a systemd unit
(`akvvm_service.service`) that executes the `akvvm_service` binary directly. This binary
is dynamically linked (expects `/lib/ld-linux-aarch64.so.1`) and fails with exit code 127
when host systemd runs it outside the bwrap FHS sandbox. The install and enable steps
succeed — only the long-running service itself fails.

**Fix**: A generalized extension wrapping framework with two layers:

1. **systemctl wrapper (bwrap-side)**: Intercepts `daemon-reload` inside the bwrap sandbox.
   Before calling the real daemon-reload, it scans `/run/systemd/system/*.service` for units
   with `ExecStart=/var/lib/waagent/...` (extension binaries) and prepends
   `/run/current-system/sw/bin/azcmagent-fhs` to their `ExecStart`. This is the primary
   mechanism — it runs during the extension install flow.

2. **arc-ext-fhs-wrapper timer (host-side)**: A systemd timer that runs every 5 minutes as
   a safety net, performing the same scan/patch for any units that might have been missed.

The framework is generic — any extension that creates a systemd unit with binaries in
`/var/lib/waagent/` gets automatically wrapped to run inside the FHS sandbox.

**Test results (KeyVault)**:
- Install handler: exit 0 ✅
- Enable handler: exit 0 ✅
- Unit file automatically patched:
  `ExecStart=/run/current-system/sw/bin/azcmagent-fhs /var/lib/waagent/.../arm64/akvvm_service`
- Binary runs through FHS sandbox successfully
- Status file written and reported to Azure ✅
- Service exits 1 due to empty `observedCertificates` — a config issue, not a platform issue

**Previous partial fix** (now superseded):
- `/etc/systemd/system` inside bwrap is symlinked to `/run/systemd/system` (host-writable)
- `systemctl` wrapper adds `--runtime` to enable/disable (writes to `/run/systemd/system/`)
- Install script completes successfully (daemon-reload finds unit, enable creates symlink)

### Gap 13: Extension Binary CWD Mismatch — ✅ RESOLVED

**Severity**: ~~Medium~~ → Resolved
**Extension**: Key Vault for Linux (KeyVaultForLinux) v3.5.3041.185

**Root Cause**: The FHS exec wrapper script did `cd "$(dirname "$1")"` for all binaries.
For extension binaries in architecture subdirectories (e.g., `arm64/akvvm_service`), this
set the working directory to `arm64/` instead of the extension root. The binary couldn't
find `./HandlerEnvironment.json` (which lives in the extension root), causing:
- No status file written → Azure showed "Creating" indefinitely
- No log files created → silent failure
- Service crash-loops with exit 1 (no output)

**Symptoms**:
- Azure portal showed "Creating" with "No status file created yet" for days
- Service journal showed rapid crash-loop: `Main process exited, code=exited, status=1/FAILURE`
- Only discoverable via strace (which ran slower and happened to work due to different CWD)

**Fix**: Updated the exec wrapper to skip the `cd dirname($1)` for extension binaries
(`/var/lib/waagent/*`). These binaries rely on systemd's `WorkingDirectory` (set by the
extension's install script), which bwrap preserves via `--chdir "$(pwd)"`. Core agent
binaries (`/opt/azcmagent/bin/*`) still get the `cd` for RPATH "." resolution.

**Result after fix**:
- `akvvm_service` reads `HandlerEnvironment.json` successfully ✅
- Writes `0.status` with proper error message ✅
- Azure portal updated from "Creating" to "Failed" with actual error: `"observedCertificates cannot be empty"` ✅
- Log files created in extension_logs directory ✅
- The remaining failure is purely a config issue (no certificates configured), not a platform issue

### Gap 12: ChangeTracking Extension — No ARM64 Binaries

**Severity**: Medium — architecture limitation, not NixOS-related
**Extension**: ChangeTracking-Linux v2.35.0.0
**Publisher**: Microsoft.Azure.ChangeTrackingAndInventory
**Error**: Exit code 126 — `cannot execute binary file: Exec format error`

**Root Cause**: The ChangeTracking extension ships only x86_64 (amd64) binaries:
- `cta_linux_handler`: ELF 64-bit x86_64 Go binary (handler)
- `change-tracking-retail_0.1.03151.216-1_amd64.deb`: amd64 only
- `change_tracking_retail-0.1.03151.216-1.x86_64.rpm`: x86_64 only

Our test VM runs aarch64 (Apple Silicon QEMU). Unlike KeyVault (which ships both
`amd64/akvvm_service` and `arm64/akvvm_service`), ChangeTracking has no arm64 variant.

**Impact**: Cannot test or use ChangeTracking on arm64 NixOS machines. NixOS-specific
compatibility (distro checks, path issues) is **untested** — the binary fails before any
NixOS-related code runs.

**Note**: The handler is a Go binary, so once arm64 support is added by Microsoft, it
may work with our existing extension wrapping framework (like KeyVault does) with
minimal or no NixOS-specific patches needed.

**Recommendation to Product Group**: Ship arm64 (aarch64) binaries for ChangeTracking.
KeyVault already demonstrates multi-arch binary shipping for the same extension pipeline.

---

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
  pkgs.apt           # MDE prerequisite package installation
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
   dependencies AMA needs. The allowlist check is the only blocker. (Currently resolved
   via runtime patcher, but native support is preferred.)
2. **Make distro checks configurable** — Allow a `--skip-distro-check` flag or extension
   setting for validated non-standard distros.
3. **Ship arm64 binaries for ChangeTracking** — KeyVault already demonstrates multi-arch
   shipping. ChangeTracking should follow the same pattern.
4. **Fix MDE publicSettings None handling on Arc** — The Python handler assumes
   `publicSettings` and `protectedSettings` are always present (WALinuxAgent behavior).
   On Arc, they may be None, causing TypeError crashes.

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
