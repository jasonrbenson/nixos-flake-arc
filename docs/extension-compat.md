# Azure Arc Extension Compatibility Matrix for NixOS

## Overview

Azure Arc extensions are managed by the Extension Manager component of the Connected
Machine Agent. Extensions are downloaded to `/opt/GC_Ext/downloads/` and installed to
`/var/lib/waagent/<extension>/`. All of this runs inside the FHS sandbox.

## Extension Compatibility

| Extension | Publisher | Type | NixOS Status | Notes |
|---|---|---|---|---|
| Azure Monitor Agent | Microsoft.Azure.Monitor | AzureMonitorLinuxAgent | 📋 Untested | Primary test candidate for Phase 2 |
| MDE | Microsoft.Azure.AzureDefenderForServers | MDE.Linux | 📋 Untested | May need Python, kernel features (eBPF/audit) |
| Guest Configuration | Microsoft.GuestConfiguration | ConfigurationforLinux | 📋 Untested | Core Arc feature for policy compliance |
| Custom Script | Microsoft.Azure.Extensions | CustomScript | 📋 Untested | Should be straightforward in FHS env |
| Azure Update Manager | Microsoft.SoftwareUpdateConfiguration | LinuxOsUpdateExtension | 📋 Untested | May conflict with NixOS update model |
| Key Vault | Microsoft.Azure.KeyVault | KeyVaultForLinux | 📋 Untested | Certificate management |

## Known Challenges

### MDE (Microsoft Defender for Endpoint)
- May require kernel audit subsystem or eBPF — NixOS supports both but may need
  explicit kernel configuration options
- Real-time protection uses fanotify — supported on NixOS
- May expect SELinux; NixOS defaults to AppArmor
- Likely requires Python runtime in the FHS environment

### Azure Update Manager
- Fundamentally incompatible with NixOS's declarative update model
- May need a shim/adapter that translates update requests to `nixos-rebuild`
- Low priority — NixOS has its own superior update story

### Guest Configuration
- Expects to write compliance state to standard paths
- Should work within the FHS sandbox
- Policy definitions may reference FHS paths in their assessment scripts

## Testing Protocol

For each extension:
1. Deploy via Azure portal to the Arc-connected NixOS machine
2. Verify extension installation succeeds (check `azcmagent extension list`)
3. Verify extension is running (check extension-specific health indicators)
4. Verify telemetry/data reaches Azure (check in Azure portal)
5. Test extension update lifecycle
6. Test extension removal
7. Document any workarounds required
