# Testing agent-shadow on a Mac

Apple `container` only runs on macOS, so this is where agent-shadow is really tested. The checks
cover what agent-shadow decides (the flags it passes, the files it writes, what it refuses, which
containers it touches), not Apple `container` itself. The host-only `make test` and `make mutants`
run in CI and aren't covered here.

## Before you start

- macOS 26 or later, Apple `container` installed and running (`container system status`).
- Run from this repository checkout.
- No agent-shadow container running (`agent-shadow stop --all`): the suite refuses to start otherwise,
  because `tools` (which it tests) refuses to write toolchains while sessions use them.

## 1. `make e2e`

```zsh
make e2e                          # all sections: about 10 minutes, plus one image build the first time
make e2e SECTIONS=run,egress      # only some sections (setup always runs)
```

**What it touches on your Mac:** everything it creates is named `e2e<random id>` (folders,
workspaces, containers, volumes, networks) and is removed when it exits, even after a failure or
Ctrl-C. It keeps its own registry and approvals in a temp folder, so your workspaces aren't read, and
its own toolchain volume `shadow-e2e-mise` (kept so node is downloaded once; `E2E_CLEAN_MISE=1` removes
it), so your `mise-store` isn't touched. It builds its own images `shadow-e2e-base:ubuntu24` and
`shadow-e2e-proxy:latest` from this checkout (the first time, and again whenever the template changed) and keeps
them (`E2E_CLEAN_IMAGES=1` removes them): your `agent-base`/`agent-proxy` images are never rebuilt. `shadow-net`
is created if missing and never removed. Approval dialogs are suppressed.

| Section | agent-shadow behaviour each check protects |
| :--- | :--- |
| setup | `init`, `register`, `register --isolated`, `tools use -g` work without a terminal |
| tools | toolchains installed with `tools` are on PATH in a session; `tools` refuses while a session runs |
| run | project mounted read-write at `/workspace`; a subfolder maps to the same subfolder; `/opt/mise` read-only; `mise install` in a session explains what to do; `/root` persists per workspace; `--env`, `--env KEY`, `--env-file` arrive; the exit code is returned; an interactive shell's prompt names the workspace; a git hook written by the session is reported |
| lifecycle | `start -p` publishes on 127.0.0.1 only (not on the Mac's network address); `connect` and an attaching `run` get the toolchains and `--env-file`; `stop` reports files changed since `start` and removes the container |
| network | a running container is reused only on the requested network (shared vs `--isolated`, for `run` and `connect`); a refused run starts no proxy; `stop` stops the workspace's proxy |
| egress | an `--isolated` network has no direct internet; an allowlisted registry works through the proxy; other hosts are refused and reported; `egress allow` takes effect; approval during a session works on retry and is stored for that workspace only; the proxy stops with the session |
| wash | `/root` is emptied, project files are untouched |
| registry | two folders with the same name get separate slugs and separate `/root`; `unregister` by path removes only that folder |
| traffic | a host not on the allowlist is listed; `'*.example.org'` covers `example.org` exactly as in the proxy; a connection to the Mac (gateway) is listed and labelled; `--all`, `--clear` |
| doctor | finds the images; reports a registered folder that is gone; reports an image built from an older template, and `run` warns about it but still runs |
| stopall | `stop --all` stops workspace containers and leaves another `agent-*` container running |
| uninstall | `./install.sh` installs a working command; `agent-shadow uninstall --yes` removes the workspaces' containers, volumes and isolated networks, the CLI and config, and keeps unrelated `agent-*`/`home-*`/`shadow-*` resources, the images, the toolchain volume and `shadow-net` |

**Reading the result:** every line is `✓ PASS`, `✗ FAIL` or `- SKIP (reason)`; nothing only warns.
A failure prints the command, its exit code and the last 25 lines of its output. The run ends with
`Results: N passed, M failed, K skipped` and the path of a log in `tests/tmp/`.
A SKIP is expected only for "not reachable on the Mac's network address" when `en0`/`en1` has no address.

## 2. `make mutants-mac`: do these checks really fail?

```zsh
zsh tests/mutants.zsh --list                       # what each mutant breaks
make mutants-mac                                   # all Mac mutants
zsh tests/mutants.zsh --only mise-writable,reuse-unchecked
```

Each mutant copies the repository to a temp folder (your checkout is never changed), puts back one
real bug (`/opt/mise` mounted read-write, ports published on every interface, `--env-file` dropped
on attach, the network check skipped, the proxy allowing every host, `stop --all` or uninstall
touching other tools' containers, …) and runs the `make e2e` sections that should catch it.

- `✓ KILLED`: a check failed, as it should; the line names the check that caught it.
- `✗ SURVIVED`: the bug went unnoticed, so that check needs work. Paste it.
- `? STALE`: the code changed and the mutant no longer applies.

The unmodified copy is run first; if that baseline fails, the mutant results mean nothing.

**Why it is slow:** every mutant is a separate `make e2e` run of its sections, setup included
(`init` check, two `register`s, `tools use -g node@24`), and every `run` boots a fresh VM. With 24 Mac
mutants plus the baseline, expect roughly 40–70 minutes (not measured). Use `--only` to check a few.
The last two mutants (`traffic-awk-buffered`, `prompt-missing`) change an image script, so the test image is
rebuilt for each, and once more by your next `make e2e`: a few extra minutes each.

## 3. Two checks a script can't judge

Do these after a change to egress approval or to how `run` starts an agent.

1. **Approval dialog.** `agent-shadow register --isolated <dir>`, then in it
   `agent-shadow run bash -c 'curl -sI https://example.org'`.
   A macOS dialog asks to allow `example.org` for that workspace (Deny after 30 s). Allow, re-run: it connects.
2. **Interactive agent.** `agent-shadow run claude` (or another agent) in a registered folder. The agent's
   screen is not garbled by agent-shadow output, and after you exit, a change to e.g. `package.json`
   made during the session is listed.

## 4. Reporting

Paste:
- the `make e2e` log from `tests/tmp/` (or at least every `✗ FAIL` block),
- the `make mutants-mac` summary and any `SURVIVED`/`STALE` lines,
- for section 3: what you saw,
- `sw_vers -productVersion` and `container --version`.
