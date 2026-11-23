# cmd_doctor.zsh — `agent-shadow doctor` and `agent-shadow list` commands

# ---------------------------------------------------------------------------
# cmd_doctor — system health check
# ---------------------------------------------------------------------------
cmd_doctor() {
  _heading "agent-shadow doctor"
  local all_ok=1

  # 1. macOS version
  _info "Checking macOS version…"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    _warn "Not running on macOS — agent-shadow requires macOS 26+ (Tahoe)."
    all_ok=0
  else
    local macos_ver major
    macos_ver="$(sw_vers -productVersion 2>/dev/null || print '0.0')"
    major="${macos_ver%%.*}"
    if (( major < 26 )); then
      _warn "macOS ${macos_ver} detected — macOS 26+ (Tahoe) required for Apple Container networks."
      all_ok=0
    else
      _ok "macOS ${macos_ver}"
      # Check host IPv4 forwarding (required for Apple Container NAT on bridge100)
      local ip_fwd
      ip_fwd="$(sysctl -n net.inet.ip.forwarding 2>/dev/null || print '1')"
      if [[ "$ip_fwd" != "1" ]]; then
        _warn "macOS IPv4 forwarding is disabled (net.inet.ip.forwarding=0)."
        _warn "  Container guest NAT may fail to reach public package mirrors."
        _warn "  Fix with: sudo sysctl -w net.inet.ip.forwarding=1"
        all_ok=0
      else
        _ok "macOS IPv4 forwarding active (net.inet.ip.forwarding=1)"
      fi
    fi
  fi

  # 2. container CLI
  _info "Checking 'container' CLI…"
  if command -v container &>/dev/null; then
    _ok "container CLI: $(container --version 2>/dev/null || print unknown)"
    # The guest kernel is Apple's business: `container system start` installs it when missing.
    if container system status &>/dev/null; then
      _ok "container system service: running"
    else
      _warn "container system service is stopped — run: container system start"
      all_ok=0
    fi
  else
    _warn "'container' CLI not found. Install with: brew install container"
    all_ok=0
  fi

  # 3. Images: built, and from the current template
  _info "Checking images…"
  local distro tag
  for distro in "${SUPPORTED_DISTROS[@]}"; do
    tag="$(_base_tag "$distro")"
    if _image_exists "$tag"; then
      _ok "Image '${tag}' exists"
      _image_is_current "$distro" "$tag" || { _image_warn_if_stale "$distro" "$tag"; all_ok=0; }
    elif [[ "$distro" == "$DEFAULT_DISTRO" ]] || _registry_uses_distro "$distro"; then
      _warn "Image '${tag}' not found — run: agent-shadow init --distro ${distro}"
      all_ok=0
    else
      _info "Image '${tag}' not built (optional) — build with: agent-shadow init --distro ${distro}"
    fi
  done
  if _image_exists "$PROXY_IMAGE"; then
    _ok "Image '${PROXY_IMAGE}' exists (egress approval proxy)"
    _image_is_current proxy "$PROXY_IMAGE" || { _image_warn_if_stale proxy "$PROXY_IMAGE"; all_ok=0; }
  else
    _warn "Image '${PROXY_IMAGE}' not found — --isolated workspaces need it. Run: agent-shadow init"
    all_ok=0
  fi

  # 4. Shared mise volumes
  _info "Checking shared mise volumes…"
  for distro in "${SUPPORTED_DISTROS[@]}"; do
    local vol="${MISE_VOLUME[$distro]}"
    if command container volume ls 2>/dev/null | grep "^${vol}" >/dev/null; then
      _ok "Volume '${vol}' exists (distro: ${distro})"
    else
      _warn "Volume '${vol}' missing — run: agent-shadow init --distro ${distro}"
      all_ok=0
    fi
  done

  # 5. Registered workspaces
  _info "Registered workspaces:"
  _registry_init
  local found=0 slug abspath reg_distro
  while IFS='|' read -r slug abspath reg_distro; do
    [[ -z "$slug" || "$slug" == \#* ]] && continue
    found=1
    if [[ -d "$abspath" ]]; then
      _ok "  ${abspath}  (slug=${slug}, distro=${reg_distro})"
    else
      _warn "  ${abspath}  (slug=${slug}) — directory no longer exists!"
      all_ok=0
    fi
  done < "$REGISTRY"
  (( found )) || _warn "No workspaces registered — run: agent-shadow register <dir>"

  # Summary
  print ""
  if (( all_ok )); then
    _ok "All checks passed — ready to run agents."
  else
    _warn "Some checks failed — see warnings above."
  fi
}

# ---------------------------------------------------------------------------
# cmd_list — tabular list of registered workspaces
# ---------------------------------------------------------------------------
cmd_list() {
  _heading "Registered workspaces"
  _registry_init

  local found=0 slug abspath reg_distro reg_net
  printf "%-20s %-10s %-18s %s\n" "SLUG" "DISTRO" "NETWORK" "PATH" >&2
  printf "%-20s %-10s %-18s %s\n" "────────────────────" "──────────" "──────────────────" "────" >&2

  while IFS='|' read -r slug abspath reg_distro reg_net; do
    [[ -z "$slug" || "$slug" == \#* ]] && continue
    found=1
    printf "%-20s %-10s %-18s %s\n" "$slug" "$reg_distro" "${reg_net:-shadow-net}" "$abspath" >&2
  done < "$REGISTRY"

  (( found )) || _warn "No workspaces registered. Run: agent-shadow register <dir>"
}

# True if any registered workspace uses the given distro.
_registry_uses_distro() {
  local want="$1" slug abspath distro rest
  [[ -f "$REGISTRY" ]] || return 1
  while IFS='|' read -r slug abspath distro rest; do
    [[ -z "$slug" || "$slug" == \#* ]] && continue
    [[ "$distro" == "$want" ]] && return 0
  done < "$REGISTRY"
  return 1
}
