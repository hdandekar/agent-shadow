# `agent-shadow` Architecture & Development Guide

How `agent-shadow` is put together: what it mounts, which networks it creates, and how each feature works.

---

## Architecture Overview

`agent-shadow` sets up containers, networks and volumes. Installing tools is left to `mise`:

```
Host (macOS Tahoe):
┌────────────────────────────────────────────────────────┐
│  agent-shadow (pure /bin/zsh CLI)                      │
│  - Registers workspaces                                │
│  - Creates isolated virtual networks (shadow-<slug>-net)│
│  - Sets up volumes & loopback-only published ports     │
└────────────────────────────────────────────────────────┘
                       │
       container run   │ (Apple Virtualization Framework)
                       ▼
Container (Ubuntu 24.04 / 26.04 VM):
┌────────────────────────────────────────────────────────┐
│  /workspace  ◄── [Bind Mount] Host project directory   │
│  /opt/mise   ◄── [Volume :ro] Shared mise-store       │
│  /root       ◄── [Volume :rw] Persistent home-<slug>  │
│                                                        │
│  mise shims at /opt/mise/shims (Node, Python, Java)    │
│  coding agent process (claude, codex, opencode, bash)  │
└────────────────────────────────────────────────────────┘
```

---

## Storage & Volume Topology

### 1. `/workspace` (Host Bind-Mount)
- Points directly to your registered local project folder on macOS.
- Changes made inside the container are changes to your Mac folder.
- Subfolders: run `agent-shadow run` from `~/my-project/packages/api` and the container still mounts the workspace root at `/workspace`, but starts in `/workspace/packages/api` (`--workdir`).

### 2. `/opt/mise` (`mise-store` Shared Volume)
- Holds the runtimes and agent CLIs installed with `agent-shadow tools` (whatever `mise` supports: Node, Python, Java, …).
- **Read-only in sessions:** `run` and `start` mount it `:ro`, so nothing in a session can change or delete installed tools.
- **Writable only through `tools`:** `agent-shadow tools <args...>` starts a temporary container with write access, after checking that no agent containers are running.

### 3. `/root` (`home-<slug>` Persistent Volume)
- Each registered workspace gets its own volume, mounted at `/root` and kept between sessions.
- Holds:
  - Agent memories and conversation state (e.g., `~/.claude/`, `~/.codex/`).
  - Authentication tokens and API key caches.
  - Shell command history (`~/.bash_history`).
  - Package manager caches (e.g., `~/.m2/repository` for Maven, `~/.cargo` for Rust).
- Also anything else written to the home folder, e.g. tools installed into `~/.local/bin` (on `PATH`, after the system directories).
- **Separate per workspace:** project A's `/root` is a different volume from project B's.
- **Reset (`wash`):** `agent-shadow wash` deletes and recreates `home-<slug>` after asking for confirmation. Files in `/workspace` are not touched.

---

## Network & Port Forwarding Security

1. **Shared network by default (`shadow-net`):** containers join `shadow-net` and have normal internet access. They can reach other containers on it by IP, and services on the Mac at the network's gateway address. This Apple Container network is not a transparent mirror of macOS networking; do not assume it has the same routes, DNS, VPN access, or firewall policy as the Mac.
2. **Dedicated Isolation Mode (`shadow-<slug>-net`):** When registering with `--isolated` (or `-i`), the workspace gets its own `shadow-<slug>-net`, created `--internal` (Apple Container reports `hostOnly`). In the tested setup, direct requests to a public IP and external DNS were blocked; proxied HTTP(S) uses the egress approval proxy. Host services listening on reachable Mac interfaces may still be reachable.
3. **Published ports on loopback:** `--publish HOST:CONTAINER` (or `-p`) is rewritten to `127.0.0.1:HOST:CONTAINER`, binding the host-side port to Mac loopback. `127.0.0.1` inside the container is that container's own loopback.

---

## Reaching Containers

- **From another container:** by IP only. Apple `container` does not resolve container names (1.7.1). Find
  addresses with `container ls`. Addresses are assigned when a container starts and can change after a restart.
- **From the Mac:** through ports published with `-p HOST:CONTAINER`, on `127.0.0.1`.

---

## `mise install` Inside a Session

The image's `/etc/profile.d/mise.sh` defines a `mise` shell function. For `install`, `use`, `upgrade` and `uninstall` it checks whether `/opt/mise` is writable. In a session it isn't, so instead of a read-only error it prints the `agent-shadow tools …` command to run on the Mac.

---

## Background Container Lifecycle (`start`, `connect`, `stop`)

- **`start`:** runs a background container (`agent-<slug>`) whose main process is `sleep infinity`. Published ports stay bound to `127.0.0.1`.
- **`connect`** (alias `shell`): opens a bash shell in it with `container exec`. Exiting the shell leaves the container and its servers running.
- **`run` while it is running:** if `agent-<slug>` is running, `run <agent>` executes the agent in it with `container exec` instead of starting a new container.
- **`stop`:** stops and removes it.

---

## Egress Approval Proxy (`egress.zsh`)

```
agent ──(shadow-<slug>-net, --internal)──► shadow-proxy-<slug> ──(shadow-net)──► internet
         HTTP(S)_PROXY=http://<proxy-ip>:3128      tinyproxy, FilterDefaultDeny
```

