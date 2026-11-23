# cmd_start.zsh — `agent-shadow start [dir] [opts]`: a background workspace container
# (dev servers, published ports) that `connect` and `run` attach to.

cmd_start() {
  _session_reset
  local target=""
  while (( $# )); do
    _session_opt "$@" && { shift "$REPLY"; continue; }
    case "$1" in
      -*) _die "Unknown option for 'start': $1" ;;
      *)
        [[ -z "$target" ]] || _die "Unexpected extra argument for 'start': $1"
        target="$1" ;;
    esac
    shift
  done
  _reject_isolated_custom_network "start" "$S_ISOLATED" "$S_NET"

  _resolve_workspace_target "$target"
  local slug="$REPLY_SLUG" workspace_root="$REPLY_ROOT"
  local distro; distro="$(_resolve_distro "${S_DISTRO:-$REPLY_DISTRO}")"
  local net; net="$(_session_network "$slug" "$REPLY_NETWORK")"
  local cname="agent-${slug}" tag; tag="$(_base_tag "$distro")"

  _session_env_args                       # validates --env-file before anything starts
  _ensure_container_system
  _image_exists "$tag" || \
    _die "Base image '${tag}' not found.\n  Run 'agent-shadow init --distro ${distro}' first to build it."

  if _container_names | grep -xF -- "$cname" >/dev/null; then
    _require_same_network "$cname" "$net" "Stop it and start again:  agent-shadow stop ${slug}"
    _ok "Workspace container '${cname}' is already running."
    _info "Connect to it with:  agent-shadow connect"
    _info "Stop it with:        agent-shadow stop"
    return 0
  fi
  _image_warn_if_stale "$distro" "$tag"
  command container rm -f "$cname" >/dev/null 2>&1 || true   # a stopped one with the same name

  _heading "agent-shadow start"
  _info "Workspace : ${workspace_root} → /workspace"
  _info "Container : ${cname}"
  _info "Network   : ${net}"
  _info "Home vol  : home-${slug} → /root"

  _session_container_args "$cname" "$net" "$workspace_root" "$slug" "$distro" /workspace
  local -a run_args=(--detach "${reply[@]}")

  local egress_active=0
  if _egress_is_isolated "$net" "$slug" && _egress_check_internal "$net" "$slug"; then
    _egress_ensure_proxy "$slug" "$net"
    run_args+=("${REPLY_EGRESS_ENV[@]}")
    egress_active=1
  fi

  _integrity_save "$slug" "$workspace_root"   # baseline for the change check in `stop`
  _run run "${run_args[@]}" "$tag" /bin/bash -c "trap : TERM INT; sleep infinity & wait"
  _ok "Workspace container '${cname}' started in background."
  _info "Connect anytime with: agent-shadow connect"
  _info "Run agents with:      agent-shadow run <agent>"
  _info "Stop container with:  agent-shadow stop"
  (( egress_active )) && _info "Approve outbound hosts: agent-shadow egress watch   (run in a second terminal)"
  return 0
}
