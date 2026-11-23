# cmd_uninstall.zsh — `agent-shadow uninstall [--purge] [--yes]`
# Removes what agent-shadow created for the registered workspaces, and its config. Only resources
# of registered workspaces are touched: other tools' containers, volumes and networks may also be
# called agent-*, home-* or shadow-*. Images, toolchains and shadow-net are kept unless --purge.
# Homebrew: run this first, then `brew uninstall agent-shadow` (Homebrew can't remove containers).

cmd_uninstall() {
  local purge=0 yes=0
  while (( $# )); do
    case "$1" in
      --purge) purge=1 ;;
      --yes|-y) yes=1 ;;
      *) _die "Unknown option for 'uninstall': $1\n  Usage: agent-shadow uninstall [--purge] [--yes]" ;;
    esac
    shift
  done

  local -a slugs=() nets=()
  local slug abspath distro net
  if [[ -f "$REGISTRY" ]]; then
    while IFS='|' read -r slug abspath distro net; do
      [[ -z "$slug" || "$slug" == \#* ]] && continue
      slugs+=("$slug")
      [[ "$net" == "shadow-${slug}-net" ]] && nets+=("$net")
    done < "$REGISTRY"
  fi

  local -a cnames=() vnames=() nnames=() inames=() existing
  local c v
  for c in ${(f)"$(_container_names -a)"}; do _shadow_owns_container "$c" && cnames+=("$c"); done
  existing=(${(f)"$(command container volume ls 2>/dev/null | awk 'NR == 1 && $1 ~ /^[A-Z]+$/ { next } NF { print $1 }')"})
  for slug in "${slugs[@]}"; do (( ${existing[(Ie)home-${slug}]} )) && vnames+=("home-${slug}"); done
  if (( purge )); then
    for v in ${(u)MISE_VOLUME}; do (( ${existing[(Ie)$v]} )) && vnames+=("$v"); done
  fi
  existing=(${(f)"$(_network_names)"})
  for net in "${nets[@]}"; do (( ${existing[(Ie)$net]} )) && nnames+=("$net"); done
  (( purge )) && (( ${existing[(Ie)shadow-net]} )) && nnames+=(shadow-net)
  if (( purge )); then
    for distro in "${SUPPORTED_DISTROS[@]}"; do _image_exists "$(_base_tag "$distro")" && inames+=("$(_base_tag "$distro")"); done
    _image_exists "$PROXY_IMAGE" && inames+=("$PROXY_IMAGE")
  fi

  # A copy installed by ./install.sh is removed too; Homebrew's and a checkout's are not.
  local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/agent-shadow"
  local bin_link="${XDG_BIN_HOME:-$HOME/.local/bin}/agent-shadow"
  local local_install=0
  [[ "${_SCRIPT_DIR:h}" == "${data_dir:A}" ]] && local_install=1

  _heading "agent-shadow uninstall"
  _info "This permanently removes:"
  (( ${#cnames} )) && _info "  containers: ${cnames[*]}"
  (( ${#vnames} )) && _info "  volumes:    ${vnames[*]}   (agent logins, history, /root state$( (( purge )) && print ', toolchains'))"
  (( ${#nnames} )) && _info "  networks:   ${nnames[*]}"
  (( ${#inames} )) && _info "  images:     ${inames[*]}"
  _info "  config:     ${CONF_DIR} (workspace registry, egress approvals)"
  (( local_install )) && _info "  program:    ${data_dir}, ${bin_link}"
  (( purge )) || _info "Kept (no re-download needed): images, toolchain volume, shadow-net. Use --purge to remove them too."
  _info "Your project folders are not touched."
  if (( ! yes )); then
    [[ -t 0 ]] || _die "Not a terminal: re-run with --yes to confirm."
    print -n "  Proceed? [y/N]: "
    local ans; read -r ans || ans=n
    [[ "$ans" == [Yy] ]] || { _info "Nothing was removed."; return 0; }
  fi

  for c in "${cnames[@]}"; do
    command container stop "$c" >/dev/null 2>&1 || true
    command container rm -f "$c" >/dev/null 2>&1 || true
  done
  for v in "${vnames[@]}"; do command container volume rm "$v" >/dev/null 2>&1 || true; done
  for net in "${nnames[@]}"; do command container network rm "$net" >/dev/null 2>&1 || true; done
  for c in "${inames[@]}"; do
    command container image rm "$c" >/dev/null 2>&1 || true
    rm -f "$(_image_stamp_file "$c")"
  done
  rm -rf "$CONF_DIR"
  if (( local_install )); then
    rm -rf "$data_dir"
    rm -f "$bin_link" "${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions/_agent-shadow"
  fi
  _ok "agent-shadow removed."
  [[ "$_SCRIPT_DIR" == */Cellar/* ]] && _info "Now remove the program: brew uninstall agent-shadow"
  return 0
}
