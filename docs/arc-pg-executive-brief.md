# Azure Arc on NixOS: Executive Brief & Call to Action

**To**: Azure Arc Connected Machine Product Group  
**From**: Jason Benson  
**Date**: March 2026  
**Subject**: Enabling Native NixOS Support — Proof-of-Concept Results and Requested Engineering Investment

---

## The Bottom Line

We built a working Azure Arc Connected Machine Agent deployment on NixOS and proved
that **5 of 7 tested extensions work** — including MDE reporting `healthy: true,
licensed: true`. Every failure we encountered traces back to a small number of
**hardcoded assumptions** in the agent and extension code that are straightforward
to fix. We are asking the Arc engineering team to make targeted changes that would
enable native NixOS support and improve agent portability across all non-standard
Linux distributions.

---

## What We Proved

| Capability | Status | Evidence |
|-----------|--------|---------|
| Core agent (connect, heartbeat, inventory) | ✅ Working | Machine visible in Azure portal, continuous heartbeat |
| Custom Script Extension | ✅ Working | End-to-end command execution, output returned to Azure |
| Azure Monitor Agent (AMA) | ✅ Working | 3 sub-services running (mdsd, amacoreagent, mdsdhelper) |
| Microsoft Defender for Endpoint (MDE) | ✅ Working | `healthy: true, licensed: true`, real-time protection active |
| Key Vault Extension | ✅ Working | Auto-wrapped for FHS sandbox, install + enable succeed |
| Guest Configuration | ✅ Working | Full compliance lifecycle — pull, validate, execute, report to Azure |
| ChangeTracking | ❌ Blocked | Compiled Go binary explicitly rejects NixOS — requires code change |

**Tested on both architectures**: aarch64 (UTM/QEMU) and x86_64 (Hyper-V Gen2)

---

## What It Took (And Why That Matters)

To get here, we implemented **24 workarounds** — runtime patchers, wrapper scripts,
bind mounts, and an FHS sandbox. Every single workaround exists because the Arc agent
or an extension makes one of these assumptions:

