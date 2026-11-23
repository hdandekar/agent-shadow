# cmd_init.zsh — `agent-shadow init`: build the images, create the toolchain volume and shadow-net.

cmd_init() {
  local distro="$DEFAULT_DISTRO" custom_subnet="" force=0
  while (( $# )); do
    case "$1" in
      --distro|-d) shift; distro="$1" ;;
      --subnet)    shift; custom_subnet="$1" ;;
      --force|-f)  force=1 ;;
      *) _die "Unknown option for 'init': $1\n  Usage: agent-shadow init [--distro NAME] [--subnet CIDR] [--force]" ;;
    esac
    shift
  done
  distro="$(_resolve_distro "$distro")"
  local tag; tag="$(_base_tag "$distro")"
  local vol="${MISE_VOLUME[$distro]}"

  _heading "agent-shadow init (distro=${distro})"
  _ensure_container_system

  command container volume create "$vol" >/dev/null 2>&1 || true
  _ok "Toolchain volume '${vol}' ready."
  local -a net_args=()
  [[ -n "$custom_subnet" ]] && net_args+=(--subnet "$custom_subnet")
  command container network create "${net_args[@]}" shadow-net >/dev/null 2>&1 || true
  _ok "Shared network 'shadow-net' ready."

  _image_ensure proxy "$PROXY_IMAGE" "$force"   # egress proxy for --isolated workspaces
  _image_ensure "$distro" "$tag" "$force"
  _info "Next: agent-shadow register <project-dir>"
}
