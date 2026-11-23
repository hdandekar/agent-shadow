# cmd_connect.zsh — `agent-shadow connect` / `shell` command
# Connects an interactive shell into the workspace's background container.

cmd_connect() {
  local target="" custom_net="" isolated_flag=0

  while (( $# )); do
    case "$1" in
      --isolated|-i) isolated_flag=1 ;;
      --network) shift; custom_net="$1" ;;
      -*) _die "Unknown option for 'connect': $1" ;;
      *)
        if [[ -z "$target" ]]; then
          target="$1"
        else
          _die "Unexpected extra argument for 'connect': $1"
        fi
        ;;
    esac
    shift
  done

  _reject_isolated_custom_network "connect" "$isolated_flag" "$custom_net"

  _resolve_workspace_target "$target"
  local slug="$REPLY_SLUG"
  local cname="agent-${slug}"
  local workspace_root="$REPLY_ROOT"   # saved: cmd_start below re-resolves REPLY_*

  # Requested network, worked out exactly like `start` does
  local net
  if [[ -n "$custom_net" ]]; then
    net="$custom_net"
  elif (( isolated_flag )); then
    net="shadow-${slug}-net"
  else
    net="$REPLY_NETWORK"
  fi
  local -a start_opts=()
  [[ -n "$custom_net" ]] && start_opts+=(--network "$custom_net")
  (( isolated_flag )) && start_opts+=(--isolated)

  local is_running=""
  is_running="$(_container_names | grep -E "^${cname}$" || true)"

  if [[ -z "$is_running" ]]; then
    _warn "Workspace container '${cname}' is not running."
    print -n "  Start container in background and connect now? [Y/n]: "
    local ans
    read -r ans || ans="y"
    if [[ "$ans" =~ ^[Nn]$ ]]; then
      _info "Aborted."
      return 0
    fi
    cmd_start "${start_opts[@]}" ${target:+"$target"}
  else
    # Same rule as run/start: never open a shell in a container on another network.
    _require_same_network "$cname" "$net" "Stop it and connect again:  agent-shadow stop ${slug}   (if you started it with --isolated, use: agent-shadow connect --isolated)"
  fi

  local -a tty_arg=()
  [[ -t 0 ]] && tty_arg=(--tty)

  _heading "Connecting to ${cname}"
  _integrity_run "$workspace_root" \
    _run exec --interactive "${tty_arg[@]}" --env "TERM=${TERM:-xterm-256color}" "$cname" /bin/bash --login
}
