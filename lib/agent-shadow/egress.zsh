# egress.zsh — Outbound (egress) approval for --isolated workspaces
#
# Topology (verified on Apple container 1.7.1 with tests/egress_probe.zsh):
#
#   agent ──(shadow-<slug>-net, --internal: no internet)──► shadow-proxy-<slug> ──(shadow-net)──► internet
#                                                            tinyproxy, deny-by-default allowlist
#
#   - The proxy is a separate VM: a root agent cannot tamper with it, and its
#     ip_forward=0 means the agent cannot route packets through it.
#   - The proxy joins shadow-net FIRST so its default route has internet access.
#   - Containers on an internal network cannot resolve each other by name, so the
#     agent is pointed at the proxy by IP (HTTP(S)_PROXY).
#   - The allowlist lives on the host (${EGRESS_DIR}/<slug>/) and is mounted
#     read-only into the proxy; SIGUSR1 makes tinyproxy re-read it.
#   - A watcher polls the proxy log for "Proxying refused on filtered domain"
#     and asks the developer via a native macOS dialog (Deny / Allow, timeout → Deny).

readonly EGRESS_DIR="${CONF_DIR}/egress"
readonly PROXY_IMAGE="${AGENT_SHADOW_IMAGE_PREFIX}-proxy:latest"
readonly PROXY_PORT=3128
readonly PROXY_PORT_HEX="0C38"
: ${EGRESS_DIALOG_TIMEOUT:=30}
: ${EGRESS_POLL_SECONDS:=2}

_egress_proxy_name() { print -r -- "shadow-proxy-${1}"; }
_egress_ws_dir()     { print -r -- "${EGRESS_DIR}/${1}"; }

# Egress control applies to the workspace's dedicated network only
_egress_is_isolated() { [[ "$1" == "shadow-${2}-net" ]]; }

_egress_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  print -r -- "$s"
}

