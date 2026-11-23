# cmd_stop.zsh — `agent-shadow stop` command
# Shuts down active background workspace container(s).

cmd_stop() {
  local target=""
  local all_flag=0

  while (( $# )); do
    case "$1" in
      --all|-a)  all_flag=1 ;;
      -*) _die "Unknown option for 'stop': $1" ;;
      *)
        if [[ -z "$target" ]]; then
          target="$1"
        else
          _die "Unexpected extra argument for 'stop': $1"
        fi
        ;;
    esac
    shift
  done

  if (( all_flag )); then
    _heading "Stopping all agent-shadow containers"

    # Only containers of registered workspaces: other tools' containers may also be agent-*.
    # Agents first, proxies last: an agent never runs with its egress proxy already gone.
    local -a cnames=() agents=() proxies=()
    local c
    for c in ${(f)"$(_container_names)"}; do
      _shadow_owns_container "$c" || continue
      if [[ "$c" == shadow-proxy-* ]]; then proxies+=("$c"); else agents+=("$c"); fi
    done
    cnames=("${agents[@]}" "${proxies[@]}")
    if (( ${#cnames} == 0 )); then
      _info "No active agent-shadow containers found."
      return 0
    fi

    for c in "${cnames[@]}"; do
      _info "Stopping ${c}…"
      command container stop "$c" >/dev/null 2>&1 || true
      command container rm "$c" >/dev/null 2>&1 || true
      _ok "Stopped and removed ${c}."
    done

    # Change check for every background container started via `start`
    local snap snap_slug
    for snap in "${INTEGRITY_DIR}"/*.start(N); do
      snap_slug="${snap:t:r}"
      if _registry_lookup_by_slug "$snap_slug"; then
        _integrity_check_saved "$snap_slug" "$REPLY_ROOT"
      else
        _integrity_forget "$snap_slug"
      fi
    done
    return 0
  fi

  _resolve_workspace_target "$target"
  local slug="$REPLY_SLUG"
  local workspace_root="$REPLY_ROOT"
  local cname="agent-${slug}"

  _heading "Stopping workspace container: ${cname}"

  local is_running
  is_running="$(_container_names | grep -E "^${cname}$" || true)"

  if [[ -z "$is_running" ]]; then
    _info "Workspace container '${cname}' is not currently running."
    command container rm "$cname" >/dev/null 2>&1 || true
    _integrity_check_saved "$slug" "$workspace_root"
    _egress_stop_proxy_if_idle "$slug"
    return 0
  fi

  command container stop "$cname" >/dev/null 2>&1 || true
  command container rm "$cname" >/dev/null 2>&1 || true
  _ok "Stopped workspace container '${cname}'."
  _integrity_check_saved "$slug" "$workspace_root"
  _egress_stop_proxy_if_idle "$slug"
}
