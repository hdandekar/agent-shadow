<p align="center">
  <img src="assets/logo.png" alt="agent-shadow logo" width="240" />
</p>

# `agent-shadow`

> **S**andboxed **H**ost-**A**gnostic **D**istros, **O**rchestrated **W**orkspaces  
> *Easy to **wash**: coding agents **do** their work in an isolated **shadow** workspace.*

Run AI coding agents (`claude`, `codex`, `agy`, `opencode`, or a plain `bash` shell) on your Mac without giving
them your Mac. Each session is a small Linux VM (Apple `container`, macOS 26+) that sees **one project folder**,
not your home folder, SSH keys, Keychain or other projects.

```bash
cd ~/work/my-app
agent-shadow run claude
```

## What you get, and what you don't

| The agent in the VM… | |
| :--- | :--- |
| can read and change the project folder (it is your Mac folder, mounted at `/workspace`) | yes |
| sees your home folder, `~/.ssh`, `~/.aws`, the Keychain, other projects | no |
| keeps its login, history and session IDs between sessions (per-project `/root`) | yes, until `agent-shadow wash` |
| can change the shared toolchains (Node, Python, agent CLIs) other projects use | no, they are read-only |
| has internet access | yes by default; with `--isolated` only to allowed hosts, and you're asked about the rest |
| can reach services listening on your Mac's network interfaces | yes, also with `--isolated` |
| can plant a git hook, `.envrc` or `package.json` script that later runs on your Mac | it can; agent-shadow lists such changes when the session ends |
| can read the API key you pass in with `--env` | yes; give it a key you can revoke |

The details and the reasons are in [docs/SECURITY.md](docs/SECURITY.md).

---

## Install

