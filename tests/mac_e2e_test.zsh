#!/bin/zsh
# mac_e2e_test.zsh — end-to-end tests on a real Mac with Apple `container`. Nothing is faked.
#
#   zsh tests/mac_e2e_test.zsh                     all sections
#   zsh tests/mac_e2e_test.zsh --only run,egress   some sections (setup always runs)
#   zsh tests/mac_e2e_test.zsh --list              list sections
#   zsh tests/mac_e2e_test.zsh --keep              leave the test resources for inspection
#
# What it touches on your Mac:
#   - Everything it creates is named with a random e2e<id> prefix (workspaces, containers,
#     volumes, networks) and is removed by the exit trap; nothing else is stopped or deleted.
#   - Its own config dir (registry, approvals) in a temp folder: your workspaces are not read.
#   - Its own toolchain volume (default 'shadow-e2e-mise', kept between runs so node is
#     downloaded once; E2E_CLEAN_MISE=1 removes it). Your 'mise-store' is not touched.
#   - Its own images 'shadow-e2e-base:ubuntu24' and 'shadow-e2e-proxy:latest', built from this
#     checkout's template the first time and whenever the template changed, kept between runs
#     (E2E_CLEAN_IMAGES=1 removes them). Your agent-base/agent-proxy images are never rebuilt.
#   - Shared, never removed: the shadow-net network.
#   - Egress dialogs are suppressed (AGENT_SHADOW_APPROVE).
# Exits non-zero if any check fails. A log is written to tests/tmp/.

set -uo pipefail

SCRIPT_DIR="${${(%):-%x}:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
BIN="${REPO_ROOT}/bin/agent-shadow"
SECTIONS=(tools run lifecycle network egress wash registry traffic doctor stopall uninstall)

ONLY="" KEEP=0
while (( $# )); do
  case "$1" in
    --only) shift; ONLY="${1:-}" ;;
    --keep) KEEP=1 ;;
    --list) print -l "${SECTIONS[@]}"; exit 0 ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
  shift
done
local -a selected=("${SECTIONS[@]}")
if [[ -n "$ONLY" ]]; then
  selected=(${(s:,:)ONLY})
  for s in "${selected[@]}"; do
    (( ${SECTIONS[(Ie)$s]} )) || { print -u2 "Unknown section '$s'. Sections: ${SECTIONS[*]}"; exit 2; }
  done
fi

# ---------------------------------------------------------------------------
# Output and checks
# ---------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/tests/tmp"
LOG="${REPO_ROOT}/tests/tmp/mac-e2e-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

PASS=0 FAIL=0 SKIP=0
local -a FAILED=()
OUT="" RC=0 LAST=""
_say()    { print -P "%F{cyan}[e2e]%f $*"; }
section() { print -P "\n%B── $1 ──%b"; }
pass()    { PASS=$(( PASS + 1 )); print -P "%F{green}  ✓ PASS%f $1"; }
skip()    { SKIP=$(( SKIP + 1 )); print -P "%F{yellow}  - SKIP%f $1 ($2)"; }
fail() {
  FAIL=$(( FAIL + 1 )); FAILED+=("$1")
  print -P "%F{red}  ✗ FAIL%f $1"
  [[ -n "${2:-}" ]] && print -r -- "       $2"
  print -r -- "       last command: ${LAST}  (exit ${RC})"
  print -r -- "       ----- output (last 25 lines) -----"
  print -r -- "${OUT}" | tail -n 25 | sed 's/^/       /'
  print -r -- "       ----------------------------------"
}
check()      { if eval "$2"; then pass "$1"; else fail "$1" "condition: $2"; fi; }
expect_rc()  { [[ "$RC" == "$2" ]] && pass "$1" || fail "$1" "expected exit ${2}"; }
expect_nonzero() { (( RC != 0 )) && pass "$1" || fail "$1" "expected a non-zero exit"; }
expect_in()  { [[ "$OUT" == *"$2"* ]] && pass "$1" || fail "$1" "expected output to contain: $2"; }
expect_not_in() { [[ "$OUT" != *"$2"* ]] && pass "$1" || fail "$1" "expected output NOT to contain: $2"; }

