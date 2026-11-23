# cmd_wash.zsh — `agent-shadow wash` command
# Resets the persistent /root volume (home-<slug>) for a clean slate.

cmd_wash() {
  local target=""
  local force=0

  while (( $# )); do
    case "$1" in
      --force|-f) force=1 ;;
      -*) _die "Unknown option for 'wash': $1\n  Usage: agent-shadow wash [dir_or_slug] [--force]" ;;
      *)
        if [[ -z "$target" ]]; then
          target="$1"
        else
          _die "Unexpected extra argument for 'wash': $1"
        fi
        ;;
    esac
    shift
  done

  _resolve_workspace_target "$target"
  local slug="$REPLY_SLUG"
  local workspace_root="$REPLY_ROOT"
  local vol_home="home-${slug}"
  local distro="$REPLY_DISTRO"
  local tag; tag="$(_base_tag "$distro")"
  local cname="agent-${slug}"

  _heading "agent-shadow wash: ${slug}"

  # Stop any running container for this workspace
  local is_running="$(_container_names | grep -E "^${cname}$" || true)"
  if [[ -n "$is_running" ]]; then
    _info "Stopping active container '${cname}' before wash…"
    command container stop "$cname" >/dev/null 2>&1 || true
    command container rm "$cname" >/dev/null 2>&1 || true
  fi

  # List directories/files inside the home volume to be deleted
  local -a items_found=()
  local raw_ls
  raw_ls="$(command container run --rm --volume "${vol_home}:/root" "$tag" ls -A /root 2>/dev/null || true)"
  items_found=(${(f)raw_ls})

  print -P "\n%F{yellow}⚠️  WARNING: You are about to wash the agent state for '%B${slug}%b'%f"
  print -P "   This will permanently reset /root (volume: %B${vol_home}%b)."

  if (( ${#items_found} > 0 )); then
    print -P "   The following items will be wiped:"
    for item in "${items_found[@]}"; do
      print -P "     • %F{red}${item}%f"
    done
  else
    print -P "   Volume is currently empty or has no state."
  fi

  print -P "\n   %BNote:%b Your host files in %B${workspace_root}%b will not be touched.\n"

  if (( ! force )); then
    print -n "  Are you sure you want to proceed with wash? [y/N]: "
    local confirm
    read -r confirm || confirm="n"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      _info "Wash cancelled."
      return 0
    fi
  fi

  command container volume rm "$vol_home" >/dev/null 2>&1 || true
  command container volume create "$vol_home" >/dev/null 2>&1 || true
  _ok "Workspace state 'home-${slug}' washed successfully (clean slate)."
}
