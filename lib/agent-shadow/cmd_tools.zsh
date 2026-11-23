# cmd_tools.zsh — `agent-shadow tools` command
#
# PURPOSE
#   Manages the shared mise-store volume with write access, gated behind a
#   safety check ensuring no agent containers are currently running.
#
#   agent-shadow does NOT act as a package manager or installer. That is mise's
#   domain. Every argument is passed directly through to `mise "$@"` inside
#   the store container, followed by `mise reshim` to refresh shims.
#
# USAGE EXAMPLES
#   agent-shadow tools use -g node@22
#   agent-shadow tools install python@3.12
#   agent-shadow tools install java@temurin-21
#   agent-shadow tools install npm:@anthropic-ai/claude-code
#   agent-shadow tools ls
#   agent-shadow tools upgrade [tool]
#   agent-shadow tools uninstall <tool>
#   agent-shadow tools exec <tool@ver> -- <cmd...>   (= mise exec)

# ---------------------------------------------------------------------------
# _tools_check_running_agents <vol>
# Aborts if any container whose name starts with 'agent-' is live.
# ---------------------------------------------------------------------------
_tools_check_running_agents() {
  local vol="$1"
  _info "Checking for running agent containers…"

  local running_agents=""
  running_agents="$(_container_names \
    | grep '^agent-' || true)"

  if [[ -n "$running_agents" ]]; then
    _die "Running agent containers detected:\n${running_agents}\n\n  Stop all agent containers before running 'tools'.\n  ('tools' mounts '${vol}' read-write, which requires exclusive access.)"
  fi

  _ok "No running agent containers — safe to mount '${vol}' read-write."
}

# ---------------------------------------------------------------------------
# _tools_run_in_store <vol> <tag> <bash-command-string>
# Spins up a throwaway container with mise-store mounted read-write.
# ---------------------------------------------------------------------------
_tools_run_in_store() {
  local vol="$1" tag="$2" bash_cmd="$3"

  # A TTY only when there is one: without a terminal (scripts, `make e2e`) Apple container
  # refuses to start a --tty container ("Operation not supported by device").
  local -a tty_arg=()
  [[ -t 0 ]] && tty_arg=(--tty)
  local -a run_args=(
    --rm
    --interactive
    "${tty_arg[@]}"
    --volume "${vol}:/opt/mise"
    --env "MISE_DATA_DIR=/opt/mise"
    --env "MISE_GLOBAL_CONFIG_FILE=/opt/mise/config.toml"
    --env "RUSTUP_HOME=/opt/mise/rustup"
    --env "CARGO_HOME=/root/.cargo"
    --env "MISE_CACHE_DIR=/tmp/mise/cache"
    --env "MISE_TMP_DIR=/tmp/mise/tmp"
    --env "BASH_ENV=/etc/profile.d/mise.sh"
    --env "PATH=/opt/mise/shims:/opt/mise/bin:/usr/local/bin:/root/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  )

  _run run "${run_args[@]}" "$tag" /bin/bash --login -c "$bash_cmd"
}

# ---------------------------------------------------------------------------
# Main tools dispatcher — direct pass-through to mise
# ---------------------------------------------------------------------------
cmd_tools() {
  local distro="$DEFAULT_DISTRO"
  local -a mise_args=()

  while (( $# )); do
    case "$1" in
      --distro|-d) shift; distro="$1" ;;
      --)          shift; mise_args+=("$@"); break ;;
      # From the mise subcommand on, everything is mise's (incl. `--` and its own --dry-run)
      *)           mise_args+=("$@"); break ;;
    esac
    shift
  done

  if (( ${#mise_args} == 0 )); then
    _die "Usage: agent-shadow tools [--distro NAME] <mise-command> [args...]\n\n  Direct pass-through to mise inside the store container with write access.\n\n  Examples:\n    agent-shadow tools use -g node@22\n    agent-shadow tools install python@3.12\n    agent-shadow tools ls\n    agent-shadow tools upgrade node\n    agent-shadow tools uninstall python@3.12\n    agent-shadow tools exec node@22 -- node --version"
  fi

  # Normalize common alias 'update' -> mise's native 'upgrade'
  if [[ "${mise_args[1]}" == "update" ]]; then
    mise_args[1]="upgrade"
  fi

  distro="$(_resolve_distro "$distro")"
  local vol="${MISE_VOLUME[$distro]}"
  local tag; tag="$(_base_tag "$distro")"

  _ensure_container_system
  _tools_check_running_agents "$vol"
  _heading "tools: mise ${mise_args[*]}"

  # Run mise with supplied arguments and reshim to ensure binary shims are up to date.
  # Backward-compatible bootstrap for existing images:
  # 1. Ensure mise is in /opt/mise/bin if only in /root/.local/bin
  # 2. Ensure MISE_GLOBAL_CONFIG_FILE is persisted in /opt/mise/config.toml
  local bootstrap="export PATH=\"/opt/mise/shims:/opt/mise/bin:/usr/local/bin:/root/.local/bin:\$PATH\"; export MISE_GLOBAL_CONFIG_FILE=/opt/mise/config.toml; if [ ! -x /usr/local/bin/mise ] && [ -x /root/.local/bin/mise ]; then mkdir -p /opt/mise/bin && cp -f /root/.local/bin/mise /opt/mise/bin/mise 2>/dev/null || true; fi; if [ -f /root/.config/mise/config.toml ] && [ ! -f /opt/mise/config.toml ]; then cp -f /root/.config/mise/config.toml /opt/mise/config.toml 2>/dev/null || true; fi"
  local -a quoted_args=()
  for arg in "${mise_args[@]}"; do
    quoted_args+=("${(q)arg}")
  done
  # Keep mise's own exit code (reshim/cp must not mask a failed install).
  local bash_cmd="${bootstrap}; mise ${quoted_args[*]}; rc=\$?; cp -f /root/.config/mise/config.toml /opt/mise/config.toml 2>/dev/null || true; mise reshim; exit \$rc"
  local rc=0
  _tools_run_in_store "$vol" "$tag" "$bash_cmd" || rc=$?
  if (( rc != 0 )); then
    _err "mise ${mise_args[1]} failed (exit code ${rc})."
    return $rc
  fi
  _ok "mise ${mise_args[1]} complete."
}
