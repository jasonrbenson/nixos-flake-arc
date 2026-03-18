# Architecture Decision Records

## ADR-001: Hybrid Packaging Approach (buildFHSEnv + NixOS Module)

**Status**: Accepted  
**Context**: Azure Arc's `azcmagent` is a precompiled binary distributed as DEB/RPM that
expects FHS-compliant filesystem layout. NixOS does not follow FHS.

**Decision**: Use `buildFHSEnv` to create an FHS sandbox for agent runtime, wrapped in a
declarative NixOS module for configuration. This gives us the fastest path to a working
PoC while providing a NixOS-native user experience.

**Alternatives Considered**:
1. **autoPatchelfHook only** — Patch ELF binaries directly. More NixOS-native but higher
   risk due to hardcoded paths in binaries that go beyond dynamic linking.
2. **Container/VM** — Run agent in a container. Too heavy and defeats the purpose of
   demonstrating native NixOS support.

**Consequences**:
- Larger closure size due to FHS environment
- Agent runs in compatibility layer rather than truly natively
- Natural migration path: can incrementally move components from FHS → native patching

## ADR-002: DEB Package Source

**Status**: Accepted  
**Context**: Microsoft publishes the agent as both DEB and RPM packages.

**Decision**: Use DEB packages as source. Nix has native `dpkg` support for extraction,
and DEB packages are simpler to unpack than RPMs.

## ADR-003: State Directory Layout

**Status**: Proposed  
**Context**: The agent writes state to `/var/lib/waagent/` and config to `/etc/azcmagent/`.
NixOS manages `/etc` declaratively.

**Decision**: Use `/var/lib/azure-arc/` as the primary state directory on the NixOS side,
with bind mounts into the FHS sandbox mapping to the paths the agent expects.

## ADR-004: Version Management

**Status**: Proposed  
**Context**: The agent has an auto-update mechanism that expects apt/yum.

**Decision**: Disable auto-update inside the FHS sandbox. Version management is handled
declaratively through the flake — update the version in `flake.nix`, run `nix flake update`
or update the hash, and `nixos-rebuild switch`.

---

## Binary Analysis Notes

*(To be filled in during Phase 0 binary analysis)*

### Hardcoded FHS Paths Found

| Binary | Path | Purpose |
|---|---|---|
| TBD | TBD | TBD |

### Shared Library Dependencies

| Library | Version | NixOS Package |
|---|---|---|
| TBD | TBD | TBD |

### Systemd Units

| Unit | Type | Description |
|---|---|---|
| TBD | TBD | TBD |