Verified on Apple container 1.7.1 (checked on every `make e2e SECTIONS=egress`):
- `--internal` networks block direct internet **and** DNS.
- A container may join several networks; the **first** `--network` provides the default route, so the proxy is started with `--network shadow-net --network shadow-<slug>-net`.
- Containers on an internal network cannot resolve each other by name → the agent gets the proxy's **IP** (read with `hostname -I` and matched against the network's `ipv4Subnet`).
- The proxy VM has `ip_forward=0`, so a root agent cannot route around it.
- tinyproxy is PID 1; `kill -USR1 1` re-reads the filter ("Re-reading filter file.").
- Denied requests log `Proxying refused on filtered domain "<host>"`.

Files in `~/.config/agent-shadow/egress/<slug>/` (mounted read-only at `/cfg`):
- `tinyproxy.conf` — generated: `Allow <internal subnet>`, `ConnectPort 443`, `FilterDefaultDeny Yes`.
- `filter` — generated anchored EREs from `DEFAULT_ALLOWLIST` + `~/.config/agent-shadow/allowlist` + `approved`.

`Allow <internal subnet>` is a source-address rule for clients connecting to tinyproxy, not a destination allowlist for private IP ranges such as `192.168.x.x` or `172.x.x.x`. The `filter` file contains allowed destination hostnames or IPv4 literals for proxied requests; CIDR destination ranges are not supported.
- `approved` — per-workspace approvals (one host per line).
- `session.log` — watcher decisions for the last `run` session.

Lifecycle: `run`/`start` start the proxy if needed; `run` starts a background watcher (polls `container logs` every `EGRESS_POLL_SECONDS`, opens the dialog with `osascript`, asks once per host per session) and stops the proxy afterwards if no other container of the workspace is running; `stop`/`stop --all` stop it; `init` builds `agent-proxy:latest`. Hosts are validated (`[A-Za-z0-9.-]`, optional leading `*.`) before they reach any file, regex or dialog.

At session end, `run` reads the proxy log once more and lists hosts refused during the session that the watcher never handled (short commands can finish before its next poll). For non-interactive runs (`run bash -c …`) the watcher also prints `↳ egress: connected to …` / `blocked …` lines as they happen; interactive sessions don't get them, as they would garble a full-screen agent UI.

---

## Workspace → Host Change Detection (`integrity.zsh`)

- **Watched files:** `DEFAULT_WATCH_PATTERNS` (zsh globs relative to the workspace root) plus optional user globs in `${XDG_CONFIG_HOME:-$HOME/.config}/agent-shadow/watch` (one per line, `#` comments; absolute paths and `..` are rejected).
- **Snapshot format:** one line per regular file (symlinks followed): `<sha256> <relative path>`, sorted. Hashing uses `shasum -a 256` (macOS) with a `sha256sum` fallback (Linux CI).
- **Ephemeral sessions:** `run` and `connect` wrap the `container run` / `container exec` call in `_integrity_run <root> <cmd...>`, which snapshots before, compares after, prints a warning listing `added` / `modified` / `removed` files, and returns the wrapped command's exit code. Skipped under `--dry-run`.
- **Background containers:** `start` writes a baseline to `agent-shadow/integrity/<slug>.start`; `stop` (and `stop --all`) compares and deletes it; `unregister` deletes it.
- **Warn-only:** nothing is blocked or reverted.

## Host Git Without Repository Hooks (`cmd_git.zsh`)

`agent-shadow git <args>` runs host git with `-c core.hooksPath=/dev/null -c core.fsmonitor=false`, `gpg{,.ssh,.x509}.program` from your global config (or `gpg` / `ssh-keygen` / `gpgsm`), `-c credential.helper=` (empty resets the list) followed by your global helpers, and the environment variables `GIT_SSH_COMMAND`, `GIT_PAGER`, `GIT_EDITOR`, `GIT_SEQUENCE_EDITOR`, `GIT_ASKPASS` (your environment, else your global config, else defaults; an empty `GIT_ASKPASS` makes git skip the repository's `core.askPass`). These take precedence over repo-local `.git/config`. Other config keys that run programs are not handled (see the list in `cmd_git.zsh` and docs/SECURITY.md §5). agent-shadow's own `--dry-run` is only taken from *before* the `git`, `run` or `tools` word, so `agent-shadow git push --dry-run` reaches git unchanged.

---

## Git Identity & Dubious Ownership

- **Safe directory:** the image runs `git config --system --add safe.directory "*"`, which avoids `fatal: detected dubious ownership in repository at '/workspace'`.
- **Identity fallback:** your Mac's global `user.name` / `user.email` are passed in as `GIT_FALLBACK_NAME` / `GIT_FALLBACK_EMAIL`. Repositories with their own identity in `.git/config` keep it.

---

## Workspace Registry

The registry is stored at `${XDG_CONFIG_HOME:-$HOME/.config}/agent-shadow/workspaces` as a plain flat file with pipe-separated fields:

```text
slug|absolute_path|distro|network
```

Example:
```text
my-project|/Users/developer/work/my-project|ubuntu24|shadow-net
```

`register` refuses `/`, `$HOME` and `/Users`, so a whole disk or home folder is never mounted.