# Hostname, IPv4, or allowlist glob with a single leading "*." — nothing else.
# Keeps regexes, shell, and AppleScript metacharacters out of every file and dialog.
_egress_valid_host() {
  local h="$1"
  [[ -n "$h" && ${#h} -le 253 ]] || return 1
  [[ "$h" =~ '^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$' ]]
}

# "*.npmjs.org" → "^(.*\.)?npmjs\.org$"   "pypi.org" → "^pypi\.org$"
_egress_glob_to_ere() {
  local p="${1:l}" prefix=""
  if [[ "$p" == '*.'* ]]; then
    prefix='(.*\.)?'
    p="${p#\*.}"
  fi
  p="${p//./\\.}"
  print -r -- "^${prefix}${p}\$"
}

# ---------------------------------------------------------------------------
# IPv4 / CIDR helpers
# ---------------------------------------------------------------------------
_ip_to_int() {
  local -a o=("${(@s:.:)1}")
  (( ${#o} == 4 )) || return 1
  local x
  for x in "${o[@]}"; do [[ "$x" == <0-255> ]] || return 1; done
  print $(( (o[1] << 24) + (o[2] << 16) + (o[3] << 8) + o[4] ))
}

_ip_in_cidr() {
  local ip="$1" base="${2%/*}" bits="${2#*/}"
  [[ "$bits" == <0-32> ]] || return 1
  local a b
  a="$(_ip_to_int "$ip")" || return 1
  b="$(_ip_to_int "$base")" || return 1
  local mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (a & mask) == (b & mask) ))
}

# ---------------------------------------------------------------------------
# Network inspection
# ---------------------------------------------------------------------------
_net_subnet() {
  command container network inspect "$1" 2>/dev/null | grep -m1 '"ipv4Subnet"' | cut -d'"' -f4
}

# Addresses of a running container ("ip,ip"), empty if not running / none listed.
_container_ips() {
  _container_addrs | awk -v n="$1" '$1 == n { print $2; exit }'
}

# Networks a running container is attached to, matched by subnet (one per line).
_container_networks() {
  local ips; ips="$(_container_ips "$1")"
  [[ -n "$ips" ]] || return 0
  local -A subs=()
  local n sn ip hit
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    sn="$(_net_subnet "$n")"; [[ -n "$sn" ]] && subs[$n]="$sn"
  done < <(_network_names)
  local -a nets=()
  for ip in ${(s:,:)ips}; do
    hit=""
    for n in "${(@k)subs}"; do _ip_in_cidr "$ip" "${subs[$n]}" && { hit="$n"; break; }; done
    nets+=("${hit:-unknown network (${ip})}")
  done
  print -rl -- "${(u)nets[@]}"
}

# 0 only if the running container is attached to <net> and nothing else: every one of
# its addresses is inside <net>'s subnet. Unknown network or no addresses -> 1 (fail closed).
_container_only_on() {
  local cname="$1" net="$2" sn ips ip
  sn="$(_net_subnet "$net")";   [[ -n "$sn" ]]  || return 1
  ips="$(_container_ips "$cname")"; [[ -n "$ips" ]] || return 1
  for ip in ${(s:,:)ips}; do _ip_in_cidr "$ip" "$sn" || return 1; done
  return 0
}

# 0 if <net>'s subnet overlaps another network's subnet (then addresses can't tell the
# networks apart). Two CIDR blocks overlap iff one's base address lies inside the other.
_net_subnet_overlaps_other() {
  local net="$1" sn other osn
  sn="$(_net_subnet "$net")"; [[ -n "$sn" ]] || return 1
  while IFS= read -r other; do
    [[ -z "$other" || "$other" == "$net" ]] && continue
    osn="$(_net_subnet "$other")"; [[ -n "$osn" ]] || continue
    if _ip_in_cidr "${osn%/*}" "$sn" || _ip_in_cidr "${sn%/*}" "$osn"; then
      print -r -- "$other"; return 0
    fi
  done < <(_network_names)
  return 1
}

# Refuse to reuse a running container whose networks differ from the requested one.
# Never stops or deletes anything; volumes and approvals are untouched.
#   _require_same_network <container> <requested-net> <how-to-fix>
_require_same_network() {
  local cname="$1" net="$2" fix="$3" clash
  # Matching is by address, so overlapping subnets would make it unreliable: fail closed.
  if clash="$(_net_subnet_overlaps_other "$net")"; then
    _die "Can't verify which network container '${cname}' is on: '${net}' and '${clash}' use overlapping address ranges.\n  Nothing was started. Give one of them a different subnet, or stop the container first:  ${fix}"
  fi
  _container_only_on "$cname" "$net" && return 0
  local have; have="$(_container_networks "$cname")"
  _die "Container '${cname}' is already running, but on a different network than requested.\n  Requested: ${net}\n  Running on: ${${(j:, :)${(f)have}}:-unknown (no address listed)}\n  Reusing it would give this session that network's access, so nothing was started.\n  ${fix}\n  (Volumes, files and egress approvals are kept.)"
}

_net_is_internal() {
  command container network inspect "$1" 2>/dev/null | grep '"mode"[[:space:]]*:[[:space:]]*"hostOnly"' >/dev/null
}

# Returns 0 if the isolated network blocks direct internet; warns and returns 1 otherwise.
_egress_check_internal() {
  local net="$1" slug="$2"
  # `run --isolated` on a workspace registered without it: create the host-only network now
  if ! command container network inspect "$net" &>/dev/null || \
     [[ -z "$(command container network inspect "$net" 2>/dev/null | grep '"id"')" ]]; then
    _info "Creating host-only network '${net}'…"
    command container network create --internal "$net" >/dev/null 2>&1 || \
      _die "Failed to create isolated network '${net}'."
    return 0
  fi
  _net_is_internal "$net" && return 0
  _warn "Network '${net}' has direct internet access (created before egress control)."
  _warn "  Outbound approval is OFF for this session. To enable it, stop this workspace and recreate the network:"
  _warn "    agent-shadow stop ${slug} && container network delete ${net} && agent-shadow register --isolated <dir>"
  return 1
}

# ---------------------------------------------------------------------------
# Allowlist rendering: defaults + global allowlist + per-workspace approvals
# ---------------------------------------------------------------------------
_egress_read_list() {
  local file="$1" line
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_egress_trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    print -r -- "$line"
  done < "$file"
}

# ---------------------------------------------------------------------------
# The allowlist, one definition for the proxy filter AND `agent-shadow traffic`: built-in
# defaults + ~/.config/agent-shadow/allowlist + this workspace's approvals, each turned into
# an anchored ERE ('*.astral.sh' matches astral.sh and every subdomain). Invalid entries skipped.
# ---------------------------------------------------------------------------
_allowlist_eres() {   # _allowlist_eres <slug> : one ERE per line, no duplicates
  local -a pats=("${DEFAULT_ALLOWLIST[@]}")
  pats+=("${(@f)$(_egress_read_list "$ALLOWLIST_FILE")}")
  [[ -n "${1:-}" ]] && pats+=("${(@f)$(_egress_read_list "$(_egress_ws_dir "$1")/approved")}")
  local -a res=()
  local p
  for p in "${pats[@]}"; do
    [[ -n "$p" ]] && _egress_valid_host "$p" && res+=("$(_egress_glob_to_ere "$p")")
  done
  print -rl -- "${(u)res[@]}"
}

# _allowlist_match <host|ip[:port]> <ere…> : 0 if allowed (same EREs tinyproxy applies)
_allowlist_match() {
  local h="${1:l}" re; shift
  h="${h%:<->}"
  for re in "$@"; do [[ "$h" =~ $re ]] && return 0; done
  return 1
}

_net_gateway() {
  command container network inspect "$1" 2>/dev/null | grep -m1 '"ipv4Gateway"' | cut -d'"' -f4
}

_egress_render() {
  local slug="$1" cidr="${2:-}"
  local dir; dir="$(_egress_ws_dir "$slug")"
  mkdir -p "$dir"
  [[ -f "${dir}/approved" ]] || : > "${dir}/approved"
  if [[ -n "$cidr" ]]; then
    print -r -- "$cidr" > "${dir}/cidr"
  elif [[ -f "${dir}/cidr" ]]; then
    cidr="$(<"${dir}/cidr")"
  else
    return 0   # proxy never started — rendered on first start
  fi

  # In-place writes (proven with SIGUSR1 reload through the :ro bind mount)
  _allowlist_eres "$slug" > "${dir}/filter"
  cat > "${dir}/tinyproxy.conf" <<EOF
# Generated by agent-shadow — do not edit (regenerated on every start/approval)
User nobody
Group nogroup
Port ${PROXY_PORT}
Listen 0.0.0.0
Timeout 600
MaxClients 100
Allow ${cidr}
ConnectPort 443
Filter "/cfg/filter"
FilterExtended On
FilterDefaultDeny Yes
LogLevel Info
EOF
  chmod 755 "$dir" 2>/dev/null || true
  chmod 644 "${dir}/filter" "${dir}/tinyproxy.conf" 2>/dev/null || true
}

_egress_is_approved() {
  local slug="$1" host="$2"
  local f; f="$(_egress_ws_dir "$slug")/approved"
  [[ -f "$f" ]] && grep -qxF -- "$host" "$f"
}

# ---------------------------------------------------------------------------
# Proxy container lifecycle
# ---------------------------------------------------------------------------
_egress_proxy_running() {
  _container_names | grep -xF -- "$(_egress_proxy_name "$1")" >/dev/null
}

_egress_reload() {
  local slug="$1" pname; pname="$(_egress_proxy_name "$slug")"
  _egress_proxy_running "$slug" || return 0
  command container exec "$pname" kill -USR1 1 >/dev/null 2>&1 || true
}

# Ensure the proxy for <slug> runs on <net>. Sets REPLY_PROXY_IP, REPLY_EGRESS_CIDR, REPLY_EGRESS_ENV.
_egress_ensure_proxy() {
  local slug="$1" net="$2"
  local pname dir cidr
  pname="$(_egress_proxy_name "$slug")"
  dir="$(_egress_ws_dir "$slug")"

  cidr="$(_net_subnet "$net")"
  [[ -n "$cidr" ]] || _die "Could not read the subnet of network '${net}'."
  _egress_render "$slug" "$cidr"

  local -a proxy_args=(
    --detach
    --name "$pname"
    --network shadow-net
    --network "$net"
    --volume "${dir}:/cfg:ro"
    --cpus 1
    --memory 512m
  )

  _image_exists "$PROXY_IMAGE" || _die "Egress proxy image '${PROXY_IMAGE}' not found.\n  Run 'agent-shadow init' to build it."
  _image_warn_if_stale proxy "$PROXY_IMAGE"

  if _egress_proxy_running "$slug"; then
    _egress_reload "$slug"
  else
    _info "Starting egress proxy '${pname}'…"
    command container network create shadow-net >/dev/null 2>&1 || true
    command container rm -f "$pname" >/dev/null 2>&1 || true
    command container run "${proxy_args[@]}" "$PROXY_IMAGE" >/dev/null || \
      _die "Failed to start egress proxy '${pname}'."
  fi

  # Wait until tinyproxy is listening
  local i listening=0
  for i in {1..20}; do
    if command container exec "$pname" sh -c \
        "awk 'NR>1 && \$4==\"0A\" {print \$2}' /proc/net/tcp | grep -qi ':${PROXY_PORT_HEX}\$'" 2>/dev/null; then
      listening=1; break
    fi
    sleep 1
  done
  (( listening )) || _die "Egress proxy '${pname}' did not start listening on :${PROXY_PORT}.\n  Inspect: container logs ${pname}"

  # The proxy's address on the internal network
  REPLY_PROXY_IP=""
  local ips ip
  for i in {1..10}; do
    ips="$(command container exec "$pname" hostname -I 2>/dev/null || true)"
    for ip in ${=ips}; do
      if _ip_in_cidr "$ip" "$cidr"; then REPLY_PROXY_IP="$ip"; break; fi
    done
    [[ -n "$REPLY_PROXY_IP" ]] && break
    sleep 1
  done
  [[ -n "$REPLY_PROXY_IP" ]] || _die "Could not determine egress proxy address on '${net}'."

  REPLY_EGRESS_CIDR="$cidr"
  local url="http://${REPLY_PROXY_IP}:${PROXY_PORT}"
  local no_proxy="localhost,127.0.0.1,::1,${cidr}"
  REPLY_EGRESS_ENV=(
    --env "HTTP_PROXY=${url}"  --env "http_proxy=${url}"
    --env "HTTPS_PROXY=${url}" --env "https_proxy=${url}"
    --env "NO_PROXY=${no_proxy}" --env "no_proxy=${no_proxy}"
  )
  _ok "Egress proxy ready: ${url} (deny-by-default allowlist)"
}

# Stop the proxy unless another container of this workspace is still running
_egress_stop_proxy_if_idle() {
  local slug="$1" pname; pname="$(_egress_proxy_name "$slug")"
  _egress_proxy_running "$slug" || return 0
  if _container_names | grep -E "^agent-(.+-)?${slug}\$" >/dev/null; then
    return 0
  fi
  command container stop "$pname" >/dev/null 2>&1 || true
  command container rm "$pname" >/dev/null 2>&1 || true
  _info "Egress proxy '${pname}' stopped."
}

# ---------------------------------------------------------------------------
# Approval
# ---------------------------------------------------------------------------
_egress_approve() {
  local slug="$1" host="${2:l}"
  local f; f="$(_egress_ws_dir "$slug")/approved"
  mkdir -p "${f:h}"
  _egress_is_approved "$slug" "$host" || print -r -- "$host" >> "$f"
  _egress_render "$slug"
  _egress_reload "$slug"
}

_egress_revoke() {
  local slug="$1" host="${2:l}"
  local f; f="$(_egress_ws_dir "$slug")/approved"
  [[ -f "$f" ]] || return 0
  local -a keep=("${(@f)$(grep -vxF -- "$host" "$f" || true)}")
  print -rl -- "${keep[@]}" | grep -v '^$' > "${f}.tmp" || true
  mv -f "${f}.tmp" "$f"
  _egress_render "$slug"
  _egress_reload "$slug"
}

# Ask the developer. AGENT_SHADOW_APPROVE=allow|deny bypasses the dialog (tests / headless).
_egress_ask() {
  local slug="$1" host="$2"
  case "${AGENT_SHADOW_APPROVE:-}" in
    allow) return 0 ;;
    deny)  return 1 ;;
  esac
  command -v osascript &>/dev/null || return 1
  local r
  r="$(osascript -e "display dialog \"Agent in workspace '${slug}' wants to reach:\n\n${host}\n\nAllow for this workspace?\" with title \"agent-shadow\" buttons {\"Deny\", \"Allow\"} default button \"Deny\" giving up after ${EGRESS_DIALOG_TIMEOUT} with icon caution" 2>/dev/null)" || return 1
  [[ "$r" == *"button returned:Allow"* && "$r" != *"gave up:true"* ]]
}

# tinyproxy: NOTICE ... Proxying refused on filtered domain "www.wikipedia.org"
_egress_parse_denied() {
  local l="$1"
  [[ "$l" == *'Proxying refused on filtered domain "'*'"'* ]] || return 1
  local h="${l#*filtered domain \"}"
  h="${h%%\"*}"
  print -r -- "${h:l}"
}

# Host from tinyproxy's 'Established connection to host "x"' line (for live progress)
_egress_parse_established() {
  local l="$1"
  [[ "$l" == *'Established connection to host "'*'"'* ]] || return 1
  local h="${l#*connection to host \"}"
  h="${h%%\"*}"
  print -r -- "${h:l}"
}

typeset -gA _EGRESS_ASKED=()
typeset -gA _EGRESS_SHOWN=()
# Live progress on fd 3 (set by _egress_session_run for non-interactive runs only:
# lines printed over a full-screen agent UI would garble it).
EGRESS_LIVE=${EGRESS_LIVE:-0}
_egress_live() { (( EGRESS_LIVE )) && print -u3 -P "%F{208}  ↳ egress:%f $*" 2>/dev/null; return 0; }

# Handle one proxy log line. Prints "APPROVED <host>" / "DENIED <host>" for decisions.
_egress_handle_line() {
  local slug="$1" line="$2" host
  if (( EGRESS_LIVE )) && host="$(_egress_parse_established "$line")"; then
    (( ${+_EGRESS_SHOWN[$host]} )) || { _EGRESS_SHOWN[$host]=1; _egress_live "connected to ${host}"; }
    return 0
  fi
  host="$(_egress_parse_denied "$line")" || return 0
  _egress_valid_host "$host" || return 0
  _egress_live "%F{yellow}blocked ${host}%f"
  (( ${+_EGRESS_ASKED[$host]} )) && return 0     # ask once per watcher session
  _EGRESS_ASKED[$host]=1
  _egress_is_approved "$slug" "$host" && return 0
  if _egress_ask "$slug" "$host"; then
    _egress_approve "$slug" "$host"
    print -r -- "APPROVED ${host}"
  else
    print -r -- "DENIED ${host}"
  fi
}

# Poll the proxy log and handle new lines (no dependency on `container logs --follow`).
_egress_watch() {
  local slug="$1" pname; pname="$(_egress_proxy_name "$slug")"
  local out seen=0 total failures=0 i
  local -a lines
  out="$(command container logs "$pname" 2>/dev/null || true)"
  [[ -n "$out" ]] && seen=${#${(@f)out}}           # only react to lines after start
  while true; do
    if out="$(command container logs "$pname" 2>/dev/null)"; then
      failures=0
      lines=("${(@f)out}")
      [[ -z "$out" ]] && lines=()
      total=${#lines}
      (( total < seen )) && seen=0                    # proxy restarted
      for (( i = seen + 1; i <= total; i++ )); do
        _egress_handle_line "$slug" "${lines[i]}"
      done
      seen=$total
    else
      (( ++failures >= 3 )) && return 0                # proxy gone
    fi
    sleep "$EGRESS_POLL_SECONDS"
  done
}

# Run a command with a background approval watcher (for `run`). Preserves exit code.
#   _egress_session_run <active 0|1> <slug> <cmd...>
_egress_session_run() {
  local active="$1" slug="$2"; shift 2
  if (( ! active )); then
    "$@"
    return $?
  fi
  local log; log="$(_egress_ws_dir "$slug")/session.log"
  : > "$log"
  # Proxy log length now: only refusals after this point belong to this session
  # (the proxy may be shared with a background container).
  local pname; pname="$(_egress_proxy_name "$slug")"
  local start_lines=0 plog
  plog="$(command container logs "$pname" 2>/dev/null || true)"
  [[ -n "$plog" ]] && start_lines=${#${(@f)plog}}
  exec 3>&2                                     # live progress goes to the terminal
  _egress_watch "$slug" >> "$log" 2>&1 &
  local wpid=$!

  local rc=0
  "$@" || rc=$?

  pkill -TERM -P "$wpid" 2>/dev/null || true   # sleep / open dialog
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  exec 3>&-

  local -a approved=("${(@f)$(grep '^APPROVED ' "$log" 2>/dev/null | cut -d' ' -f2)}")
  local -a denied=("${(@f)$(grep '^DENIED ' "$log" 2>/dev/null | cut -d' ' -f2)}")
  [[ -n "${approved[1]:-}" ]] && _info "Egress approved this session: ${approved[*]}"
  [[ -n "${denied[1]:-}" ]] && _info "Egress denied this session:   ${denied[*]}  (approve later: agent-shadow egress allow <host>)"

  # Refusals the watcher never got to (short commands can finish before its next poll).
  local -a unasked=()
  local -A handled=()
  local h l
  for h in "${approved[@]}" "${denied[@]}"; do [[ -n "$h" ]] && handled[$h]=1; done
  plog="$(command container logs "$pname" 2>/dev/null || true)"
  if [[ -n "$plog" ]]; then
    local -a plines=("${(@f)plog}")
    for l in "${(@)plines[start_lines+1,-1]}"; do
      h="$(_egress_parse_denied "$l")" || continue
      _egress_valid_host "$h" || continue
      (( ${+handled[$h]} )) && continue
      _egress_is_approved "$slug" "$h" && continue
      handled[$h]=1; unasked+=("$h")
    done
  fi
  if (( ${#unasked} )); then
    _warn "Blocked this session before it could be asked: ${unasked[*]}"
    local hint="agent-shadow egress allow ${unasked[1]}"
    local -a labels=("${(@s:.:)unasked[1]}")
    # e.g. releases.astral.sh -> also offer '*.astral.sh' (an approval covers one exact host)
    (( ${#labels} >= 3 )) && hint+="   (or '*.${(j:.:)labels[2,-1]}' for all its subdomains)"
    _info "  Approve and re-run: ${hint}"
  fi

  _egress_stop_proxy_if_idle "$slug"
  return $rc
}

# ---------------------------------------------------------------------------
# `agent-shadow egress [dir] list | allow <host> | revoke <host> | watch`
# ---------------------------------------------------------------------------
cmd_egress() {
  local target=""
  case "${1:-}" in
    list|allow|revoke|watch|"") ;;
    *) target="$1"; shift ;;
  esac
  local sub="${1:-list}"
  (( $# )) && shift

  _resolve_workspace_target "$target"
  local slug="$REPLY_SLUG" net="$REPLY_NETWORK"
  local dir; dir="$(_egress_ws_dir "$slug")"

  case "$sub" in
    list)
      _heading "agent-shadow egress (${slug})"
      if _egress_is_isolated "$net" "$slug"; then
        _ok "Workspace network '${net}' is isolated — outbound traffic goes through the approval proxy."
      else
        _warn "Workspace uses '${net}' (not isolated) — egress approval is not active."
        _info "  Enable with: agent-shadow register --isolated <dir>"
      fi
      if _egress_proxy_running "$slug"; then
        _ok "Proxy '$(_egress_proxy_name "$slug")' is running."
      else
        _info "Proxy '$(_egress_proxy_name "$slug")' is not running (starts with run/start)."
      fi
      print -P "\n%BApproved for this workspace%b (${dir}/approved):" >&2
      local -a appr=("${(@f)$(_egress_read_list "${dir}/approved")}")
      if [[ -n "${appr[1]:-}" ]]; then print -rl -- "${appr[@]/#/  }" >&2; else print "  (none)" >&2; fi
      print -P "\n%BGlobal allowlist%b (${ALLOWLIST_FILE}):" >&2
      local -a glob=("${(@f)$(_egress_read_list "$ALLOWLIST_FILE")}")
      if [[ -n "${glob[1]:-}" ]]; then print -rl -- "${glob[@]/#/  }" >&2; else print "  (none)" >&2; fi
      print -P "\n%BBuilt-in defaults%b: ${#DEFAULT_ALLOWLIST} patterns (npm, PyPI, crates, GitHub, Ubuntu, mise, LLM APIs)" >&2
      ;;
    allow)
      local host="${1:-}"
      [[ -n "$host" ]] || _die "Usage: agent-shadow egress [dir] allow <host>"
      host="${host:l}"
      _egress_valid_host "$host" || _die "Invalid host '${host}'. Use a hostname, IPv4 address, or '*.domain'."
      _egress_approve "$slug" "$host"
      _ok "Allowed '${host}' for workspace '${slug}'."
      ;;
    revoke)
      local host="${1:-}"
      [[ -n "$host" ]] || _die "Usage: agent-shadow egress [dir] revoke <host>"
      host="${host:l}"
      _egress_is_approved "$slug" "$host" || _die "'${host}' is not in the approved list for '${slug}'."
      _egress_revoke "$slug" "$host"
      _ok "Revoked '${host}' for workspace '${slug}'."
      ;;
    watch)
      _egress_is_isolated "$net" "$slug" || _die "Workspace '${slug}' is not isolated — nothing to watch."
      _egress_proxy_running "$slug" || _die "Proxy for '${slug}' is not running. Start the workspace first (agent-shadow start / run)."
      _heading "Watching outbound requests for '${slug}' (Ctrl+C to stop)"
      _info "Denied hosts will open an Allow/Deny dialog (${EGRESS_DIALOG_TIMEOUT}s timeout → Deny)."
      _egress_watch "$slug"
      _info "Proxy '$(_egress_proxy_name "$slug")' stopped — watcher exiting."
      ;;
    *)
      _die "Unknown egress subcommand '${sub}'.\n  Usage: agent-shadow egress [dir] list | allow <host> | revoke <host> | watch"
      ;;
  esac
}
