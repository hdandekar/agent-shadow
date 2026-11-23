# Project: `agent-shadow` (macOS CLI for Apple Container + `mise` Agent Sandboxes)

> **S**andboxed **H**ost-**A**gnostic **D**istros, **O**rchestrated **W**orkspaces  
> *Easy to **wash**: coding agents **do** their work in an isolated **shadow** workspace.*

## Goal
A `#!/bin/zsh` CLI (`bin/agent-shadow` and `lib/agent-shadow/*.zsh`), a checkout installer for development (`install.sh`), and a Homebrew formula (the only user install method) (`Formula/agent-shadow.rb`) for running isolated AI coding agents (`claude`, `codex`, `agy`, `opencode`, `bash`) on macOS 26+ (Tahoe) using Apple's `container` CLI and `mise`.

## Current Status & Invariants
1. **Host Language & Modularity:**
   - Pure `/bin/zsh` (`set -euo pipefail`); on the host it needs only macOS tools and Apple `container`.
   - Entry point: `bin/agent-shadow` (help text, argument handling, dispatch; ~200 lines).
   - Modular library in `lib/agent-shadow/` (`helpers.zsh`, `image.zsh`, `session.zsh`, `cmd_init.zsh`, `cmd_register.zsh`, `cmd_start.zsh`, `cmd_connect.zsh`, `cmd_run.zsh`, `cmd_stop.zsh`, `cmd_wash.zsh`, `cmd_tools.zsh`, `cmd_doctor.zsh`, `cmd_uninstall.zsh`, `cmd_traffic.zsh`, `cmd_git.zsh`, `integrity.zsh`, `egress.zsh`).
   - Native Zsh completion at `completions/_agent-shadow`.
   - Output prefix `[agent-shadow]` is 256-colour orange (`%F{208}`), chosen to stay distinct from common zsh themes (robbyrussell uses cyan/green/red/blue) across Apple Terminal profiles. Don't switch it back to a basic ANSI colour. The in-container bash prompt (`profile.sh`, `[agent-shadow:<slug>]` from `AGENT_SHADOW_WORKSPACE`) uses the same 208.

2. **Distribution Scope:**
   - **Phase 1 (Active):** `ubuntu24` (default, `ubuntu:24.04`) and `ubuntu26` (`ubuntu:26.04`).
   - **Phase 2 (Future):** `debian`, `fedora`, `rocky`, `alpine`.
   - Distro override validation: Unsupported distro flags fail fast with clear guidance.

3. **Storage & Runtime Model:**
   - **Toolchains (`mise-store` volume):** Mounted read-only at `/opt/mise` during `agent-shadow run`. Gated read-write access during `agent-shadow tools`.
   - **Workspace State (`home-<slug>` volume):** Mounted persistent at `/root` per registered project. Holds agent session IDs, memories, tokens, bash history, and `~/.m2` caches across container terminations.
   - **Workspace Files:** Host directory bind-mounted at `/workspace` with relative subdirectory tracking.

4. **Security & Guardrails:**
   - Shared user-defined network `shadow-net` by default; dedicated `shadow-<slug>-net` per workspace with `--isolated`.
   - `--isolated` networks are created `--internal` (host-only, no internet, no external DNS). Egress goes through `shadow-proxy-<slug>` (image `agent-proxy:latest`, tinyproxy, deny-by-default) attached `--network shadow-net --network shadow-<slug>-net` **in that order** (first network = default route). Agent reaches proxy **by IP** (no inter-container DNS on internal nets) via `HTTP(S)_PROXY`. Allowlist dir `~/.config/agent-shadow/egress/<slug>/` mounted `:ro`; reload = `kill -USR1 1`. Approvals are per-workspace; watcher polls `container logs` (no `--follow` dependency); `AGENT_SHADOW_APPROVE=allow|deny` bypasses the dialog.
   - Registration explicitly refuses protected paths (`/`, `$HOME`, `/Users`).
   - Port publishing always rewritten to loopback (`127.0.0.1:HOST:CONTAINER`).
   - Never automatically injects `--dangerously-skip-permissions` or `--full-auto`.
   - Workspace → host change detection: `run`/`connect` (and `start`→`stop`) hash host-executable files (`DEFAULT_WATCH_PATTERNS` in `integrity.zsh` + user `~/.config/agent-shadow/watch`) and warn on changes. Warn-only, never blocks; agent exit code is preserved.
   - `agent-shadow git` runs host git with hooks, fsmonitor, sshCommand, pager, editor, sequence editor, askpass, credential helpers and gpg programs pinned to the user's own config (tested against real git). It is **not** a boundary for an untrusted repo (filters, diff drivers, include.path, … remain); never document it as one. Arguments after `git` are passed to git verbatim.
   - Apple `container` 1.x has **no Go-template `--format`** (only `json`/`table`). Get container names with `_container_names [-a]` (parses the table); never `container ls --format '{{.Names}}'`. Test fakes must reject `--format` like the real CLI.
   - `make test` (tests/unit_test.zsh) never uses containers and must never reach the real `container` CLI: an inert stub is first on `PATH` (guarded by a test). Don't add tests that imitate Apple `container`; container behaviour is tested for real on a Mac in tests/mac_e2e_test.zsh.
   - Scope: agent-shadow wraps Apple `container`; it does not diagnose or manage it. No kernel download/caching, no network diagnostics (`demo`/`network`/`ip` were removed), no `--dry-run` (it existed to feed string-matching tests). Installing `container` and its kernel is Apple's (or Homebrew's) job.
   - Commands acting on "all" containers (`stop --all`, uninstall) select by the registry (`_shadow_owns_container`, slugs from `workspaces`), never by a bare `agent-*`/`home-*`/`shadow-*` name prefix: other tools use those names too. Uninstall keeps images, `mise-store`, `shadow-net` and the kernel unless `--purge`.
   - Slugs are unique per folder (`_registry_slug_for`): a second folder with the same name gets `<name>-<6 hex of the path's SHA-256>`. Never derive a slug with `_slugify` alone outside that helper.
   - Apple `container` (1.7.1) does **not resolve container names** between containers; address siblings by IP (`_container_addrs`). Never document `name:port` Docker-Compose style.
   - Under `pipefail`, never end a pipeline with `grep -q` (`cmd | grep -q x`): grep exits early, `cmd` gets SIGPIPE (141) and the pipeline fails even on a match. Use `grep x >/dev/null`.
   - In-container interceptor warns if `mise install/use/upgrade/uninstall` is executed while `/opt/mise` is mounted read-only.