CWD="$PWD"
# as <args…> : run agent-shadow in $CWD (stdin /dev/null), capture OUT and RC
as() {
  LAST="(cd ${CWD:t} && agent-shadow $*)"
  RC=0; OUT="$(cd "$CWD" && "$BIN" "$@" 2>&1 </dev/null)" || RC=$?
}
# sh_ <cmd…> : run a host command, capture OUT and RC
sh_() { LAST="$*"; RC=0; OUT="$("$@" 2>&1)" || RC=$?; }
need() { (( RC == 0 )) || { fail "$1" "setup step failed; stopping"; exit 1; }; pass "$1"; }

# Apple container 1.x tables: first column, header skipped (no Go-template --format)
names() { command container "$@" 2>/dev/null | awk 'NR == 1 && $1 ~ /^[A-Z]+$/ { next } NF { print $1 }'; }
# (never end a pipeline with grep -q under pipefail: grep exits early, awk gets SIGPIPE)
running() { names ls | grep -xF -- "$1" >/dev/null; }
exists_container() { names ls -a | grep -xF -- "$1" >/dev/null; }
exists_volume()  { names volume ls | grep -xF -- "$1" >/dev/null; }
exists_network() { names network ls | grep -xF -- "$1" >/dev/null; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
print -P "\n%B%F{blue}  agent-shadow end-to-end tests on this Mac%f%b"
[[ "$(uname -s)" == Darwin ]] || { print "This suite needs macOS with Apple 'container'. Use 'make test' elsewhere."; exit 2; }
command -v container >/dev/null || { print "Apple 'container' CLI not found (brew install container)."; exit 2; }
command container system status >/dev/null 2>&1 || command container system start || { print "container system did not start."; exit 2; }
others="$(names ls | grep -E '^(agent-|shadow-proxy-)' || true)"
if [[ -n "$others" ]]; then
  print "These agent-shadow containers are running:"; print -r -- "$others"
  print "Stop them first (agent-shadow stop --all): 'tools' refuses while any agent container runs."
  exit 2
fi
_say "macOS $(sw_vers -productVersion), $(command container --version 2>/dev/null)"
_say "log: ${LOG}"

E2E_ID="$(printf '%04x%04x' $RANDOM $RANDOM)"
PFX="e2e${E2E_ID}"
ROOT="${${TMPDIR:-/tmp}%/}/agent-shadow-${PFX}"
mkdir -p "$ROOT"; ROOT="${ROOT:A}"
export XDG_CONFIG_HOME="${ROOT}/config"
export AGENT_SHADOW_MISE_VOLUME="${E2E_MISE_VOLUME:-shadow-e2e-mise}"
export AGENT_SHADOW_IMAGE_PREFIX=shadow-e2e
BASE_IMG="shadow-e2e-base:ubuntu24" PROXY_IMG="shadow-e2e-proxy:latest"
export AGENT_SHADOW_APPROVE=deny
export EGRESS_POLL_SECONDS=1
REG="${XDG_CONFIG_HOME}/agent-shadow/workspaces"
_say "id ${PFX}, temp ${ROOT}, toolchain volume ${AGENT_SHADOW_MISE_VOLUME}"

cleanup() {
  print -P "\n%B── cleanup ──%b"
  if (( KEEP )); then _say "--keep: resources named *${PFX}* and ${ROOT} were left in place"; return; fi
  local c v n
  for c in ${(f)"$(names ls -a | grep -F -- "$PFX")"}; do
    command container stop "$c" >/dev/null 2>&1; command container rm -f "$c" >/dev/null 2>&1
  done
  for v in ${(f)"$(names volume ls | grep -F -- "$PFX")"}; do command container volume rm "$v" >/dev/null 2>&1; done
  for n in ${(f)"$(names network ls | grep -F -- "$PFX")"}; do command container network rm "$n" >/dev/null 2>&1; done
  [[ -n "${E2E_CLEAN_MISE:-}" ]] && command container volume rm "$AGENT_SHADOW_MISE_VOLUME" >/dev/null 2>&1
  [[ -n "${E2E_CLEAN_IMAGES:-}" ]] && command container image rm "$BASE_IMG" "$PROXY_IMG" >/dev/null 2>&1
  rm -rf "$ROOT"
  local left="$( { names ls -a; names volume ls; names network ls; } | grep -F -- "$PFX" || true)"
  [[ -z "$left" ]] && _say "removed everything named *${PFX}*" || _say "could not remove: ${left//$'\n'/ }"
}
summary() {
  cleanup
  print -P "\n%B  Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped%b"
  (( FAIL )) && print -l "  Failed:" "${FAILED[@]/#/    - }"
  print "  Log: ${LOG}"
}
trap summary EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# Setup (always): images, two workspaces, node in the test toolchain volume
# ---------------------------------------------------------------------------
section "setup"
W1="${ROOT}/${PFX}-shared"; W2="${ROOT}/${PFX}-iso"
mkdir -p "$W1" "$W2"
git -C "$W1" init -q
print 'E2E_FILEVAR=fromfile' '# a comment' > "${ROOT}/e2e.env"
CWD="$ROOT"
_say "agent-shadow init (builds ${BASE_IMG} and ${PROXY_IMG} if missing or outdated; the first build takes several minutes)"
as init;                     need "init: images, toolchain volume and shadow-net ready"
if [[ "$OUT" == *"older template"* ]]; then
  _say "the test images are older than this checkout's template: rebuilding them"
  as init --force;           need "init --force: test images rebuilt from the current template"
fi
as register "$W1";           need "register shared workspace"
as register --isolated "$W2"; need "register isolated workspace"
S1="$(grep -F "|${W1}|" "$REG" | cut -d'|' -f1)"; S2="$(grep -F "|${W2}|" "$REG" | cut -d'|' -f1)"
_say "slugs: ${S1} (shared), ${S2} (isolated)"
as tools use -g node@22;     need "tools use -g node@22 (into ${AGENT_SHADOW_MISE_VOLUME})"

stop_all_test() { local d; for d in "$W1" "$W2"; do (cd "$d" && "$BIN" stop >/dev/null 2>&1 </dev/null) || true; done; }

# ---------------------------------------------------------------------------
sec_tools() {
  section "tools: installed toolchains reach every kind of session"
  CWD="$ROOT"; as tools ls
  expect_in "tools ls lists node" "node"
  CWD="$W1"; as run bash -c 'node --version'
  expect_in "node from the toolchain volume runs in 'run'" "v22."
  as start; need "start background container"
  CWD="$ROOT"; as tools ls
  expect_nonzero "tools refuses while an agent container runs (store would be written while mounted)"
  expect_in "tools says why it refused" "Running agent containers detected"
  stop_all_test
}

# ---------------------------------------------------------------------------
sec_run() {
  section "run: mounts, toolchains, state, environment"
  CWD="$W1"
  as run bash -c 'node -e "console.log(6*7)"'
  expect_in "node executes code in the sandbox" "42"
  print HOSTDATA > "${W1}/host.txt"
  as run bash -c 'cat /workspace/host.txt; echo FROM-CONTAINER > /workspace/from-container.txt'
  expect_in "project folder is visible at /workspace" "HOSTDATA"
  check "the project is mounted read-write (the agent's edits reach the Mac)" '[[ "$(cat "${W1}/from-container.txt" 2>/dev/null)" == FROM-CONTAINER ]]'
  mkdir -p "${W1}/sub/dir"; CWD="${W1}/sub/dir"
  as run bash -c 'pwd'
  expect_in "a subfolder of the project maps to the same subfolder in /workspace" "/workspace/sub/dir"
  CWD="$W1"
  as run bash -c 'touch /opt/mise/.e2e-probe 2>/dev/null && echo MISE=writable || echo MISE=readonly'
  expect_in "/opt/mise (shared toolchains) is read-only in a session" "MISE=readonly"
  as run bash -c 'mise install python@3.12'
  expect_nonzero "mise install inside a session fails"
  expect_in "mise install inside a session explains to use 'agent-shadow tools'" "agent-shadow notice"
  as run bash -c "echo TOKEN-${PFX} > /root/.e2e-token"
  as run bash -c 'cat /root/.e2e-token'
  expect_in "/root survives between sessions (per-workspace volume)" "TOKEN-${PFX}"
  export E2E_HOSTVAR=fromhost
  as run --env A=1 --env E2E_HOSTVAR --env-file "${ROOT}/e2e.env" bash -c 'echo "A=$A H=$E2E_HOSTVAR F=$E2E_FILEVAR"'
  expect_in "--env KEY=VAL, --env KEY (from the Mac) and --env-file arrive" "A=1 H=fromhost F=fromfile"
  as run bash -c 'exit 7'
  expect_rc "the session's exit code is returned" 7
  as run bash -c 'echo "#!/bin/sh" > /workspace/.git/hooks/pre-commit'
  expect_in "a git hook written by the session is reported" "added     .git/hooks/pre-commit"
  rm -f "${W1}/.git/hooks/pre-commit"
}

# ---------------------------------------------------------------------------
sec_lifecycle() {
  section "start / connect / run (attach) / stop"
  CWD="$W1"
  local port=$(( 20000 + RANDOM % 20000 ))
  # Ask for every interface explicitly: agent-shadow must still bind 127.0.0.1. (Plain -p H:C
  # binds loopback by Apple's own default, which would not test our rewrite.)
  as start -p "0.0.0.0:${port}:${port}"; need "start -p 0.0.0.0:${port}:${port}"
  check "background container is running" 'running "agent-${S1}"'

  LAST="print commands | agent-shadow connect"
  RC=0; OUT="$(print -l 'node --version' 'exit' | (cd "$W1" && "$BIN" connect 2>&1))" || RC=$?
  expect_in "node is available in a connect shell" "v22."

  as run --env-file "${ROOT}/e2e.env" bash -c 'echo "F=$E2E_FILEVAR"; node --version'
  expect_in "run attaches to the running container" "attaching to agent-${S1}"
  expect_in "--env-file reaches a session that attaches to a running container" "F=fromfile"
  expect_in "node is available when attaching" "v22."

  # Published port: one-connection HTTP server in the container, probed from the Mac
  cat > "${W1}/e2e-server.pl" <<'PERL'
use IO::Socket::INET;
my $s = IO::Socket::INET->new(LocalPort => $ARGV[0], Listen => 5, ReuseAddr => 1) or die "listen: $!";
for (1..3) { my $c = $s->accept or next; <$c>; print $c "HTTP/1.0 200 OK\r\nContent-Length: 9\r\n\r\nE2E-HELLO"; close $c; }
PERL
  (cd "$W1" && "$BIN" run bash -c "timeout 30 perl /workspace/e2e-server.pl ${port}" >/dev/null 2>&1 </dev/null) &
  local srv=$! body="" i
  for i in {1..20}; do body="$(curl -s -m 2 "http://127.0.0.1:${port}/" 2>/dev/null)"; [[ "$body" == E2E-HELLO ]] && break; sleep 1; done
  LAST="curl http://127.0.0.1:${port}/"; OUT="$body"; RC=0
  check "published port answers on the Mac's 127.0.0.1" '[[ "$body" == E2E-HELLO ]]'
  local lan="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  if [[ -n "$lan" ]]; then
    body="$(curl -s -m 3 "http://${lan}:${port}/" 2>/dev/null)"
    LAST="curl http://${lan}:${port}/"; OUT="$body"
    check "-p 0.0.0.0:… is still bound to 127.0.0.1 only (not reachable on ${lan})" '[[ "$body" != E2E-HELLO ]]'
  else
    skip "published port is not reachable on the Mac's network address" "no address on en0/en1"
  fi
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null

  # Change made during the start→stop lifetime, outside any agent-shadow session
  command container exec "agent-${S1}" sh -c 'echo x > /workspace/.envrc'
  as stop
  expect_in "stop reports files changed since start" "added     .envrc"
  check "stop removes the background container" '! exists_container "agent-${S1}"'
  rm -f "${W1}/.envrc" "${W1}/e2e-server.pl"
}

# ---------------------------------------------------------------------------
sec_network() {
  section "network: a running container is reused only on the requested network"
  CWD="$W1"
  as start; need "start on shadow-net"
  as run --isolated bash -c 'echo SHOULD-NOT-RUN'
  expect_rc "run --isolated refuses to attach to a shadow-net container" 1
  expect_in "the refusal names the network mismatch" "different network than requested"
  expect_not_in "the refused command did not run" "SHOULD-NOT-RUN"
  check "the refused run started no egress proxy" '! running "shadow-proxy-${S1}"'
  as connect --isolated
  expect_rc "connect --isolated refuses too" 1
  stop_all_test

  as start --isolated; need "start --isolated (creates shadow-${S1}-net and a proxy)"
  as run bash -c 'echo SHOULD-NOT-RUN'
  expect_rc "plain run refuses to attach to an isolated container" 1
  expect_not_in "the refused command did not run" "SHOULD-NOT-RUN"
  as run --isolated bash -c 'echo ATTACHED-ISO'
  expect_in "run --isolated attaches to the isolated container" "ATTACHED-ISO"
  as stop
  check "stop also stops the workspace's egress proxy" '! running "shadow-proxy-${S1}"'
}

# ---------------------------------------------------------------------------
sec_egress() {
  section "egress: --isolated workspace, real proxy"
  CWD="$W2"
  cat > "${W2}/probe.sh" <<'SH'
curl -sS -m 8 --noproxy '*' -o /dev/null https://example.com 2>/dev/null && echo DIRECT_HTTPS=open || echo DIRECT_HTTPS=blocked
echo "ALLOWED=$(curl -s -m 20 -o /dev/null -w '%{http_code}' https://registry.npmjs.org/)"
curl -s -m 20 -o /dev/null https://example.com; echo "DENIED_RC=$?"
SH
  as run bash /workspace/probe.sh
  expect_in "--isolated network has no direct internet (HTTPS bypassing the proxy fails)" "DIRECT_HTTPS=blocked"
  expect_in "an allowlisted registry works through the proxy" "ALLOWED=200"
  expect_not_in "a host not on the allowlist is refused by the proxy" "DENIED_RC=0"
  check "the refused host is reported at the end of the session" \
    '[[ "$OUT" == *"denied this session"*example.com* || "$OUT" == *"before it could be asked: "*example.com* ]]'
  check "the proxy is stopped when the session ends" '! running "shadow-proxy-${S2}"'

  as egress allow example.com
  as run bash -c 'echo "CODE=$(curl -s -m 20 -o /dev/null -w "%{http_code}" https://example.com/)"'
  expect_in "after 'egress allow', the host works through the proxy" "CODE=200"

  # Approval during a session (the watcher reads the real tinyproxy log)
  AGENT_SHADOW_APPROVE=allow as run bash -c '
    echo "FIRST=$(curl -s -m 20 -o /dev/null -w "%{http_code}" https://example.net/)"; sleep 8
    echo "SECOND=$(curl -s -m 20 -o /dev/null -w "%{http_code}" https://example.net/)"'
  expect_not_in "before approval the host is refused" "FIRST=200"
  expect_in "approved during the session, the retry works without a restart" "SECOND=200"
  check "the approval is stored for this workspace only" \
    'grep -qx example.net "${XDG_CONFIG_HOME}/agent-shadow/egress/${S2}/approved" && ! grep -qsx example.net "${XDG_CONFIG_HOME}/agent-shadow/egress/${S1}/approved"'

  rm -f "${W2}/probe.sh"
}

# ---------------------------------------------------------------------------
sec_wash() {
  section "wash: resets /root, keeps the project"
  CWD="$W1"
  print keep > "${W1}/e2e-keep.txt"
  as run bash -c "echo WASH-${PFX} > /root/.e2e-wash"
  as wash --force; need "wash --force"
  as run bash -c 'cat /root/.e2e-wash 2>/dev/null || echo GONE'
  expect_in "state in /root is gone after wash" "GONE"
  check "project files are untouched by wash" '[[ -f "${W1}/e2e-keep.txt" ]]'
  rm -f "${W1}/e2e-keep.txt"
}

# ---------------------------------------------------------------------------
sec_registry() {
  section "registry: two folders with the same name stay separate"
  local d1="${ROOT}/a/${PFX}-dup" d2="${ROOT}/b/${PFX}-dup"
  mkdir -p "$d1" "$d2"
  CWD="$ROOT"; as register "$d1"; as register "$d2"
  local s1="$(grep -F "|${d1}|" "$REG" | cut -d'|' -f1)" s2="$(grep -F "|${d2}|" "$REG" | cut -d'|' -f1)"
  check "both folders are registered" '[[ -n "$s1" && -n "$s2" ]]'
  check "they get different slugs (${s1:-?} / ${s2:-?})" '[[ "$s1" != "$s2" ]]'
  CWD="$d1"; as run bash -c 'echo ONE > /root/who'
  CWD="$d2"; as run bash -c 'echo TWO > /root/who'
  CWD="$d1"; as run bash -c 'cat /root/who'
  expect_in "the first folder keeps its own /root" "ONE"
  CWD="$d2"; as run bash -c 'cat /root/who'
  expect_in "the second folder has its own /root" "TWO"
  CWD="$ROOT"; as unregister "$d1"
  check "unregister by path removes only that folder" '! grep -qF "|${d1}|" "$REG" && grep -qF "|${d2}|" "$REG"'
  CWD="$d1"; as run bash -c true
  expect_rc "run in an unregistered folder fails" 1
}

# ---------------------------------------------------------------------------
sec_traffic() {
  section "traffic: what the containers connected to"
  CWD="$W1"
  print '*.example.org' > "${XDG_CONFIG_HOME}/agent-shadow/allowlist"
  local gw; gw="$(command container network inspect shadow-net 2>/dev/null | grep -m1 '"ipv4Gateway"' | cut -d'"' -f4)"
  as traffic --clear
  as run bash -c "sleep 3; curl -s -m 8 -o /dev/null https://example.com; curl -s -m 8 -o /dev/null https://example.org; curl -s -m 3 -o /dev/null http://${gw}:9/; sleep 3"
  # First: was anything recorded? Otherwise the "not listed" checks below would pass on an empty log.
  as traffic --all
  expect_in "the monitor recorded the session's connections (example.com)" "example.com"
  expect_in "…and the allowlisted one too (example.org, shown by --all)" "example.org"
  as traffic
  expect_in "a host not on the allowlist is listed" "example.com"
  if [[ "$OUT" == *example.com* ]]; then
    expect_not_in "'*.example.org' on the allowlist covers example.org itself, as in the proxy" "example.org"
  else
    fail "'*.example.org' on the allowlist covers example.org itself, as in the proxy" "nothing was recorded, so this can't be judged"
  fi
  if [[ -n "$gw" ]]; then
    expect_in "a connection to the Mac (gateway ${gw}) is listed and labelled" "${gw}:9  (your Mac)"
  else
    skip "a connection to the Mac is listed" "no gateway in 'container network inspect shadow-net'"
  fi
  as traffic --clear
  as traffic
  expect_in "--clear empties the record" "No external network calls recorded"
  rm -f "${XDG_CONFIG_HOME}/agent-shadow/allowlist"
}

# ---------------------------------------------------------------------------
sec_doctor() {
  section "doctor, and the outdated-image warning"
  CWD="$ROOT"
  as doctor
  expect_in "doctor finds the image" "Image '${BASE_IMG}' exists"
  expect_not_in "doctor: the image is from the current template" "older template"
  local gone="${ROOT}/${PFX}-gone"; mkdir -p "$gone"
  as register "$gone"; rm -rf "$gone"
  as doctor
  expect_in "doctor reports a registered folder that no longer exists" "directory no longer exists"
  as unregister "$gone"
  local append="${XDG_CONFIG_HOME}/agent-shadow/Dockerfile.ubuntu24.append"
  print 'RUN true' > "$append"
  as doctor
  expect_in "doctor reports an image built from an older template (here: the .append file changed)" "built from an older template"
  CWD="$W1"; as run bash -c 'echo STILL-RUNS'
  expect_in "run warns about the outdated image" "built from an older template"
  expect_in "…and still runs with it (warn only, nothing rebuilt)" "STILL-RUNS"
  rm -f "$append"
}

# ---------------------------------------------------------------------------
sec_stopall() {
  section "stop --all: only agent-shadow's containers"
  CWD="$W1"; as start; need "start a workspace container"
  local foreign="agent-${PFX}frgn"
  sh_ command container run -d --name "$foreign" "$BASE_IMG" sleep 600
  need "start an unrelated container named ${foreign}"
  CWD="$ROOT"; as stop --all
  check "stop --all stopped the workspace container" '! running "agent-${S1}"'
  check "stop --all left the unrelated agent-* container running" 'running "$foreign"'
  command container stop "$foreign" >/dev/null 2>&1; command container rm -f "$foreign" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
sec_uninstall() {
  section "install and uninstall (into a temp prefix; images kept)"
  local P="${ROOT}/prefix" shim="${ROOT}/shim"
  mkdir -p "$P" "$shim"
  ln -sf "$(command -v container)" "${shim}/container"   # PATH without Homebrew: no brew completion dir
  local -a ienv=(env PATH="${shim}:/usr/bin:/bin:/usr/sbin:/sbin" XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
                 XDG_DATA_HOME="${P}/data" XDG_BIN_HOME="${P}/bin")
  sh_ "${ienv[@]}" zsh "${REPO_ROOT}/install.sh"
  need "./install.sh into ${P}"
  sh_ "${P}/bin/agent-shadow" version
  check "the installed command runs and reports this version" '[[ "$OUT" == "$("$BIN" version)" ]]'

  CWD="$W1"; as start; need "start a workspace container (uninstall must remove it)"
  local fv="home-${PFX}frgn" fn="shadow-${PFX}frgn" fc="agent-${PFX}frgn"
  command container volume create "$fv" >/dev/null 2>&1
  command container network create "$fn" >/dev/null 2>&1
  command container run -d --name "$fc" "$BASE_IMG" sleep 600 >/dev/null 2>&1
  check "unrelated volume/network/container with agent-shadow-like names exist" \
    'exists_volume "$fv" && exists_network "$fn" && running "$fc"'

  sh_ "${ienv[@]}" AGENT_SHADOW_IMAGE_PREFIX=shadow-e2e AGENT_SHADOW_MISE_VOLUME="$AGENT_SHADOW_MISE_VOLUME" \
    "${P}/bin/agent-shadow" uninstall --yes
  expect_rc "agent-shadow uninstall --yes succeeds" 0
  check "workspace container removed" '! exists_container "agent-${S1}"'
  check "workspace /root volumes removed" '! exists_volume "home-${S1}" && ! exists_volume "home-${S2}"'
  check "isolated workspace network removed" '! exists_network "shadow-${S2}-net"'
  check "unrelated home-* volume kept" 'exists_volume "$fv"'
  check "unrelated shadow-* network kept" 'exists_network "$fn"'
  check "unrelated agent-* container kept" 'running "$fc"'
  sh_ command container image ls
  check "images kept" '[[ "$OUT" == *shadow-e2e-base* && "$OUT" == *shadow-e2e-proxy* ]]'
  check "toolchain volume and shadow-net kept" 'exists_volume "$AGENT_SHADOW_MISE_VOLUME" && exists_network shadow-net'
  check "CLI, completion and config removed" \
    '[[ ! -e "${P}/data/agent-shadow" && ! -e "${P}/bin/agent-shadow" && ! -e "${XDG_CONFIG_HOME}/agent-shadow" ]]'
}

for s in "${SECTIONS[@]}"; do
  (( ${selected[(Ie)$s]} )) || continue
  "sec_${s}"
  stop_all_test
done
(( FAIL == 0 ))