1. **The OS is on a hardcoded allowlist** (AMA, ChangeTracking)
2. **apt/dpkg/yum is available** (MDE, AMA)
3. **System paths are writable** (`/opt/`, `/etc/systemd/system/`, `/usr/bin/`)
4. **DEB maintainer scripts will run** (MDE's `useradd`, `postinst`)
5. **`publicSettings` is never None on Arc** (MDE, AMA — this is a bug everywhere)

None of these assumptions are fundamental. They are implementation shortcuts that
could be replaced with portable alternatives at low cost.

---

## What We're Asking For

### Phase 1: Quick Wins (Days of Work, Zero Risk to Other Platforms)

These changes are additive — they add NixOS support without changing behavior on
any existing platform:

| # | Change | Owner | Impact |
|---|--------|-------|--------|
| 1 | Add `'nixos'` to AMA's `supported_distros.py` | AMA team | Eliminates exit code 51; one-line change per arch dict |
| 2 | Add `nixos → debian` mapping in MDE's `mde_installer.sh` | MDE team | 3-line elif block in distro detection |
| 3 | Add `nixos` to ChangeTracking's distro allowlist | CT team | Compiled Go — needs rebuild, but trivial logic change |
| 4 | Fix `publicSettings`/`protectedSettings` None handling in MDE | MDE team | 4 lines — add `is None` checks. **This is a bug affecting ALL Arc machines**, not just NixOS |
| 5 | Fix `HUtilObject._context` and `SettingsDict` None handling in AMA | AMA team | 3 guards. **Also a bug on all Arc machines** |
| 6 | Use `systemctl --runtime enable` in extensions | Extension framework | Works correctly on any system with read-only `/etc/` |

**Estimated effort**: 1-2 days per team. Zero regression risk — all changes are
additive guards or allowlist additions.

**Result**: Eliminates the need for **all runtime patchers** in our PoC. NixOS works
with just the FHS sandbox (a stable, maintainable configuration).

### Phase 2: Portability Improvements (Weeks)

These changes benefit NixOS, Alpine, Guix, container base images, and embedded Linux:

| # | Change | Benefit |
|---|--------|---------|
| 1 | **Provide tarball distribution** (`.tar.gz` + `setup.sh`) | Enables packaging on ANY Linux without DEB/RPM |
| 2 | **Pluggable package install** (`--install-method=extract`) | `dpkg-deb -x` data-only mode for non-Debian systems |
| 3 | **Modular MDE setup** | Separate essential setup from 3000-line postinst script |
| 4 | **Document gc.config** | ServiceType values currently undocumented outside install.sh |
| 5 | **Ship arm64 ChangeTracking** | KeyVault already ships both architectures |
| 6 | **SSL cert auto-discovery** | Honor `SSL_CERT_FILE`/`SSL_CERT_DIR` environment variables |

**Estimated effort**: 2-4 weeks total across teams.

**Result**: NixOS (and other non-FHS distros) can install and run the agent from a
tarball with `autoPatchelf` — no FHS sandbox required for the core agent.

### Phase 3: Native NixOS Architecture (Quarterly)

These changes make the agent a first-class citizen on NixOS and improve portability
broadly:

| # | Change | Benefit |
|---|--------|---------|
| 1 | **Configurable installation paths** | `--prefix` flag instead of hardcoded `/opt/azcmagent` |
| 2 | **Static linking for GC components** | Core agent (Go) is already static; GC (C++/.NET) should follow |
| 3 | **Declarative extension config** | JSON/YAML manifest instead of imperative CLI |
| 4 | **Check binary presence, not dpkg status** | `which curl` instead of `dpkg -l curl` |
| 5 | **Add NixOS to CI test matrix** | Prevent regressions with each release |

**Result**: Fully native NixOS support — a standard Nix package and NixOS module,
no sandbox, no patching, no workarounds.

---

## The Pathway to Native Support

```
Today                    Phase 1              Phase 2              Phase 3
─────                    ───────              ───────              ───────
FHS sandbox         →    FHS sandbox     →    Nix package     →    Fully native
24 workarounds            0 patchers           autoPatchelf          No sandbox
2 runtime patchers        Sandbox only         Minimal sandbox       Standard Nix pkg
                          (stable)             (extensions only)     NixOS module

Effort: Done              Days                 Weeks                 Quarter
Risk: PoC                 Zero to existing     Low                   Medium
```

Each phase is independently valuable. Phase 1 alone makes NixOS a viable Arc target
with our existing open-source FHS sandbox module.

---

## Why NixOS Matters to Azure

**Enterprise adoption is accelerating**. NixOS is gaining traction in:

- **Security-critical environments** — Immutable OS, tamper-evident filesystem,
  reproducible builds. MDE on NixOS benefits from OS-level tamper resistance.
- **Financial services and regulated industries** — Declarative configuration enables
  audit trails and compliance (every change is a git commit).
- **DevOps/SRE teams** — Atomic upgrades with instant rollback. No "half-upgraded"
  states. Identical fleet configurations guaranteed by the build system.
- **AI/ML infrastructure** — Reproducible environments are critical for model training
  and deployment pipelines.

**Azure competitive positioning**: Neither AWS SSM Agent nor Google's OS Config agent
natively support NixOS. First-mover advantage is available.

**Community leverage**: The NixOS community actively packages software. Publishing
a tarball distribution (Phase 2) would likely result in community-maintained packages
appearing in nixpkgs within weeks — free distribution and ongoing maintenance.

---

## What We're Providing

All of our work is open-source and available for the Arc team to reference:

| Resource | Location |
|----------|----------|
| Working PoC (code) | [github.com/jasonrbenson/nixos-flake-arc](https://github.com/jasonrbenson/nixos-flake-arc) |
| Deep technical guide (1,200 lines) | `docs/arc-pg-nixos-integration-guide.md` — every issue, root cause, and fix |
| Extension compatibility matrix | `docs/extension-compat.md` — per-extension breakdown |
| 14 documented gaps with resolutions | `docs/gaps-and-findings.md` — field-tested on 2 architectures |
| Hyper-V test environment | `docs/hyperv-setup.md` — any Arc engineer can reproduce in 30 minutes |
| Production deployment guide | `docs/production-guide.md` — end-to-end NixOS + Arc setup |

The technical integration guide (`arc-pg-nixos-integration-guide.md`) contains the
exact sed patterns, code locations, and root causes for every incompatibility. An
engineer can use it as a checklist to implement Phase 1 changes.

---

## Next Steps

1. **Review the technical guide** — `docs/arc-pg-nixos-integration-guide.md` has
   everything needed to scope the Phase 1 work
2. **Assign Phase 1 items** — One-line allowlist additions and None-guard bug fixes
3. **Validate on our test infrastructure** — We can test any upstream changes on our
   NixOS VMs (both aarch64 and x86_64) and report results
4. **Plan Phase 2** — Tarball distribution unlocks community packaging

We are available to pair with Arc engineers, test changes, and provide NixOS expertise
throughout the process.

---

*For questions or to coordinate on implementation, contact Jason Benson.*
