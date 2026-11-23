# Security Notes

What `agent-shadow` protects, what it does not, and why some things are deliberately left out.

The starting point: **treat the agent as untrusted code running as root.** An agent can run any shell command, and its own "Allow this command?" prompts can be worked around (subshells, encoded commands, instructions hidden in files it reads). So agent-shadow does not depend on them. Each container runs in a separate Linux VM. The guest can access host files through explicit mounts and can read any environment variables passed into it; network reachability is separate from those filesystem boundaries. This limits direct host access, but does not stop the agent changing mounted project files or establish that every VM escape is impossible.

---

## 1. Design choices

### SSH keys are not mounted (`~/.ssh`)
* **The risk:** agents install packages (`npm install`, `pip install`, `cargo build`). A malicious package's install script runs as root and could read `~/.ssh/id_*` and send it anywhere.
* **The damage:** an SSH key usually opens your repositories and often servers too.
* **What we do:** SSH keys are never mounted. The agent edits files in `/workspace`; you review `git diff` and push from the Mac (`agent-shadow git push`). The image has no SSH client either, though root could install one. This protects your SSH keys; it does not protect secrets you pass into the container yourself (see §3).

### Agent permission flags are left to you (`--dangerously-skip-permissions`, `--full-auto`)
* **The risk:** turning these on by default would take the decision away from you.
* **What we do:** agent-shadow never adds agent flags. If you turn them on yourself, the container limits what the agent can reach, but not everything: it can still change the project folder, use the network (unless `--isolated`), reach services on your Mac that listen on all interfaces, and read its own API key.

### Published ports are bound to `127.0.0.1`
* **The risk:** agents start databases and dev servers without passwords.
* **What we do:** every `--publish HOST:CONTAINER` is rewritten to `127.0.0.1:HOST:CONTAINER`, binding the published host port to the Mac's loopback. This is distinct from `127.0.0.1` inside the container, which refers to that container.

### Shared toolchains (`/opt/mise`) are read-only in sessions
* **The risk:** `mise-store` is shared by every workspace. If a session could write to it, a malicious package could replace `node`, `python` or an agent CLI for all projects.
* **What we do:** `/opt/mise` is mounted read-only in `run` and `start`. Installs and upgrades go through `agent-shadow tools` on the Mac, which refuses to run while agent containers are running.
* **Not covered:** each workspace's own `/root` is writable and persists, so a package can leave files there (`~/.bashrc`, `~/.local/bin`) that run in that workspace's later sessions. `agent-shadow wash` removes them.

### Your home folder is never mounted
* **The risk:** mounting your home folder would expose documents, browser data, `.aws/credentials` and shell profiles.
* **What we do:** `agent-shadow register` refuses `/`, `$HOME` and `/Users`. Only the registered project folder is mounted, at `/workspace`.

---

## 2. The `rm` guardrail (catches mistakes, not attacks)

`rm -rf /workspace` by mistake would delete your uncommitted work on the Mac.

> **Scope:** this only catches accidents. Anything that wants to delete files can bypass it (`/bin/rm`, `find -delete`, `python -c "shutil.rmtree(...)"`). Keep work committed and pushed.

The image has a wrapper at `/usr/local/bin/rm`:
* **Blocks** recursive deletes (`-r`, `-R`, `-rf`, `--recursive`) of:
  * `/root`, `~`, `$HOME` (the persistent agent state volume)
  * `/workspace` (the project bind mount root)
  * `/`, a literal unexpanded `/*` / `/root/*` / `/workspace/*`, or `.` when the current directory is a protected root
  * Trailing-slash variants count as the root (`/root/`, `/root/.`, `/workspace//`)
* **Allows:** everything below the roots (`/workspace/node_modules`, `/tmp/…`, installer temp dirs under `/root/.local`), so normal cleanup works.
* **When blocked:** exits with code 1 and prints:
  ```text
  🔴 [agent-shadow guardrail] Blocked destructive recursive rm on: /workspace
     To protect your workspace and persistent state, recursive deletion of root mount points is forbidden.
     Use agent-shadow wash on the host to cleanly reset workspace state.
  ```
* So `rm -rf node_modules`, `rm -rf target/` and `rm -rf dist/` work as usual.

---

## 3. Environment Variables & Secrets Management

*"Can the agent read environment variables I pass in?"*