Needs macOS 26 (Tahoe) or later and [Homebrew](https://brew.sh). Homebrew also installs Apple's `container` if you don't have it.

```bash
brew tap hdandekar/agent-shadow https://github.com/hdandekar/agent-shadow
brew trust --formula hdandekar/agent-shadow/agent-shadow   # Homebrew 6+ asks you to trust third-party formulae
brew install agent-shadow
```

Upgrade with `brew upgrade agent-shadow`. agent-shadow is not in homebrew-core: this repository is the tap,
which is why `brew tap` needs the URL. What is downloaded and how it is checked:
[docs/SECURITY.md §8](docs/SECURITY.md#8-where-agent-shadow-and-its-images-come-from).

## First session (about 10 minutes, mostly downloads)

```bash
# 1. Once per Mac: build the image and create the shared toolchain volume.
agent-shadow init

# 2. Once per project: register the folder.
agent-shadow register ~/work/my-app

# 3. Once per Mac: install the tools the sessions should have.
agent-shadow tools use -g node@22
agent-shadow tools use -g npm:@anthropic-ai/claude-code

# 4. Every time: run the agent from the project folder (or any folder below it).
cd ~/work/my-app
agent-shadow run claude
```

The first `claude` asks you to log in; the login is kept in that project's `/root`, so you do it once per
project. Prefer an API key? `agent-shadow run --env ANTHROPIC_API_KEY claude` passes your Mac's value in.

`agent-shadow doctor` checks the setup if something doesn't work.

### Installing the agents

`tools` passes its arguments to [mise](https://mise.jdx.dev), so anything mise can install works. Install with
`tools use -g NAME@VERSION`, then start the program **by its name**:

| Agent | Install once | Run |
| :--- | :--- | :--- |
| Claude Code | `agent-shadow tools use -g npm:@anthropic-ai/claude-code` | `agent-shadow run claude` |
| Codex | `agent-shadow tools use -g npm:@openai/codex` | `agent-shadow run codex` |
| Antigravity | `agent-shadow tools use -g agy@latest` | `agent-shadow run agy` |
| opencode | `agent-shadow tools use -g npm:opencode-ai` | `agent-shadow run opencode` |
| a shell | nothing | `agent-shadow run bash` |

The `npm:` ones need Node first (`agent-shadow tools use -g node@22`). Use `use -g`, not `install`:
`install` only downloads, while `use -g` also puts the tool on `PATH` in every session.

---

## Everyday use

### Agent sessions and shells

```bash
agent-shadow run claude                   # an agent
agent-shadow run claude --resume          # everything after the program name goes to the program
agent-shadow run bash                     # a shell, to run tests or try things
agent-shadow run bash -c 'npm test'       # one command, then exit; its exit code is returned
agent-shadow run --env-file .env bash     # options for agent-shadow go before the program name
```

Every `run` starts a fresh container and removes it when you exit. What survives:

| Where | Kept after exit? |
| :--- | :--- |
| `/workspace` (your project folder) | yes, it's your Mac folder |
| `/root` (logins, history, `~/.local/bin`, `uv tool install`, …) | yes, per project, until `agent-shadow wash` |
| toolchains installed with `agent-shadow tools` | yes, in every project |
| `apt-get install …` in the session | no: add it to the image ([Customizing the image](#customizing-the-image)) |

### After a session: review and push from the Mac

When a session ends, agent-shadow lists files it changed that can run code on your Mac:

```text
  ⚠ Files that can run code on your Mac changed since this session started:
       added     .git/hooks/pre-commit
       modified  package.json
```

Look at those before you run anything in the project on the Mac. Add your own patterns (one glob per line,
e.g. `pyproject.toml`, `gradle/wrapper/*`) to `~/.config/agent-shadow/watch`.

The VM has no SSH client and no keys, so `git push` over SSH fails inside it on purpose. Commit and push
on the Mac:

```bash
git diff
agent-shadow git commit -am "agent changes"
agent-shadow git push
```

`agent-shadow git` is your git with the repository's hooks, pager, editor, askpass, credential helper
and gpg program replaced by your own settings. That covers the usual tricks, but a hostile repository has others
(filters, diff drivers, `include.path`): it is **not** a safe way to work in a repository you don't trust.

### Dev servers and a long-running container

```bash
agent-shadow start -p 3000:3000     # background container; port 3000 on your Mac's 127.0.0.1 only
agent-shadow connect                # a shell in it (as many as you like)
npm run dev                         # inside; open http://localhost:3000 on the Mac
agent-shadow stop                   # removes it and lists changed files, as after a run
```

While it runs, `agent-shadow run claude` in the same project opens the agent inside that container instead
of starting another one. Several projects can run at the same time, each in its own terminal.

### Blocking the internet: `--isolated`

```bash
agent-shadow register --isolated ~/work/client-app
```

The project gets its own network with no direct internet. HTTPS goes through a per-project proxy that allows
package registries, GitHub and the LLM APIs, and asks you about any other host:

```text
  Agent in workspace 'client-app' wants to reach:
      api.stripe.com
  Allow for this workspace?            [Deny]  [Allow]
```

Allow, then tell the agent to retry. No restart is needed. Without an answer it is denied after 30 s.

```bash
agent-shadow egress list                 # what's allowed for this project
agent-shadow egress allow api.stripe.com # allow without the dialog; '*.stripe.com' for all subdomains
agent-shadow egress revoke api.stripe.com
agent-shadow egress watch                # the dialogs for start/connect sessions (run in a second terminal)
```

An entry covers exactly that host (`astral.sh` doesn't cover `releases.astral.sh`). Hosts listed in
`~/.config/agent-shadow/allowlist` are allowed for every project. Services listening on your Mac's interfaces
stay reachable; see [SECURITY.md §6](docs/SECURITY.md#6-outbound-network---isolated).

### What did it connect to? `traffic`

```bash
agent-shadow traffic            # hosts not on the allowlist, and anything on your Mac
agent-shadow traffic --all      # every DNS lookup and connection
agent-shadow traffic --follow   # live
agent-shadow traffic --clear
```

It uses the same allowlist as `--isolated`. The record is kept inside the container, where root can edit it,
so it is for review, not protection. To block traffic, use `--isolated`.

### Toolchains

```bash
agent-shadow tools use -g python@3.14     # install and activate for every project
agent-shadow tools ls
agent-shadow tools upgrade node
agent-shadow tools use -g node@22.12.0    # go back to an exact version
agent-shadow tools uninstall python@3.12
```

All projects share these toolchains, so `tools` refuses while any session runs (`agent-shadow stop --all` first).
`mise install` inside a session says which `agent-shadow tools` command to run instead.

### Customizing the image

The image is Ubuntu 24.04 with `git`, `curl`, `unzip`, `xz` and mise: no compilers, no Python or Node (those
come from `tools`). Add your own layers in `~/.config/agent-shadow/Dockerfile.<distro>.append` and rebuild:

```bash
mkdir -p ~/.config/agent-shadow
cat >> ~/.config/agent-shadow/Dockerfile.ubuntu24.append <<'EOF'
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libssl-dev zlib1g-dev jq ripgrep && \
    rm -rf /var/lib/apt/lists/*
EOF
agent-shadow init --force
```

The append file is inserted into [the Containerfile](lib/agent-shadow/image/Containerfile). Don't replace the
Containerfile itself, because agent-shadow relies on what is in it. After an agent-shadow upgrade or a change
to your append file, `run` warns that the image is out of date. It keeps working until you run
`agent-shadow init --force`, and rebuilding loses nothing, because projects, `/root` and toolchains are not in the image.

`ubuntu26` (Ubuntu 26.04) is also available: `agent-shadow init --distro ubuntu26`, then
`register --distro ubuntu26` or `run --distro ubuntu26`. Other distributions are on the
[roadmap](ROADMAP.md#issue-1-more-linux-distributions-fedora-almalinux-alpine-).

### Resetting and removing

```bash
agent-shadow wash                        # empty this project's /root (logins, history); project files stay
agent-shadow unregister ~/work/my-app    # forget a project
agent-shadow uninstall                   # remove all projects' containers, /root volumes, networks and config
agent-shadow uninstall --purge           # ... and the images, toolchains and shadow-net
brew uninstall agent-shadow
```

`uninstall` asks first (`--yes` skips the question) and touches only what belongs to registered projects, so other
tools' containers are left alone. Without `--purge` it keeps the images and toolchains, so a reinstall is ready
at once.

---

## Troubleshooting

| You see | Do |
| :--- | :--- |
| `brew install`: *untrusted tap* | `brew trust --formula hdandekar/agent-shadow/agent-shadow` |
| `No registered workspace found for …` | `agent-shadow register <project folder>`, or `cd` into it |
| `Base image 'agent-base:…' not found` | `agent-shadow init` (with `--distro` if you use another one) |
| `claude: command not found` (or any tool) in a session | install it with `agent-shadow tools use -g …`; `tools install` alone doesn't activate it |
| `'agy@latest' looks like a tool version` | `run` takes the program name: `agent-shadow run agy` |
| `Running agent containers detected` from `tools` | `agent-shadow stop --all`, then run `tools` again |
| `Image '…' was built from an older template` | it still works; `agent-shadow init --force` when convenient |
| `cannot run ssh` on `git push` inside the session | push from the Mac: `agent-shadow git push` |
| `… is already running, but on a different network` | `agent-shadow stop`, then run again |
| anything else | `agent-shadow doctor`; for Apple `container` itself, `container system status` |

---

## Command reference

| Command | What it does |
| :--- | :--- |
| `init [--distro NAME] [--subnet CIDR] [--force]` | Build the images, create the toolchain volume and `shadow-net` (`--force` rebuilds) |
| `register [dir] [--distro NAME] [--isolated \| --network NAME] [--subnet CIDR]` | Register a project folder |
| `unregister <dir>` | Forget a project (prints how to delete its volume and network) |
| `run [opts] <program> [args…]` | Run a program in the project of the current folder |
| `start [dir] [opts]` / `stop [dir] [--all]` | Start / stop the project's background container |
| `connect [dir]` (alias `shell`) | Shell in the background container |
| `wash [dir] [--force]` | Empty the project's `/root` |
| `tools <mise args…>` | Run mise with write access to the toolchains |
| `list` | Registered projects |
| `traffic [dir] [--all] [--follow] [--clear]` | Recorded DNS lookups and connections |
| `egress [dir] list \| allow <host> \| revoke <host> \| watch` | Approvals for `--isolated` projects |
| `git <args…>` | Host git with repository hooks and helpers pinned |
| `doctor` | Check macOS, `container`, images, volumes and projects |
| `uninstall [--purge] [--yes]` | Remove agent-shadow's containers, volumes and config |

Options for `run` and `start` (before the program name):
`-p, --publish HOST:CONTAINER` (always bound to `127.0.0.1`, repeatable) ·
`--env KEY[=VALUE]` (repeatable) · `--env-file FILE` · `-i, --isolated` · `--network NAME` ·
`-d, --distro NAME` · `--cpus N` (default 4) · `-m, --memory SIZE` (default `4g`).

---

## Development

```bash
./install.sh       # install this checkout as ~/.local/bin/agent-shadow (run again after changes)
make lint test     # syntax check and host-only tests (also in CI)
make mutants       # deliberately broken copies the tests must catch
make e2e           # on a Mac: real containers; cleans up after itself
```

[docs/TESTING.md](docs/TESTING.md) covers the Mac suites and how to report results, and
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) explains how it works. [ROADMAP.md](ROADMAP.md) lists what's next.
Pull requests are welcome. Run `make lint test mutants`, and `make e2e` on a Mac for anything that touches containers.

Built on [Apple container](https://github.com/apple/container) and [mise](https://github.com/jdx/mise).
MIT License, see [LICENSE](LICENSE).
