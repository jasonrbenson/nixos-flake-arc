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

## ADR-005: Extension Service Wrapping Framework

**Status**: Accepted
**Context**: Some Azure Arc extensions (e.g., KeyVault) create systemd unit files during
their install handler that execute dynamically linked binaries directly. These binaries
expect FHS paths (`/lib/ld-linux-aarch64.so.1`) that don't exist on the NixOS host.
The install handler runs inside bwrap (via extd), but the resulting systemd service
runs on the host — outside the sandbox.

**Decision**: Automatically intercept and patch extension-created systemd units at two
levels:

1. **systemctl wrapper (bwrap-side)**: Replace `/usr/bin/systemctl` in the bwrap rootfs
   with a wrapper that intercepts `daemon-reload`. Before calling the real daemon-reload,
   it scans `/run/systemd/system/*.service` for units with `ExecStart=/var/lib/waagent/...`
   and prepends `/run/current-system/sw/bin/azcmagent-fhs` to run the binary in the FHS
   sandbox.

2. **arc-ext-fhs-wrapper timer (host-side)**: A systemd timer runs every 5 minutes as a
   safety net, performing the same scan/patch. Catches units created outside the normal
   install flow.

Additional sub-decisions:
- `/etc/systemd/system` inside bwrap is symlinked to `/run/systemd/system` so extension
  install scripts can write unit files to a host-writable path in systemd's search path
- `systemctl enable/disable` intercepted to add `--runtime` flag (writes to
  `/run/systemd/system/` instead of read-only `/etc/systemd/system/`)
- Units in `/run/systemd/system/` don't survive reboot, but extd re-installs extensions
  on boot, re-triggering the wrapper

**Alternatives Considered**:
1. **Per-extension NixOS services** — Manually create a NixOS systemd unit for each
   extension that needs it. More explicit but doesn't scale and breaks when extensions
   change their binary paths.
2. **inotify watcher** — Watch `/run/systemd/system/` for new `.service` files. More
   reactive but adds complexity and a daemon dependency.

**Consequences**:
- Transparent to extensions — no per-extension configuration needed
- Any future extension creating a service unit with binaries in `/var/lib/waagent/` is
  automatically handled
- 5-minute polling interval means the safety net has a small window where unpatched units
  could be started (mitigated by the primary daemon-reload interception)

## ADR-006: /run/systemd/system for Extension Units

**Status**: Accepted
**Context**: Extension install scripts write systemd unit files to `/etc/systemd/system/`.
On NixOS, `/etc` is managed declaratively and `/etc/systemd/system/` is a symlink chain
into the read-only nix store.

**Decision**: Inside the bwrap sandbox, create a symlink from `/etc/systemd/system` to
`/run/systemd/system/` (a host-writable tmpfs directory that is part of systemd's unit
search path). This lets extension install scripts write unit files normally while the
files actually land on a writable path the host systemd can read.

**Consequences**:
- Extension units don't survive reboot (tmpfs) — acceptable because extd re-delivers
  extensions on boot
- No modification to the NixOS `/etc` — all changes are inside the bwrap namespace

---

## Binary Analysis Notes

### Core Agent Binaries — Statically Linked Go

**Critical finding**: The core agent binaries (`himds`, `arcproxy`, `azcmagent_executable`)
are **statically linked Go executables**. This means they have **zero dynamic library
dependencies** and can theoretically run without FHS or patching.

However, they have hardcoded path references to:
- `/opt/azcmagent/` (binaries, config, catalog)
- `/var/opt/azcmagent/` (certs, logs, socks, tokens)
- `/opt/GC_Ext/GC` (extension service)

The `azcmagent` CLI itself is a **bash wrapper** that simply calls
`/opt/azcmagent/bin/azcmagent_executable "$@"`.

### GC Components — Dynamically Linked

The Guest Configuration components (`gc_worker`, `gc_linux_service`) are **dynamically
linked C++/.NET executables** that:
- Require `/lib64/ld-linux-x86-64.so.2` as interpreter
- Link against glibc, libcrypto, libssl, libboost, libpthread, libgcc_s
- Ship their own `.so` files alongside (libmi, libclrjit, libhostfxr, PowerShell runtime)
- Include a .NET Core runtime and PowerShell for policy evaluation

These components **require** the FHS environment or binary patching.

### Hardcoded FHS Paths Found

| Binary | Path | Purpose |
|---|---|---|
| himds (Go, static) | `/opt/azcmagent/` | Binary home directory |
| himds | `/var/opt/azcmagent/certs` | Certificate storage |
| himds | `/var/opt/azcmagent/log/himds` | HIMDS log files |
| himds | `/var/opt/azcmagent/socks/himds` | Unix socket for IPC |
| himds | `/var/opt/azcmagent/tokens` | Auth token storage |
| himds | `/opt/GC_Ext/GC` | Extension service path |
| azcmagent_executable (Go, static) | `/opt/azcmagent/` | Binary home |
| azcmagent_executable | `/var/opt/azcmagent/log/azcmagent` | CLI logs |
| azcmagent_executable | `/var/opt/azcmagent/log/arcproxy` | Proxy logs |
| arcproxy (Go, static) | `/opt/azcmagent/` | Binary home |
| gc_worker (C++, dynamic) | `/lib64/ld-linux-x86-64.so.2` | ELF interpreter |
| gc_linux_service (C++, dynamic) | `/lib64/ld-linux-x86-64.so.2` | ELF interpreter |
| Various .sh scripts | `/opt/azcmagent/bin/` | Script references |
| install.sh (GC) | `/lib/systemd/system/` or `/usr/lib/systemd/system/` | Unit file install |
| install.sh (GC) | `/var/lib/GuestConfig` | GC state directory |

### Shared Library Dependencies (GC components)

| Library | Required By | NixOS Package |
|---|---|---|
| libcrypto.so | gc_worker | openssl |
| libssl.so | gc_worker | openssl |
| libz.so | gc_worker | zlib |
| libboost_filesystem.so.1.83.0 | gc_worker | (shipped in package) |
| libgcc_s.so | gc_worker | libgcc |
| libpthread.so | gc_worker | glibc |
| libc.so | gc_worker, gc_linux_service | glibc |
| libclrjit.so | gc_linux_service (.NET) | (shipped in package) |
| libhostfxr.so | gc_linux_service (.NET) | (shipped in package) |
| libicu*.so | gc_linux_service (.NET) | icu |

### Systemd Units (from DEB datafiles)

| Unit | Type | User | Description |
|---|---|---|---|
| himdsd.service | simple | himds:himds | Core agent — identity & Azure connection |
| arcproxyd.service | simple | arcproxy:himds | Network proxy for agent + extensions |
| gcad.service | simple | root | Guest Configuration agent |
| extd.service | simple | root | Extension Manager (requires himdsd) |

### DEB Package Dependencies

```
Depends: curl, systemd, passwd
```

### Port Usage

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 40342 | TCP | Local only | IMDS endpoint (identity/metadata) |
| 443 | TCP | Outbound | Azure Arc endpoints |