### Who can see what
1. **In the same container: yes.** Everything runs as root, so any process, including the agent and the packages it installs, can read variables passed with `--env` / `--env-file` (`echo $SECRET_KEY`, `/proc/*/environ`). Don't pass production or broad credentials.
2. **Direct process/environment access in another container: no.** A database or server in a different container runs in a different VM. The agent cannot read its process memory or environment, but it can call services exposed over a network it can reach. This is not a guarantee that the service's data or operations are safe from the agent; use disposable data and credentials, and don't run agent-controlled code in a service container holding sensitive credentials.

### What to put in the container
* ✅ **Safe to load into container:**
  * Ephemeral local credentials (`POSTGRES_PASSWORD=postgres_dev_123`)
  * Local test database URLs (`DATABASE_URL=postgres://localhost:5432/testdb`)
  * Disposable development API tokens or mock keys
  * *If these leak, they only open local or test services.*
* ❌ **Keep out of the container:**
  * Production AWS/GCP/Azure access keys
  * Live Stripe, payment, or production API keys
  * Master GitHub Personal Access Tokens (PATs) with write access across organizations
  * Production database connection strings

### When you need a real third-party test key
Testing an integration (Stripe test mode, a staging OAuth app) sometimes needs a real external key. agent-shadow can't enforce how you handle it; these habits help:

1. **Assume it leaked:** treat any key the agent or its packages could read as exposed.
2. **Rotate it afterwards:** once the integration work is done.
3. **Use restricted keys:** most providers let you create keys limited to test mode or specific actions.
4. **Run `agent-shadow wash`** afterwards. It deletes and recreates the workspace's `home-<slug>` volume, removing shell history, caches and logs that may contain the key.

### The Agent's Own API Key / Login Token
The agent's credential (e.g. `ANTHROPIC_API_KEY`, or the login token saved under `/root/.claude/`) **is** useful outside the container. A well-known, widely used agent lowers the risk of the *agent itself* misbehaving; there are many such agents, commercial and open source. That doesn't protect the token from *other code the agent runs*: anything installed with `npm install` / `pip install` runs as root in the same container and can read `/root`.

agent-shadow does not prevent this today. These steps limit the damage:
1. **One key per workspace** where the vendor allows it, so a leak can be traced and revoked on its own.
2. **Spending limits or usage caps** on that key.
3. **Logins you can revoke** (OAuth / subscription sessions) rather than long-lived API keys.
4. **If you suspect a bad dependency:** revoke the key or log out at the vendor, then run `agent-shadow wash` to remove saved tokens.

---

## 4. Opening the project in an editor on your Mac

Packages the agent installs end up in the project folder on your Mac (`./node_modules/`, `./.venv/`). Editor extensions on the Mac may run code from there when you open the folder, for example a linter from `node_modules` or the Python interpreter in `.venv`, and that code then runs as you, outside the container. agent-shadow does not cover this.

What helps:
1. **Don't trust such folders in your editor.** In VS Code, keep Workspace Trust on and open them in Restricted Mode, so extensions and tasks don't run automatically.
2. **Run linters and test runners in the container**, e.g. `agent-shadow run bash -c 'npx eslint .'`.

---

## 5. Files in the project that run on your Mac

`/workspace` is your project folder and is writable, because the agent has to edit code. So the agent, or a package it installs, can also write files that **later run on your Mac as you**, often without you choosing to run them:

