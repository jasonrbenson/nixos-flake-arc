# Azure Arc Extension Compatibility Matrix for NixOS

## Overview

Azure Arc extensions are managed by the Extension Manager (extd) component of the
Connected Machine Agent. Extensions are downloaded to `/var/lib/GuestConfig/downloads/`,
validated via GPG signature, and installed to `/var/lib/waagent/<extension>/`. All of this
runs inside the FHS bubblewrap sandbox.

## Tested Extensions

Testing performed on aarch64 NixOS 26.05, agent v1.61, AzureUSGovernment (usgovvirginia).

| Extension | Publisher | Type | Version | Result | Details |
|---|---|---|---|---|---|
| Custom Script | Microsoft.Azure.Extensions | CustomScript | 2.1.14 | ✅ **Full Success** | Native Go binary, no OS checks. Ran commands and returned output to Azure. |
| MDE | Microsoft.Azure.AzureDefenderForServers | MDE.Linux | 1.0.10.0 | ✅ **Install OK** | Python handler runs. Needs Defender onboarding blob for full activation. No distro check. |
| AMA | Microsoft.Azure.Monitor | AzureMonitorLinuxAgent | 1.40.0 | ❌ **Blocked** | Exit 51: `UnsupportedOperatingSystem`. Hardcoded distro allowlist rejects `ID=nixos`. |
| DSCForLinux | Microsoft.OSTCExtensions | DSCForLinux | — | ⛔ **Unavailable** | Not available in USGov Virginia (cloud/region limitation, not NixOS-related). |

## Untested Extensions

| Extension | Publisher | Type | Expected Outcome | Notes |
|---|---|---|---|---|
| Azure Update Manager | Microsoft.SoftwareUpdateConfiguration | LinuxOsUpdateExtension | ❓ Unknown | Fundamentally incompatible with NixOS declarative updates |
| Key Vault | Microsoft.Azure.KeyVault | KeyVaultForLinux | ❓ Likely works | Certificate management, probably no OS check |
| Guest Configuration | Microsoft.GuestConfiguration | ConfigurationforLinux | ❓ Unknown | May have OS-specific policy scripts |

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

### AMA (Azure Monitor Agent)
- **Blocked by distro allowlist** — `agent.py` checks `ID` from `/etc/os-release` against
  `supported_distros.py`. NixOS is not listed. This is the only reason AMA fails.
- Workaround: Patch `supported_distros.py` after download (fragile).
- Recommendation: Ask Arc PG to add NixOS to the allowlist.

### MDE (Microsoft Defender for Endpoint)
- Extension handler installs and enables without issue
- Requires Defender for Endpoint onboarding blob via `--settings`
- May need additional FHS sandbox dependencies for the `mdatp` daemon
- Likely needs kernel audit/eBPF features (NixOS supports both)

### Azure Update Manager
- Fundamentally incompatible with NixOS's declarative update model
- Would need a shim that translates update requests to `nixos-rebuild`
- Low priority — NixOS has its own superior update story

## Testing Protocol

For each extension:
1. Deploy via `az connectedmachine extension create`
2. Monitor `/var/lib/GuestConfig/ext_mgr_logs/gc_ext.log` for delivery progress
3. Check state at `/var/lib/GuestConfig/extension_logs/<name>-<version>/state.json`
4. Check stderr/stdout in the same directory
5. Verify portal status via `az connectedmachine extension list`
6. Document any missing sandbox dependencies
7. Test extension removal
