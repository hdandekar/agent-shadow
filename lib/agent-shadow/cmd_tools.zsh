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
#   agent-shadow tools use -g node@24
#   agent-shadow tools install python@3.12
#   agent-shadow tools install java@temurin-21
#   agent-shadow tools install npm:@anthropic-ai/claude-code
#   agent-shadow tools ls
#   agent-shadow tools upgrade [tool]
#   agent-shadow tools uninstall <tool>
#   agent-shadow tools exec <tool@ver> -- <cmd...>   (= mise exec)

# ---------------------------------------------------------------------------
# _tools_check_running_agents <vol> <stop:0|1> <mise args as text, for the hint>
# Sessions mount the store, so it must not be written while any runs. Shows what is running;
# with --stop, or a "y" at the prompt, stops the registered workspaces' containers first.
# Other agent-* containers are never stopped by agent-shadow, so they still block.
# ---------------------------------------------------------------------------
_tools_check_running_agents() {
  local vol="$1" stop="$2" args_text="$3" c
  local -a mine=() others=()
  for c in ${(f)"$(_container_names)"}; do
    if _container_owner "$c"; then
      case "$REPLY_ROLE" in
        background) mine+=("$(printf '%-22s background container (agent-shadow start): what runs in it stops too' "$REPLY_SLUG")") ;;
        proxy)      mine+=("$(printf '%-22s egress proxy (--isolated)' "$REPLY_SLUG")") ;;
        *)          mine+=("$(printf '%-22s agent-shadow run %s' "$REPLY_SLUG" "$REPLY_ROLE")") ;;
      esac
    elif [[ "$c" == agent-* ]]; then
      others+=("$c")
    fi
  done

  if (( ${#others} )); then
    _die "Containers named agent-* that aren't from a registered workspace are running:\n$(print -l -- "${others[@]/#/    }")\n  They may have '${vol}' mounted, so 'tools' won't write to it. agent-shadow doesn't stop\n  containers it can't tell are its own: stop them yourself (container stop <name>), then run 'tools' again."
  fi
  (( ${#mine} )) || return 0

  _warn "'tools' writes to the shared toolchains ('${vol}'). These sessions have it mounted and must stop first:"
  print -l -- "${mine[@]/#/    }" >&2
  _info "Project files and each workspace's /root are kept; only the running programs end."
  if (( ! stop )); then
    if [[ -t 0 ]]; then
      local answer=""
      read -r "answer?Stop them and continue? [y/N] " || true
      [[ "$answer" == [yY]* ]] && stop=1
    fi
    (( stop )) || _die "Nothing was stopped or installed.\n  Stop them and continue:  agent-shadow tools --stop ${args_text}\n  Or exit the sessions and run 'tools' again."
  fi
  cmd_stop --all
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
  local distro="$DEFAULT_DISTRO" stop=0
  local -a mise_args=()

  while (( $# )); do
    case "$1" in
      --distro|-d) shift; distro="$1" ;;
      --stop)      stop=1 ;;
      --)          shift; mise_args+=("$@"); break ;;
      # From the mise subcommand on, everything is mise's (incl. `--` and its own --dry-run)
      *)           mise_args+=("$@"); break ;;
    esac
    shift
  done

  if (( ${#mise_args} == 0 )); then
    _die "Usage: agent-shadow tools [--distro NAME] [--stop] <mise-command> [args...]\n\n  Direct pass-through to mise inside the store container with write access.\n\n  Examples:\n    agent-shadow tools use -g node@24\n    agent-shadow tools install python@3.12\n    agent-shadow tools ls\n    agent-shadow tools upgrade node\n    agent-shadow tools uninstall python@3.12\n    agent-shadow tools exec node@24 -- node --version"
  fi

  # Normalize common alias 'update' -> mise's native 'upgrade'
  if [[ "${mise_args[1]}" == "update" ]]; then
    mise_args[1]="upgrade"
  fi

  distro="$(_resolve_distro "$distro")"
  local vol="${MISE_VOLUME[$distro]}"
  local tag; tag="$(_base_tag "$distro")"

  _ensure_container_system
  _tools_check_running_agents "$vol" "$stop" "${(j: :)${(q-)mise_args[@]}}"
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