| File | Runs on the host when… |
| :--- | :--- |
| `.git/hooks/*`, `.husky/*`, `.pre-commit-config.yaml` | you run `git commit`, `git checkout`, `git push` |
| `.git/config` (`core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, `core.pager`, filters) | you run almost any git command |
| `.envrc` | you `cd` into the folder with direnv enabled |
| `.vscode/tasks.json`, `.vscode/settings.json`, `.devcontainer/*` | you open the folder in VS Code / Cursor |
| `package.json` scripts, `.npmrc` | you run `npm` on the host |
| `Makefile` | you run `make` on the host |
| `.github/workflows/*` | you push — runs in CI with repository secrets |

> A global `core.hooksPath` in `~/.gitconfig` does **not** protect you: git reads repo-local `.git/config` *after* global config, so the agent can override it.

### Controls
1. **Change detection when a session ends (warns only).** `run` and `connect` hash the files above before and after the session; `start` saves a baseline that `stop` compares against. Added, changed and removed files are listed, and files `git diff` would not show are marked:
   ```text
     ⚠ Files that can run code on your Mac changed since this session started:
          added     .git/hooks/pre-commit
          modified  package.json
   ```
   Extend the list with one glob per line in `~/.config/agent-shadow/watch` (e.g. `pyproject.toml`, `gradlew`, `gradle/wrapper/*`, `.mvn/wrapper/*` — add these if you run those builds on the host).
2. **Committing with `agent-shadow git`.** Runs `git` on the Mac with these settings taken from your global config (or a default) instead of the repository: hooks, `core.fsmonitor`, `core.sshCommand`, `core.pager`, `core.editor`, `sequence.editor`, `core.askPass`, `credential.helper` and `gpg.program`. Command-line options and `GIT_*` variables win over `.git/config`, so what the agent writes there for these is not used. The test suite checks the editor, askpass, credential helper and gpg program against a real git repository; the settings listed below as not covered are not tested and remain ways to run programs.
   ```bash
   git diff                                   # review
   agent-shadow git commit -am "agent changes"
   agent-shadow git push
   ```
   **Not covered, and not a complete list:** clean/smudge filters (`filter.*` with `.gitattributes`), `diff.external` and diff/merge drivers (`textconv`, `merge.*.driver`), `include.path` / `includeIf` (more config from another file), aliases, `pager.<command>`, `remote.*.uploadpack` / `receivepack` and `core.gitProxy`. So `agent-shadow git` is **not a security boundary** for a repository the agent controls. Change detection flags changes to `.git/config`; read it (and `.gitattributes`) before running git on the Mac when it does.

---

## 6. Outbound network (`--isolated`)

On the default shared Apple Container `shadow-net`, containers have normal internet access. This network is not a transparent mirror of macOS networking; do not assume it has the same routes, DNS, VPN access, or firewall policy as the Mac. `--network NAME` attaches to a named Apple Container network and does not imply isolation. `agent-shadow traffic` lists what containers connected to, but that log is inside the container, so root there could edit it. `--isolated` blocks instead of just recording:

* **Internet egress:** `shadow-<slug>-net` is created `--internal` (Apple Container reports `hostOnly`). Live tests on container 1.7.1 blocked direct HTTP to numeric public IP `1.1.1.1:80` and direct HTTPS to `example.com`; approved HTTPS through the proxy succeeded, and a non-allowlisted host was denied.
* **One exit:** the proxy `shadow-proxy-<slug>` runs in its own VM; its config is mounted read-only, and it does not forward packets (`ip_forward=0`), so the agent can neither change it nor route around it.
* **Allowlist for proxied internet traffic:** the destination filter applies only to requests sent through the proxy (built-in registries and LLM APIs, your `~/.config/agent-shadow/allowlist`, and this workspace's approvals). Entries can be hostnames, IPv4 literals, or a leading-`*.` domain pattern; CIDR destination ranges are not supported. Proxy tunnels (`CONNECT`) are limited to port 443; the proxy is not a raw TCP router. The generated `Allow <workspace-subnet>` rule is a source-address ACL: it allows clients on that isolated subnet to connect to the proxy. It is not a destination allowlist or a blanket exception for `192.168.x.x` or `172.x.x.x`. Push from the Mac.
* **You decide:** a blocked host opens a macOS dialog (Deny / Allow; no answer in 30 s = Deny). Approvals apply to this workspace and can be removed (`agent-shadow egress revoke <host>`).
* **Tools that ignore the proxy settings** (`HTTP(S)_PROXY`) cannot use the proxy; direct HTTPS to the public internet was blocked in the live probe. Mac-host services may still be reachable.
* **No silent reuse across networks:** `run`, `start` and `connect` refuse to use an already running container unless all its addresses are in the requested network's subnet. An agent can't end up in a shared-network container through `--isolated`, or the reverse. If the network's subnet overlaps another network's, they refuse too, because addresses can't tell the two apart.

**Known limits:**
- Host-only still means the agent can reach **services listening on reachable Mac interfaces** (e.g. a database bound to `0.0.0.0`). The Mac is the network's gateway (`192.168.x.1`, shown by `container network inspect <net>`); a live test on macOS 27 / container 1.7.1 returned `HTTP 200` from a temporary Mac service bound to `0.0.0.0`. This test did not cover services bound only to the Mac's loopback; restrict service interfaces and verify the behavior you need rather than treating `--isolated` as a host-service firewall.
- `--isolated` controls the workspace's Apple Container network and proxied internet requests; it does not make the container's network behavior identical to the Mac's or establish a general policy for every reachable address.
- Filtering matches a **destination hostname or IPv4 literal** in proxied requests. An allowlisted host that accepts uploads (e.g. `github.com`, a package registry) can still be used to exfiltrate data if the agent holds credentials for it. Keep the allowlist small and credentials scoped.
- Workspaces registered `--isolated` before this feature keep their old network, which has internet access, until it is recreated; `run` warns about this.

---

## 7. Summary

| What | In the container | Protection | Gaps |
| :--- | :--- | :--- | :--- |
| **SSH keys (`~/.ssh`)** | Not mounted | Packages can't read them | — |
| **Rest of your Mac (`$HOME`, other folders)** | Not mounted | Separate VM | Mac services listening on reachable interfaces are reachable (§6) |
| **Project folder** | `/workspace`, read-write | Only the registered folder | The agent can change anything in it (§5) |
| **Agent logins and history** | `home-<slug>`, per workspace | Separate per workspace; `wash` resets | Readable by packages the agent runs (§3) |
| **Shared runtimes** | `/opt/mise`, read-only | A session can't change them | Per-workspace `/root` is writable and persists |
| **Published ports** | Host side bound to Mac `127.0.0.1`; guest loopback is separate | Published port is bound to the Mac's loopback | — |
| **Files that run on your Mac** (git hooks, `.envrc`, IDE tasks) | Writable | Listed when a session ends; `agent-shadow git` turns off hooks and some other git settings | Warns only; other git settings, editors and plain `git` still act on them |
| **Outbound network (`--isolated`)** | Direct public-internet HTTPS blocked in the live probe | Allowlist proxy in its own VM, port 443, Allow/Deny dialog | An allowed host can still receive data; Mac services may be reachable (§6) |
| **Outbound network (default)** | Normal internet; shared `shadow-net` | `traffic` lists connections | Not blocked; containers on the shared network can reach exposed services on each other; the log can be edited inside the container |
| **Agent API key** | In `home-<slug>` or env | One key per workspace, spend limits, revoke + `wash` | Readable inside the container |
| **`rm -rf` of `/`, `/root`, `/workspace`** | Blocked by wrapper | Catches mistakes | Easy to bypass on purpose |

---

## 8. Where agent-shadow and its images come from

What you trust when you install and build, as of now:

| Input | Where it comes from | Verified? |
| :--- | :--- | :--- |
| agent-shadow (Homebrew) | Tagged GitHub source archive named in `Formula/agent-shadow.rb` (the tap is this repository) | Homebrew checks the archive against the formula's SHA-256; no signature. Whoever controls the repository controls both the formula and the code |
| agent-shadow (`./install.sh`) | The checkout you run it from | Whatever you checked out |
| Base images `ubuntu:24.04` / `ubuntu:26.04` (also the proxy image) | Docker Hub | Pinned by digest in `helpers.zsh` (`BASE_IMAGE_SHA`); the container runtime checks downloaded content against it |
| `mise` in the image | GitHub release `v2026.11.10`, `linux-arm64` binary | SHA-256 recorded in `helpers.zsh`, checked with `sha256sum -c` at build time |
| Ubuntu packages (`git`, `curl`, `tinyproxy`, …) | Ubuntu package mirrors via `apt` | Only apt's own signature checks |
| Tools installed with `agent-shadow tools` | Whatever registry `mise` uses for each tool | As far as `mise` checks them |
| Guest kernel | Apple `container`'s recommended kernel download | As far as Apple `container` checks it |

The formula's SHA-256 detects an archive that differs from the one the formula was written for; it is not an
independent signature or protection against a compromised repository or maintainer account.

Builds are still not reproducible: `apt` installs whatever the Ubuntu mirrors serve at build time, and tools
come from their registries. The base-image and mise pins are only as trustworthy as the copy of agent-shadow
they are in. Updating a pin (e.g. for Ubuntu security updates) is a deliberate edit to `helpers.zsh`.
