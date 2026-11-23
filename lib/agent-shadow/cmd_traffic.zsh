# cmd_traffic.zsh — `agent-shadow traffic`: the outbound connections a workspace's containers made
# (recorded inside the container by traffic-monitor.sh: a record for review, not protection).
# Hides allowlisted hosts by default, decided exactly as the --isolated egress proxy decides.
# The network gateway is the Mac itself and is labelled as such.

# _traffic_known <dest> : allowlisted (uses the caller's `eres`, from _allowlist_eres)
_traffic_known() { _allowlist_match "$1" "${eres[@]}"; }
# _traffic_dest <dest> : the destination, with "(your Mac)" when it is the network gateway
_traffic_dest() { if [[ -n "$gw" && "${1%:*}" == "$gw" ]]; then print -r -- "$1  (your Mac)"; else print -r -- "$1"; fi; }

cmd_traffic() {
  local target=""
  local show_all=0
  local follow_mode=0
  local clear_mode=0

  while (( $# )); do
    case "$1" in
      --all|-a)    show_all=1 ;;
      --follow|-f) follow_mode=1 ;;
      --clear|-c)  clear_mode=1 ;;
      -*) _die "Unknown option for 'traffic': $1\n  Usage: agent-shadow traffic [dir] [--all] [--follow] [--clear]" ;;
      *)
        if [[ -z "$target" ]]; then
          target="$1"
        else
          _die "Unexpected extra argument for 'traffic': $1"
        fi
        ;;
    esac
    shift
  done

  _resolve_workspace_target "$target"
  local slug="$REPLY_SLUG"
  local distro="$REPLY_DISTRO"
  local cname="agent-${slug}"
  local vol_home="home-${slug}"
  local tag; tag="$(_base_tag "$distro")"
  local -a eres=(${(f)"$(_allowlist_eres "$slug")"})
  local gw; gw="$(_net_gateway "$REPLY_NETWORK")"

  _heading "agent-shadow traffic (${slug})"

  # Check if container is running
  local is_running=""
  is_running="$(_container_names | grep -E "^${cname}$" || true)"

  # Clear log mode
  if (( clear_mode )); then
    _info "Clearing network traffic log for '${slug}'…"
    local clear_cmd="chattr -a /root/.traffic.log 2>/dev/null || true; truncate -s 0 /root/.traffic.log 2>/dev/null || true; chattr +a /root/.traffic.log 2>/dev/null || true"
    if [[ -n "$is_running" ]]; then
      command container exec "$cname" /bin/sh -c "$clear_cmd" 2>/dev/null || true
    else
      command container run --rm --volume "${vol_home}:/root" "$tag" /bin/sh -c "$clear_cmd" 2>/dev/null || true
    fi
    _ok "Traffic log cleared for '${slug}'."
    return 0
  fi

  # Follow / Live stream mode
  if (( follow_mode )); then
    if [[ -z "$is_running" ]]; then
      _die "Container '${cname}' is not currently running.\n  Start it first with 'agent-shadow start' or run an agent."
    fi
    if (( show_all )); then
      _info "Streaming ALL unique external calls in real time (Ctrl+C to stop)…"
    else
      _info "Streaming UNKNOWN external calls in real time (Ctrl+C to stop)…"
      _info "Allowlisted hosts are hidden; connections to your Mac are shown."
    fi
    print ""
    printf "%-20s %-6s %s\n" "TIMESTAMP" "TYPE" "DESTINATION"
    printf "%-20s %-6s %s\n" "────────────────────" "──────" "───────────"

    # Stream and filter via Zsh loop
    command container exec "$cname" tail -f -n 20 /root/.traffic.log 2>/dev/null | while IFS=$'\t' read -r ts type dest; do
      [[ -z "$ts" || -z "$dest" ]] && continue
      if (( ! show_all )) && _traffic_known "$dest"; then
        continue
      fi
      printf "%-20s %-6s %s\n" "$ts" "$type" "$(_traffic_dest "$dest")"
    done
    return 0
  fi

  # Audit / Display mode
  local log_content=""
  if [[ -n "$is_running" ]]; then
    log_content="$(command container exec "$cname" cat /root/.traffic.log 2>/dev/null || true)"
  else
    log_content="$(command container run --rm --volume "${vol_home}:/root" "$tag" cat /root/.traffic.log 2>/dev/null || true)"
  fi

  if [[ -z "$log_content" ]]; then
    _ok "No external network calls recorded for '${slug}'."
    _info "All requests were internal/localhost or no network traffic has occurred yet."
    return 0
  fi

  local -a unknown_lines=()
  local -a all_lines=()
  local ts type dest

  while IFS=$'\t' read -r ts type dest; do
    [[ -z "$ts" || -z "$dest" ]] && continue
    all_lines+=("${ts}\t${type}\t${dest}")
    if ! _traffic_known "$dest"; then
      unknown_lines+=("${ts}\t${type}\t${dest}")
    fi
  done <<< "$log_content"

  if (( ! show_all )); then
    if (( ${#unknown_lines} == 0 )); then
      _ok "No connections to hosts outside the allowlist recorded for '${slug}'."
      _info "All ${#all_lines} recorded connections went to allowlisted hosts."
      _info "Use 'agent-shadow traffic --all' to inspect all recorded calls."
      return 0
    fi

    print -P "%B%F{red}🔴 Connections to hosts outside the allowlist (${slug}):%f%b"
    printf "%-20s %-6s %s\n" "TIMESTAMP" "TYPE" "DESTINATION"
    printf "%-20s %-6s %s\n" "────────────────────" "──────" "───────────"
    local entry
    local -a parts=()
    for entry in "${unknown_lines[@]}"; do
      parts=(${(s:\t:)entry})
      printf "%-20s %-6s %s\n" "${parts[1]}" "${parts[2]}" "$(_traffic_dest "${parts[3]}")"
    done
    print ""
    _warn "If these are legitimate project endpoints, add them to: ${ALLOWLIST_FILE}"
    _info "Use 'agent-shadow traffic --all' to inspect all calls."
    return 0
  fi

  # Show all mode
  _info "Displaying ALL recorded unique external calls (${#all_lines} total):"
  printf "%-20s %-6s %-12s %s\n" "TIMESTAMP" "TYPE" "STATUS" "DESTINATION"
  printf "%-20s %-6s %-12s %s\n" "────────────────────" "──────" "────────────" "───────────"

  local entry dest_status
  local -a parts=()
  for entry in "${all_lines[@]}"; do
    parts=(${(s:\t:)entry})
    if _traffic_known "${parts[3]}"; then
      dest_status="[KNOWN]"
    else
      dest_status="[UNKNOWN ⚠️]"
    fi
    printf "%-20s %-6s %-12s %s\n" "${parts[1]}" "${parts[2]}" "$dest_status" "$(_traffic_dest "${parts[3]}")"
  done
}
