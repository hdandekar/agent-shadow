# cmd_register.zsh — `agent-shadow register` and `agent-shadow unregister`
# Creates an isolated network + persistent /root volume for a workspace.

# Safety: paths that must never be registered
readonly -a _FORBIDDEN_PATHS=("/" "$HOME" "/Users")

cmd_register() {
  local target_dir="" distro="$DEFAULT_DISTRO"
  local isolated_flag=0 custom_net="" custom_subnet=""

  while (( $# )); do
    case "$1" in
      --distro|-d)   shift; distro="$1" ;;
      --isolated|-i) isolated_flag=1 ;;
      --network)     shift; custom_net="$1" ;;
      --subnet)      shift; custom_subnet="$1" ;;
      -*) _die "Unknown option for 'register': $1\n  Usage: agent-shadow register [dir] [--distro NAME] [--isolated | --network NAME] [--subnet CIDR]" ;;
      *)  target_dir="$1" ;;
    esac
    shift
  done

  _reject_isolated_custom_network "register" "$isolated_flag" "$custom_net"

  [[ -z "$target_dir" ]] && target_dir="$PWD"

  # Resolve symlinks + make absolute (zsh :A modifier)
  target_dir="${target_dir:A}"

  # Guardrails — refuse dangerous top-level paths
  for f in "${_FORBIDDEN_PATHS[@]}"; do
    [[ "$target_dir" == "$f" ]] && \
      _die "Refusing to register protected path: ${target_dir}\n  Registering '/', '\$HOME', or '/Users' is not allowed."
  done

  [[ ! -d "$target_dir" ]] && \
    _die "Directory does not exist: ${target_dir}"

  distro="$(_resolve_distro "$distro")"

  local slug net vol_home
  slug="$(_registry_slug_for "$target_dir")"
  vol_home="home-${slug}"
  if [[ "$slug" != "$(_slugify "$target_dir")" ]] && ! _registry_lookup_path "$target_dir"; then
    _info "Another registered folder is already called '$(_slugify "$target_dir")'; this one gets '${slug}'."
  fi

  if [[ -n "$custom_net" ]]; then
    net="$custom_net"
  elif (( isolated_flag )); then
    net="shadow-${slug}-net"
  else
    net="shadow-net"
  fi

  _heading "agent-shadow register"
  _info "Path  : ${target_dir}"
  _info "Slug  : ${slug}"
  _info "Distro: ${distro}"
  _info "Net   : ${net} (isolated=${isolated_flag}${custom_subnet:+, subnet=${custom_subnet}})"
  _info "Home  : ${vol_home}"

  # Build network creation arguments
  local -a net_args=()
  # Isolated networks are host-only: no direct internet; egress goes through the approval proxy
  [[ -z "$custom_net" ]] && (( isolated_flag )) && net_args+=(--internal)
  [[ -n "$custom_subnet" ]] && net_args+=(--subnet "$custom_subnet")
  net_args+=("$net")

  # Create or ensure network exists
  _info "Ensuring network '${net}' exists…"
  command container network create "${net_args[@]}" 2>/dev/null || \
    _warn "Network '${net}' may already exist — skipping."
  _ok "Network '${net}' ready."

  # Create persistent /root volume
  _info "Creating volume '${vol_home}'…"
  command container volume create "$vol_home" 2>/dev/null || \
    _warn "Volume '${vol_home}' may already exist — skipping."
  _ok "Volume '${vol_home}' ready."

  # Persist to registry
  _registry_add "$slug" "$target_dir" "$distro" "$net"
  _ok "Workspace registered: ${target_dir}"
  _info "  slug=${slug}  distro=${distro}  network=${net}"
  _info "Next: agent-shadow run <agent>"
}

cmd_unregister() {
  local target_dir="${1:-}"
  [[ -z "$target_dir" ]] && \
    _die "Usage: agent-shadow unregister <dir>"

  # By registered path (the folder may already be deleted) or by slug.
  local slug reg_net
  if _registry_lookup_path "${target_dir:A}" || _registry_lookup_by_slug "$target_dir"; then
    slug="$REPLY_SLUG"; target_dir="$REPLY_ROOT"
    reg_net="$REPLY_NETWORK"   # remembered before the entry is gone (cleanup hints)
  else
    _die "'${target_dir}' is not a registered workspace (neither its path nor its slug).\n  Run 'agent-shadow list' to view registered workspaces."
  fi

  _heading "agent-shadow unregister"
  _info "Path: ${target_dir}"
  _info "Slug: ${slug}"

  _registry_remove "$slug"
  _integrity_forget "$slug"
  rm -rf "$(_egress_ws_dir "$slug")" 2>/dev/null || true
  _warn "Workspace removed from the registry."

  # Containers of this workspace (incl. stopped ones): they keep the volume in use.
  local -a leftovers=()
  leftovers=(${(f)"$(_container_names -a | grep -E "^(agent-(.+-)?${slug}|shadow-proxy-${slug})\$" || true)"})

  _info "Volumes and networks are NOT deleted automatically. To clean up:"
  (( ${#leftovers} )) && _info "  container rm -f ${leftovers[*]}      # first: they still use the volume"
  _info "  container volume rm home-${slug}"
  # Only a workspace-specific network (registered --isolated) is ours to delete;
  # never suggest deleting shadow-net or a custom shared network.
  if [[ "$reg_net" == "shadow-${slug}-net" ]]; then
    _info "  container network rm shadow-${slug}-net"
  fi
}