5. **Packaging & Delivery:**
   - **Homebrew only** for users (`brew install` / `brew upgrade`); not in homebrew-core, the tap is this repository. `./install.sh` installs a checkout for development and refuses to run piped. No remote installer, no `self-update`, no `release.conf`. Removal is `agent-shadow uninstall` (Homebrew can't remove containers), then `brew uninstall`.
   - **Image:** `lib/agent-shadow/image/` (plain Containerfile + scripts) is what agent-shadow depends on; users extend it only through `~/.config/agent-shadow/Dockerfile.<distro>.append` (inserted at the marker line), never by replacing it. `init` records a template hash per image tag in `$XDG_STATE_HOME/agent-shadow/images/`; `run`, `start`, `doctor` and `init` only warn when it changed, never rebuild on their own. `AGENT_SHADOW_IMAGE_PREFIX` selects another image set (the Mac suite uses `shadow-e2e`).
   - **One copy of shared logic:** `run`/`start` options and container arguments live in `session.zsh`; the allowlist (proxy filter and `traffic`) comes from `_allowlist_eres`/`_allowlist_match` in `egress.zsh`. Don't re-implement either in a command.
   - **Homebrew:** the repository is `hdandekar/agent-shadow` (no `homebrew-` prefix; the local folder name differs), so the tap is `brew tap hdandekar/agent-shadow https://github.com/hdandekar/agent-shadow`. Homebrew 6+ refuses formulae from untrusted taps: users run `brew trust --formula hdandekar/agent-shadow/agent-shadow` before installing (also needed for `brew audit`/`test`). Releasing: bump `AGENT_SHADOW_VERSION` (helpers.zsh) and the Formula `url`/`test` together (a unit test checks they agree), commit, push `main` and the `vX.Y.Z` tag, then set the Formula `sha256` to `curl -fsSL <url> | shasum -a 256` of GitHub's tag archive in a follow-up commit (it can't be known before the tag exists).
   - **Trust model:** Homebrew checks the tagged archive against the formula's SHA-256; that is not a signature, and the repository remains the trust root. Base images (incl. the proxy) are pinned by digest (`BASE_IMAGE_SHA`) and mise by version + SHA-256 (`MISE_VERSION`, `MISE_SHA256_LINUX_ARM64`) in `helpers.zsh`; apt packages and tool registries are not pinned. Never describe builds as fully verified or reproducible (see docs/SECURITY.md §8).
   - **Reusing running containers:** `run`, `start`, `connect` must call `_require_same_network` before using an existing container (fail closed on mismatch, unknown address, IPv6 address, or overlapping subnets). `_container_addrs` must return *every* address of a container, whatever the separator.

6. **Testing & Verification:**
   - `make lint`: syntax check of every script, including install.sh and tests.
   - `make test`: tests/unit_test.zsh, host-only (real files, real git, real hashing, the image scripts run on sample input; no containers). Runs in CI on macOS.
   - `make e2e`: tests/mac_e2e_test.zsh on a real Mac, nothing faked; `SECTIONS=a,b` picks sections. Everything it creates is named `e2e<id>` and removed by its exit trap; it uses its own XDG config and toolchain volume (`AGENT_SHADOW_MISE_VOLUME`, default `shadow-e2e-mise`). Each check is PASS/FAIL/SKIP-with-reason; never add a check that only warns.
   - `make mutants` / `make mutants-mac`: tests/mutants.zsh re-introduces known bugs in a temp copy and expects the tests to fail. When adding a test for a bug, add a mutant for it; keep `--check` passing (every mutant still applies). Never add a mutant that deletes images or volumes on the Mac.
   - GitHub macOS runners can't start Apple containers: CI runs only lint, `make test` and `make mutants`.
   - `docs/TESTING.md`: how to run and report the suites, plus the manual walkthrough (dialog, interactive sessions); update it whenever user-visible behaviour changes.
