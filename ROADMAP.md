# `agent-shadow` Roadmap

Planned work, written so each item can become a GitHub issue.

---

### Issue 1: More Linux distributions (Fedora, AlmaLinux, Alpine, …)

- **Status:** Planned (design agreed: one Containerfile + `packages.sh`)

#### Goal
Today the images are `ubuntu24` (`ubuntu:24.04`, default) and `ubuntu26` (`ubuntu:26.04`). Add distros from three
families: Debian (`debian`), RHEL (`fedora`, `almalinux`, `rocky`) and Alpine (`alpine`).

#### What differs between distros, and what doesn't
- **Shared, unchanged:** `profile.sh`, `rm-guard.sh`, `entrypoint.sh`, `traffic-monitor.sh` and `traffic-filter.awk`
  are POSIX `sh`/`awk`; tcpdump exists everywhere. The egress proxy image stays Ubuntu (internal, not user-facing).
- **Packages:** `apt-get` vs `dnf` vs `apk`, and some names differ (`xz-utils` vs `xz`; on Alpine `chattr` comes
  from `e2fsprogs-extra`). Alpine has no `bash`, which `run` uses: it must be installed.
- **C library:** Alpine uses musl, so it needs mise's musl build (`mise-v<version>-linux-arm64-musl`, its own
  SHA-256 pin) and its own toolchain volume: tools built for glibc don't run on musl. Fedora/AlmaLinux are glibc
  but ship older versions than Ubuntu 24.04 (AlmaLinux 9: 2.34, Ubuntu 24.04: 2.39), and tools built against a
  newer glibc fail on an older one, so each family gets its own toolchain volume rather than sharing `mise-store`.

#### Design: one Containerfile, distro logic in one script
Keep the single `lib/agent-shadow/image/Containerfile`: the parts agent-shadow depends on (mise and its paths,
the COPYs, the entrypoint) stay in one place, the same reason `run`/`start` share `session.zsh`. Replace its
`apt-get install` line with:
```dockerfile
COPY packages.sh /tmp/packages.sh
RUN sh /tmp/packages.sh && rm /tmp/packages.sh
```
`packages.sh` reads `/etc/os-release` (`ID`, `ID_LIKE`) and installs the same set with the family's manager:

| Family | Manager | Packages |
| :--- | :--- | :--- |
| debian (ubuntu, debian) | `apt-get` | `ca-certificates curl git unzip xz-utils tcpdump e2fsprogs` |
| rhel (fedora, almalinux, rocky) | `dnf` | `ca-certificates curl git unzip xz tcpdump e2fsprogs` |
| alpine | `apk` | `ca-certificates curl git unzip xz tcpdump e2fsprogs-extra bash` |

It fails the build with a clear message for an unknown family. Per distro, `helpers.zsh` gains one table row:
base image + digest, family, libc (selects the mise build and its SHA-256, passed as build arguments) and
toolchain volume (`mise-store`, `mise-store-rhel`, `mise-store-musl`). The user's `Dockerfile.<distro>.append`
works as today, in that distro's own package manager.

#### Steps
1. Add `image/packages.sh`; use it in the Containerfile (Ubuntu first, so the existing images and tests prove it).
2. Extend `SUPPORTED_DISTROS`/`BASE_IMAGE`/`BASE_IMAGE_SHA` with family, libc and toolchain volume per distro;
   add the musl mise pin. `init`/`run`/`start`/`tools` already pick the volume from `MISE_VOLUME[$distro]`.
3. Unit tests: `packages.sh` picks the right manager and list for sample `/etc/os-release` files (run on the host
   with a stub for the package manager that records its arguments); every family's toolchain volume differs
   where the libc differs.
4. Mac: `make e2e DISTRO=<name>` runs the suite against `shadow-e2e-base:<name>` (setup registers with `--distro`),
   so node from mise, `traffic`, `rm` guard and the rest are checked on that distro. Add one mutant per family
   (e.g. drop `bash` from the Alpine list) to prove the suite notices.

---

### Issue 2: Linux and Windows (WSL2) hosts via Podman or Docker

- **Status:** Proposed

#### Problem
On Windows, WSL2 mounts the Windows drives under `/mnt/c/Users/<user>/` by default. An agent running directly
in WSL2 can read Windows credentials (`.ssh`, `.aws`), browser data and personal files, and can delete them.
On a Linux host, an agent running directly has the same access to `$HOME`.

#### Idea
1. **Detect the container engine** in `helpers.zsh`: Apple `container` on macOS, `podman` or `docker` on Linux and
   WSL2, and have `_run()` call whichever is available.
2. **Refuse risky folders** in `cmd_register.zsh`: on WSL2 also refuse `/mnt/c`, `/mnt/d`, and so on, as `$HOME` and `/`
   are refused today. Only the project folder is mounted, so the Windows drives stay out of reach.
3. **Installer:** install to `~/.local/bin/agent-shadow` on Linux/WSL2 and check that `podman` or `docker` is present.

Open question: Apple-specific parts (the egress dialog uses `osascript`, `--internal` networks) need an
equivalent or have to be switched off on other engines.
