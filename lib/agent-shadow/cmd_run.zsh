# cmd_run.zsh — `agent-shadow run [opts] <agent> [args…]`
# Runs the agent in a new container for the workspace of the current folder, or attaches to the
# workspace's running container (`start`, or another `run` of the same agent).

cmd_run() {
  _session_reset
  local agent=""
  local -a extra_args=()
  while (( $# )); do
    _session_opt "$@" && { shift "$REPLY"; continue; }
    case "$1" in
      --) shift; extra_args+=("$@"); break ;;
      -*) _die "Unknown option for 'run': $1\n  Run 'agent-shadow --help' for usage." ;;
      *)
        # Everything after the agent name belongs to the agent (e.g. `run bash -c '…'`,
        # `run claude --resume`); a leading `--` is accepted and dropped.
        agent="$1"; shift
        [[ "${1:-}" == "--" ]] && shift
        extra_args+=("$@")
        break ;;
    esac
  done
  _reject_isolated_custom_network "run" "$S_ISOLATED" "$S_NET"
  [[ -n "$agent" ]] || \
    _die "Usage: agent-shadow run [opts] <agent> [args...]\n  Example: agent-shadow run claude\n           agent-shadow run bash"
  # `run` starts a program; versions are chosen when installing it
  [[ "$agent" == *@* && "$agent" != */* ]] && \
    _die "'${agent}' looks like a tool version: run takes the program's name.\n  Run it:     agent-shadow run ${agent%%@*}\n  Pick the version with: agent-shadow tools use -g ${agent}"
  # Container names allow only [a-z0-9-]: derive the name part from the program's basename
  local agent_id="${${agent:t}:l}"
  agent_id="${${agent_id//[^a-z0-9]/-}:-agent}"

  # Find the registered workspace from $PWD upward. Resolve symlinks: register stores ${dir:A}.
  local cwd="${PWD:A}"
  _registry_lookup "$cwd" || \
    _die "No registered workspace found for '${cwd}' or any parent directory.\n  Run 'agent-shadow register <dir>' first."
  local slug="$REPLY_SLUG" workspace_root="$REPLY_ROOT"
  local distro; distro="$(_resolve_distro "${S_DISTRO:-$REPLY_DISTRO}")"
  local net; net="$(_session_network "$slug" "${REPLY_NETWORK:-shadow-net}")"
  local tag; tag="$(_base_tag "$distro")"

  local rel="${${cwd#${workspace_root}}#/}"
  local container_cwd="/workspace${rel:+/${rel}}"
  local -a tty_arg=()
  [[ -t 0 ]] && tty_arg=(--tty)

  local -a exec_cmd=("$agent" "${extra_args[@]}")
  [[ "$agent" == bash ]] && exec_cmd=(/bin/bash --login "${extra_args[@]}")
  # Shell-quoted copy for display (e.g. -w "%{http_code}"); keep literal backslashes
  local shown="${(j: :)${(q-)exec_cmd[@]}}"
  shown="${shown//\\/\\\\}"

  _session_env_args                       # validates --env-file before anything starts
  local -a env_args=("${reply[@]}")
  _ensure_container_system

  # Attach to the workspace's running container, if any. It is only reused if it is on exactly
  # the requested network (shared vs --isolated): otherwise this session would get that access.
  local target="" fix=""
  if _container_names | grep -xF -- "agent-${slug}" >/dev/null; then
    target="agent-${slug}"; fix="Stop it and run again:  agent-shadow stop ${slug}"
  elif _container_names | grep -xF -- "agent-${agent_id}-${slug}" >/dev/null; then
    target="agent-${agent_id}-${slug}"
    fix="Exit the other 'agent-shadow run ${agent}' session in this workspace (or: container stop ${target}), then run again."
  fi
  [[ -n "$target" ]] && _require_same_network "$target" "$net" "$fix"

  # Egress approval proxy for isolated workspaces (shadow-<slug>-net, --internal)
  local -a egress_env=()
  local egress_active=0
  if _egress_is_isolated "$net" "$slug" && _egress_check_internal "$net" "$slug"; then
    _egress_ensure_proxy "$slug" "$net"
    egress_env=("${REPLY_EGRESS_ENV[@]}")
    egress_active=1
  fi

  if [[ -n "$target" ]]; then
    _heading "agent-shadow run (attaching to ${target})"
    _info "Executing: ${shown//\%/%%}"   # %% so print -P shows % literally
    local -a exec_args=(--interactive "${tty_arg[@]}" --workdir "$container_cwd" --env "TERM=${TERM:-xterm-256color}")
    exec_args+=("${env_args[@]}" "${egress_env[@]}")
    _egress_session_run "$egress_active" "$slug" \
      _integrity_run "$workspace_root" _run exec "${exec_args[@]}" "$target" "${exec_cmd[@]}"
    return $?
  fi

  _image_exists "$tag" || \
    _die "Base image '${tag}' not found.\n  Run 'agent-shadow init --distro ${distro}' first to build it."
  _image_warn_if_stale "$distro" "$tag"

  _heading "agent-shadow run"
  _info "Agent     : ${agent}"
  _info "Image     : ${tag}"
  _info "Workspace : ${workspace_root} → /workspace"
  _info "CWD inside: ${container_cwd}"
  _info "Network   : ${net}"
  (( egress_active )) && _info "Egress    : approval proxy (denied hosts open an Allow/Deny dialog)"
  _info "Home vol  : home-${slug} → /root (rw)"
  _info "Mise vol  : ${MISE_VOLUME[$distro]} → /opt/mise (ro)"

  _session_container_args "agent-${agent_id}-${slug}" "$net" "$workspace_root" "$slug" "$distro" "$container_cwd"
  local -a run_args=(--rm --interactive "${tty_arg[@]}" "${reply[@]}" "${egress_env[@]}")

  # Non-interactive commands (`run bash -c …`) get live egress progress lines;
  # interactive agents/shells don't (they would garble a full-screen UI).
  [[ "$agent" == bash && "${extra_args[1]:-}" == -c ]] && EGRESS_LIVE=1
  _info "Starting sandbox container…"   # the VM boot is silent and takes a few seconds

  # Warn on exit if files that can run code on the host changed; for isolated workspaces,
  # watch the proxy for hosts needing approval.
  _egress_session_run "$egress_active" "$slug" \
    _integrity_run "$workspace_root" _run run "${run_args[@]}" "$tag" "${exec_cmd[@]}"
}
