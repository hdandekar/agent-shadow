#!/bin/zsh
# unit_test.zsh — host-only tests: no containers, no network, safe anywhere (macOS or Linux).
#
# Everything here runs agent-shadow's real code against real files, real git and real
# hashing. Nothing in this file imitates Apple `container`: behaviour that depends on
# containers is tested on a Mac by tests/mac_e2e_test.zsh. Only `curl` is replaced, in the
# release tests, because no tagged release exists to download.
#
# tests/mutants.zsh breaks the code on purpose and checks that these tests then fail.

set -euo pipefail

SCRIPT_DIR="${${(%):-%x}:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
BIN="${REPO_ROOT}/bin/agent-shadow"
LIB="${REPO_ROOT}/lib/agent-shadow"

TEST_COUNT=0 PASS_COUNT=0 FAIL_COUNT=0

T="${$(mktemp -d "${TMPDIR:-/tmp}/agent-shadow-unit.XXXXXX"):A}"
trap 'rm -rf "$T"' EXIT
export XDG_CONFIG_HOME="${T}/config"
mkdir -p "$XDG_CONFIG_HOME"

# SAFETY: an inert `container` first on PATH (accepts everything, lists nothing). register,
# unregister and egress call `container`; this makes sure nothing here reaches the real CLI.
SAFE_BIN="${T}/safe-bin"
mkdir -p "$SAFE_BIN"
printf '#!/bin/sh\necho "$*" >> "%s/calls.log"\nexit 0\n' "$SAFE_BIN" > "${SAFE_BIN}/container"
chmod +x "${SAFE_BIN}/container"
export PATH="${SAFE_BIN}:${PATH}"

_pass() { TEST_COUNT=$(( TEST_COUNT + 1 )); PASS_COUNT=$(( PASS_COUNT + 1 )); print -P "%F{green}  ✓ [PASS]%f $1"; }
_fail() { TEST_COUNT=$(( TEST_COUNT + 1 )); FAIL_COUNT=$(( FAIL_COUNT + 1 )); print -P "%F{red}  ✗ [FAIL]%f $1"; }
assert_equal() {
  if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1"; print -r -- "     Expected: '$2'"; print -r -- "     Actual  : '$3'"; fi
}
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then _pass "$1"; else _fail "$1"; print -r -- "     Missing : '$2'"; print -r -- "     In      : '${3[1,400]}'"; fi
}
assert_not_contains() {
  if [[ "$3" != *"$2"* ]]; then _pass "$1"; else _fail "$1"; print -r -- "     Unexpected: '$2'"; fi
}
section() { print -P "\n%B[$1]%b"; }
# rc_of <cmd...> : prints the command's exit code (output discarded)
rc_of() { "$@" >/dev/null 2>&1 && print 0 || print $?; }
sha() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

print -P "\n%B%F{blue}  agent-shadow host-only unit tests%f%b"

section "Safety"
assert_equal "tests use the inert container stub, not the real CLI" "${SAFE_BIN}/container" "$(command -v container)"


section "Version and installer"
# ---------------------------------------------------------------------------
# A release needs the code and the Homebrew formula to agree.
v_code="$(zsh -c 'source "$1/helpers.zsh"; print -r -- "$AGENT_SHADOW_VERSION"' x "$LIB")"
v_url="$(sed -n 's|.*archive/refs/tags/v\([0-9.]*\)\.tar\.gz.*|\1|p' "${REPO_ROOT}/Formula/agent-shadow.rb")"
v_ftest="$(sed -n 's/.*"agent-shadow \([0-9.]*\)".*/\1/p' "${REPO_ROOT}/Formula/agent-shadow.rb")"
assert_equal "version agrees: helpers.zsh, Formula url, Formula test" "${v_code} ${v_code} ${v_code}" "${v_code} ${v_url} ${v_ftest}"

STUB="${T}/stub-bin"; mkdir -p "$STUB"
printf '#!/bin/sh\n[ "$1" = -s ] && { echo Darwin; exit 0; }\nexec /usr/bin/uname "$@"\n' > "${STUB}/uname"
chmod +x "${STUB}/uname"
CO="${T}/checkout"; mkdir -p "$CO"
cp -R "${REPO_ROOT}/bin" "${REPO_ROOT}/lib" "${REPO_ROOT}/completions" "${REPO_ROOT}/install.sh" "$CO/"
LD="${T}/local"; mkdir -p "$LD"
local_install() {
  (cd "$LD" && PATH="${STUB}:${PATH}" HOME="${LD}/home" XDG_CONFIG_HOME="${LD}/config" \
    XDG_DATA_HOME="${LD}/data" XDG_BIN_HOME="${LD}/bin" zsh "${CO}/install.sh" 2>&1)
}
out="$(local_install)" && rc=0 || rc=$?
assert_equal "./install.sh installs from the checkout" "0" "$rc"
assert_equal "the installed command runs" "agent-shadow ${v_code}" "$("${LD}/bin/agent-shadow" version 2>&1)"
assert_equal "the image files are installed with it" "present" \
  "$([[ -f "${LD}/data/agent-shadow/lib/agent-shadow/image/Containerfile" ]] && print present || print absent)"
print '# left by an older version' > "${LD}/data/agent-shadow/lib/agent-shadow/removed_in_new_version.zsh"
local_install >/dev/null 2>&1 || true
assert_equal "reinstall removes library files the new version no longer has" "absent" \
  "$([[ -e "${LD}/data/agent-shadow/lib/agent-shadow/removed_in_new_version.zsh" ]] && print present || print absent)"
# Piped (curl … | zsh) from inside a checkout: must not install whatever is in the current folder
mkdir -p "${T}/piped/cwd"; cp -R "$CO"/* "${T}/piped/cwd/"
out="$(cd "${T}/piped/cwd" && PATH="${STUB}:${PATH}" HOME="${T}/piped/home" XDG_DATA_HOME="${T}/piped/data" \
  XDG_BIN_HOME="${T}/piped/bin" zsh -s < "${CO}/install.sh" 2>&1)" && rc=0 || rc=$?
assert_equal "piped install refuses (no file, so no checkout to trust)" "1" "$rc"
assert_contains "piped install points to Homebrew" "brew install agent-shadow" "$out"
assert_equal "piped install installed nothing" "absent" "$([[ -e "${T}/piped/data/agent-shadow" ]] && print present || print absent)"

# ---------------------------------------------------------------------------
section "Help and completion list every command"
# ---------------------------------------------------------------------------
cmds=(${(f)"$(sed -n 's/^    \([a-z][a-z-]*\)[|)].*/\1/p' "$BIN" | grep -vx 'version\|help')"})
help_text="$("$BIN" help 2>&1)"
# only the top-level command list (_agent_shadow_commands), not e.g. the tools subcommands
comp_text="$(awk '/^_agent_shadow_commands\(\)/ { on = 1 } on { print } on && /^}/ { exit }' "${REPO_ROOT}/completions/_agent-shadow")"
missing_help=() missing_comp=()
for c in "${cmds[@]}"; do
  [[ "$help_text" == *$'\n'"  ${c} "* ]] || missing_help+=("$c")
  [[ "$comp_text" == *"'${c}:"* ]] || missing_comp+=("$c")
done
assert_equal "dispatcher commands found (sanity)" "yes" "$( (( ${#cmds} >= 12 )) && print yes || print no )"
assert_equal "every command is in 'agent-shadow help'" "" "${missing_help[*]}"
assert_equal "every command is in the zsh completion" "" "${missing_comp[*]}"

# ---------------------------------------------------------------------------
section "Workspace registry"
# ---------------------------------------------------------------------------
reg() { "$BIN" register "$@" 2>&1; }
assert_equal "register refuses /" "1" "$(rc_of "$BIN" register /)"
assert_equal "register refuses \$HOME" "1" "$(rc_of "$BIN" register "$HOME")"
mkdir -p "${T}/x/myapp" "${T}/y/myapp" "${T}/z/My App!"
reg "${T}/x/myapp" >/dev/null
reg "${T}/y/myapp" >/dev/null
regfile="${XDG_CONFIG_HOME}/agent-shadow/workspaces"
assert_equal "two folders with the same name both stay registered" "2" "$(grep -c '|.*/myapp|' "$regfile")"
assert_equal "two folders with the same name get different slugs" "2" "$(cut -d'|' -f1 "$regfile" | grep '^myapp' | sort -u | wc -l | tr -d ' ')"
slug_y="$(grep "|${T:A}/y/myapp|" "$regfile" | cut -d'|' -f1)"
reg "${T}/y/myapp" >/dev/null
assert_equal "re-registering a folder keeps its slug" "$slug_y" "$(grep "|${T:A}/y/myapp|" "$regfile" | cut -d'|' -f1)"
assert_equal "slug of a folder name with spaces and punctuation" "my-app" "$(reg "${T}/z/My App!" | sed -n 's/.*Slug  : //p')"
"$BIN" unregister "${T}/x/myapp" >/dev/null 2>&1
assert_equal "unregister by path removes only that folder" "${T:A}/y/myapp" "$(grep '/myapp|' "$regfile" | cut -d'|' -f2)"
"$BIN" unregister "$slug_y" >/dev/null 2>&1
assert_equal "unregister by slug removes it" "0" "$(grep -c '/myapp|' "$regfile")"
assert_equal "unregister of an unknown folder fails" "1" "$(rc_of "$BIN" unregister "${T}/x/myapp")"
out="$("$BIN" register --isolated --network custom "${T}/z/My App!" 2>&1)" && rc=0 || rc=$?
assert_equal "--isolated and --network together are refused" "1" "$rc"
out="$(cd "${T}/z/My App!" && "$BIN" run agy@latest 2>&1)" && rc=0 || rc=$?
assert_equal "run with a tool version (agy@latest) is refused" "1" "$rc"
assert_contains "…and says to run the program by name" "Run it:     agent-shadow run agy" "$out"
assert_contains "…and where versions are chosen" "agent-shadow tools use -g agy@latest" "$out"
# Which workspace a running container belongs to (list's RUNNING column, stop --all, uninstall)
mkdir -p "${T}/owners/agent-shadow"
print -l 'shadow|/p/shadow|ubuntu24|' 'wheres-shadow|/p/wheres-shadow|ubuntu24|' > "${T}/owners/agent-shadow/workspaces"
owner() { XDG_CONFIG_HOME="${T}/owners" zsh -c 'set -euo pipefail; source "$1/helpers.zsh"; _container_owner "$2" && print "$REPLY_SLUG $REPLY_ROLE" || print none' x "$LIB" "$1" 2>&1; }
assert_equal "a run session belongs to the workspace with the longest matching name" "wheres-shadow bash" "$(owner agent-bash-wheres-shadow)"
assert_equal "a background (start) container is recognised" "wheres-shadow background" "$(owner agent-wheres-shadow)"
assert_equal "a program name with dashes stays whole" "shadow script-sh" "$(owner agent-script-sh-shadow)"
assert_equal "an egress proxy is recognised" "shadow proxy" "$(owner shadow-proxy-shadow)"
assert_equal "another tool's agent-* container belongs to no workspace" "none" "$(owner agent-other)"

# ---------------------------------------------------------------------------
section "rm guardrail (the image's /usr/local/bin/rm, run on the host)"
# ---------------------------------------------------------------------------
RMW="${T}/rmw"; mkdir -p "$RMW"
# The real script, with its final `exec /bin/rm` replaced by an echo so nothing is deleted here
sed 's|^exec /bin/rm "\$@"$|echo "WOULD-RM $*"|' "${LIB}/image/rm-guard.sh" > "${RMW}/rm"
rmw() { local o; o="$(HOME=/root sh "${RMW}/rm" "$@" 2>&1)" || true; [[ "$o" == *WOULD-RM* ]] && print allowed || { [[ "$o" == *Blocked* ]] && print blocked || print "error"; }; }
assert_equal "test copy ends in an echo instead of rm" "1" "$(grep -c 'WOULD-RM' "${RMW}/rm" 2>/dev/null || print 0)"
assert_equal "allows temp and project subfolders" "allowed allowed allowed allowed" \
  "$(rmw -rf /tmp/tmp.abc) $(rmw -rf /root/.local/bin/tmp.abc) $(rmw -rf /workspace/node_modules) $(rmw -r build)"
assert_equal "blocks /, /root, /workspace" "blocked blocked blocked" "$(rmw -rf /) $(rmw -rf /root) $(rmw -rf /workspace)"
assert_equal "blocks trailing-slash and /. variants" "blocked blocked blocked" "$(rmw -rf /root/) $(rmw -rf /root/.) $(rmw -rf /workspace//)"
assert_equal "blocks literal unexpanded globs" "blocked blocked" "$(rmw -rf '/*') $(rmw -rf '/root/*')"
assert_equal "blocks combined flags (-Rf, -fr, --recursive)" "blocked blocked blocked" "$(rmw -Rf /workspace) $(rmw -fr /root) $(rmw --recursive /)"
assert_equal "non-recursive rm is untouched" "allowed" "$(rmw /root/file.txt)"

# ---------------------------------------------------------------------------
section "Workspace → host change detection"
# ---------------------------------------------------------------------------
W="${T}/integ"; mkdir -p "${W}/.git/hooks" "${W}/.vscode"
print '{"scripts":{}}' > "${W}/package.json"; print sample > "${W}/.git/hooks/pre-commit.sample"; print '{}' > "${W}/.vscode/tasks.json"
integ_run() {   # integ_run <cmd…> : _integrity_run around a command in $W; prints output + rc=N
  zsh -c 'set -euo pipefail; source "$1/helpers.zsh"; source "$1/integrity.zsh"; root="$2"; shift 2; cd "$root"
          rc=0; _integrity_run "$root" "$@" || rc=$?; print "rc=${rc}"' x "$LIB" "$W" "$@" 2>&1
}
assert_equal "no warning when nothing changed" "rc=0" "$(integ_run true)"
assert_contains "detects an added git hook" "added     .git/hooks/pre-commit" "$(integ_run sh -c 'echo evil > .git/hooks/pre-commit')"
assert_contains "detects a modified package.json" "modified  package.json" "$(integ_run sh -c 'echo "{}" > package.json')"
assert_contains "detects a removed hook" "removed   .git/hooks/pre-commit.sample" "$(integ_run rm .git/hooks/pre-commit.sample)"
assert_contains "detects .git/config (hooksPath, fsmonitor live there)" "added     .git/config" "$(integ_run sh -c 'printf "[core]\n\tfsmonitor = ./x\n" > .git/config')"
assert_contains "detects .gitattributes (selects filters/diff drivers)" "added     .gitattributes" "$(integ_run sh -c 'echo "* filter=x" > .gitattributes')"
assert_contains "detects .envrc (direnv)" "added     .envrc" "$(integ_run sh -c 'echo x > .envrc')"
out="$(integ_run sh -c 'echo "{\"t\":1}" > .vscode/tasks.json; exit 7')"
assert_contains "keeps the session's exit code" "rc=7" "$out"
assert_contains "still reports changes after a failing session" "modified  .vscode/tasks.json" "$out"
assert_equal "pyproject.toml is not watched by default" "rc=0" "$(integ_run sh -c 'echo x > pyproject.toml')"
print -l '# extra' 'pyproject.toml' '../outside' > "${XDG_CONFIG_HOME}/agent-shadow/watch"
out="$(integ_run sh -c 'echo y > pyproject.toml')"
assert_contains "user watch file adds patterns" "modified  pyproject.toml" "$out"
assert_contains "watch patterns leaving the workspace are ignored" "Ignoring watch pattern outside workspace" "$out"
rm -f "${XDG_CONFIG_HOME}/agent-shadow/watch"
out="$(zsh -c 'set -euo pipefail; source "$1/helpers.zsh"; source "$1/integrity.zsh"
  _integrity_save demo "$2"; print change > "$2/.npmrc"; _integrity_check_saved demo "$2"
  [[ -f "${INTEGRITY_DIR}/demo.start" ]] && print kept || print removed' x "$LIB" "$W" 2>&1)"
assert_contains "start→stop compares against the start snapshot" "added     .npmrc" "$out"
assert_contains "start snapshot is removed after the check" "removed" "$out"
GN="${T}/gitnote"; mkdir -p "$GN"
(cd "$GN" && git init -q && print '.vscode/' > .gitignore && print '{}' > package.json && git add -A \
  && git -c user.name=t -c user.email=t@t commit -qm init) >/dev/null 2>&1
out="$(zsh -c 'source "$1/helpers.zsh"; source "$1/integrity.zsh"; b="$(_integrity_snapshot "$2")"
  mkdir -p "$2/.vscode"; print x > "$2/.vscode/tasks.json"; print x > "$2/.envrc"; print "{\"a\":1}" > "$2/package.json"
  _integrity_report "$2" "$b" "$(_integrity_snapshot "$2")" test' x "$LIB" "$GN" 2>&1)"
assert_contains "marks git-ignored files (not in git diff)" ".vscode/tasks.json   (git-ignored: not in git diff)" "$out"
assert_contains "marks untracked files (not in git diff)" ".envrc   (untracked: not in git diff)" "$out"
assert_contains "tracked files are not marked" "modified  package.json"$'\n' "$out"

# ---------------------------------------------------------------------------
section "Host git wrapper (real git; each case first proves plain git runs the program)"
# ---------------------------------------------------------------------------
GH="${T}/githome"; GR="${GH}/repo"; MK="${GH}/marks"; mkdir -p "$GR" "$MK"
(cd "$GR" && HOME="$GH" git init -q && HOME="$GH" git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init) >/dev/null 2>&1
for t in editor askpass credential gpg hook; do
  printf '#!/bin/sh\ntouch "%s/%s"\nexit 1\n' "$MK" "$t" > "${GR}/evil-${t}"; chmod +x "${GR}/evil-${t}"
done
git -C "$GR" config core.editor "${GR}/evil-editor"
git -C "$GR" config core.askPass "${GR}/evil-askpass"
git -C "$GR" config credential.helper "!${GR}/evil-credential"
git -C "$GR" config gpg.program "${GR}/evil-gpg"
mkdir -p "${GR}/.git/hooks"; cp "${GR}/evil-hook" "${GR}/.git/hooks/pre-commit"
gx() {   # gx <plain|shadow> <git args…>  (caller's own GIT_EDITOR etc. cleared, no prompts)
  local mode="$1"; shift
  local -a runner=(git); [[ "$mode" == shadow ]] && runner=("$BIN" git)
  (cd "$GR" && env -u GIT_EDITOR -u GIT_SEQUENCE_EDITOR -u GIT_ASKPASS -u SSH_ASKPASS \
     HOME="$GH" EDITOR=true VISUAL= GIT_TERMINAL_PROMPT=0 "${runner[@]}" -c user.name=t -c user.email=t@t "$@") </dev/null >/dev/null 2>&1 || true
}
ran() { [[ -e "${MK}/$1" ]] && print ran || print no; rm -f "${MK}"/*(N); }
gx plain commit --allow-empty -m x --no-gpg-sign;  r1="$(ran hook)"
gx shadow commit --allow-empty -m x --no-gpg-sign; r2="$(ran hook)"
assert_equal "repo pre-commit hook: runs with plain git, not via agent-shadow git" "ran no" "$r1 $r2"
rm -f "${GR}/.git/hooks/pre-commit"
gx plain commit --allow-empty;  r1="$(ran editor)"
gx shadow commit --allow-empty; r2="$(ran editor)"
assert_equal "repo core.editor: runs with plain git, not via agent-shadow git" "ran no" "$r1 $r2"
git -C "$GR" config commit.gpgsign true
gx plain commit --allow-empty -m x;  r1="$(ran gpg)"
gx shadow commit --allow-empty -m x; r2="$(ran gpg)"
assert_equal "repo gpg.program: runs with plain git, not via agent-shadow git" "ran no" "$r1 $r2"
cred_in=$'protocol=https\nhost=example.com\n\n'
(cd "$GR" && env -u GIT_ASKPASS -u SSH_ASKPASS HOME="$GH" GIT_TERMINAL_PROMPT=0 git credential fill <<< "$cred_in") >/dev/null 2>&1 || true
c1="$([[ -e "${MK}/credential" ]] && print ran || print no)"; a1="$(ran askpass)"
(cd "$GR" && env -u GIT_ASKPASS -u SSH_ASKPASS HOME="$GH" GIT_TERMINAL_PROMPT=0 "$BIN" git credential fill <<< "$cred_in") >/dev/null 2>&1 || true
c2="$([[ -e "${MK}/credential" ]] && print ran || print no)"; a2="$(ran askpass)"
assert_equal "repo credential.helper: runs with plain git, not via agent-shadow git" "ran no" "$c1 $c2"
assert_equal "repo core.askPass: runs with plain git, not via agent-shadow git" "ran no" "$a1 $a2"

# ---------------------------------------------------------------------------
section "Egress allowlist logic (the proxy itself is tested on a Mac)"
# ---------------------------------------------------------------------------
eg() { zsh -c 'set -euo pipefail; source "$1/helpers.zsh"; source "$1/egress.zsh"; eval "$2"' x "$LIB" "$1" 2>&1; }
assert_equal "'*.npmjs.org' becomes an anchored pattern" '^(.*\.)?npmjs\.org$' "$(eg '_egress_glob_to_ere "*.npmjs.org"')"
assert_equal "exact host becomes an anchored pattern" '^pypi\.org$' "$(eg '_egress_glob_to_ere pypi.org')"
# The generated pattern, applied with grep -E the way tinyproxy's ERE filter applies it
ere_match() { local re; re="$(eg "_egress_glob_to_ere '$1'")"; print -r -- "$2" | grep -E "$re" >/dev/null && print match || print no; }
assert_equal "pattern matches the host and its subdomains" "match match" "$(ere_match '*.npmjs.org' npmjs.org) $(ere_match '*.npmjs.org' registry.npmjs.org)"
assert_equal "pattern rejects look-alike hosts" "no no no" \
  "$(ere_match '*.npmjs.org' npmjs.org.evil.com) $(ere_match '*.npmjs.org' evilnpmjs.org) $(ere_match pypi.org pypixorg)"
assert_equal "valid host names are accepted" "ok ok ok" \
  "$(eg '_egress_valid_host api.example.com && print ok') $(eg '_egress_valid_host "*.example.com" && print ok') $(eg '_egress_valid_host 10.0.0.1 && print ok')"
assert_equal "shell/AppleScript characters and mid-label wildcards are rejected" "bad bad bad" \
  "$(eg '_egress_valid_host "x\"; do shell script \"y" || print bad') $(eg '_egress_valid_host "foo*.com" || print bad') $(eg '_egress_valid_host "a b" || print bad')"
assert_equal "address range check" "in out" "$(eg '_ip_in_cidr 192.168.128.2 192.168.128.0/24 && print in') $(eg '_ip_in_cidr 172.20.0.5 192.168.128.0/24 || print out')"
assert_equal "tinyproxy refusal line is parsed" "www.wikipedia.org" \
  "$(eg '_egress_parse_denied "NOTICE    Nov 20 05:30:49.110 [1]: Proxying refused on filtered domain \"www.wikipedia.org\""')"
out="$(eg '_egress_render demo 192.168.128.0/24; cat "$EGRESS_DIR/demo/tinyproxy.conf" "$EGRESS_DIR/demo/filter"')"
assert_contains "proxy config: only the workspace subnet may connect" "Allow 192.168.128.0/24" "$out"
assert_contains "proxy config: deny by default" "FilterDefaultDeny Yes" "$out"
assert_contains "proxy config: CONNECT only to port 443" "ConnectPort 443" "$out"
out="$(eg 'export AGENT_SHADOW_APPROVE=deny DRY_RUN=1; _egress_render demo 192.168.128.0/24
  l="NOTICE x [1]: Proxying refused on filtered domain \"evil.example\""
  _egress_handle_line demo "$l"; _egress_handle_line demo "$l"; grep -c evil "$EGRESS_DIR/demo/approved" || true')"
assert_equal "a denied host is asked about once and not approved" $'DENIED evil.example\n0' "$out"
mkdir -p "${T}/egws"; "$BIN" register --isolated "${T}/egws" >/dev/null 2>&1
out="$(cd "${T}/egws" && "$BIN" egress allow API.Example.com 2>&1; "$BIN" egress list 2>&1)"
assert_contains "egress allow stores the host lowercased" "  api.example.com" "$out"
assert_equal "egress allow rejects an invalid host" "1" "$(cd "${T}/egws" && rc_of "$BIN" egress allow 'bad host')"
out="$(cd "${T}/egws" && "$BIN" egress revoke api.example.com 2>&1; "$BIN" egress list 2>&1)"
assert_contains "egress revoke removes it" "(none)" "$out"

# One allowlist, one answer: the proxy's filter file and `traffic` must agree, host by host
print -l '# global allowlist' '*.astral.sh' > "${XDG_CONFIG_HOME}/agent-shadow/allowlist"
out="$(eg '_egress_render demo 192.168.128.0/24
  eres=(${(f)"$(_allowlist_eres demo)"})
  for h in astral.sh releases.astral.sh evilastral.sh astral.sh.evil.com registry.npmjs.org 1.2.3.4:443 example.com; do
    p=no; print -r -- "$h" | grep -E -f "$EGRESS_DIR/demo/filter" >/dev/null && p=match
    t=no; _allowlist_match "$h" "${eres[@]}" && t=match
    print -rn -- "${h}=${p}/${t} "
  done')"
assert_equal "proxy filter and traffic agree on every host ('*.astral.sh' covers astral.sh too)" \
  "astral.sh=match/match releases.astral.sh=match/match evilastral.sh=no/no astral.sh.evil.com=no/no registry.npmjs.org=match/match 1.2.3.4:443=no/no example.com=no/no " "$out"
rm -f "${XDG_CONFIG_HOME}/agent-shadow/allowlist"

# ---------------------------------------------------------------------------
section "Traffic monitor (the image's scripts on tcpdump -n output as Apple container produces it)"
# ---------------------------------------------------------------------------
TL="${T}/traffic.log"; : > "$TL"
cat > "${T}/tcpdump.txt" <<'TCPDUMP'
12:00:00.000001 eth0 Out IP 192.168.64.5.40000 > 93.184.215.14.443: Flags [S], seq 1, win 64240, length 0
12:00:00.000002 eth0 Out IP 192.168.64.5.40002 > 192.168.64.1.5432: Flags [S], seq 1, win 64240, length 0
12:00:00.000003 eth0 Out IP 192.168.64.5.40004 > 1.1.1.1.443: Flags [S], seq 1, win 64240, length 0
12:00:00.000004 eth0 Out IP 192.168.64.5.53311 > 192.168.64.1.53: 4660+ A? example.com. (29)
12:00:00.000005 eth0 Out IP 192.168.64.5.53312 > 192.168.64.1.53: 4661+ AAAA? example.com. (29)
12:00:00.000006 lo   In  IP 127.0.0.1.40000 > 127.0.0.1.8080: Flags [S], seq 1, win 65495, length 0
12:00:00.000007 eth0 In  IP 93.184.215.14.443 > 192.168.64.5.40000: Flags [S.], seq 1, ack 2, win 65535, length 0
12:00:00.000008 eth0 Out IP 192.168.64.5.40010 > 93.184.215.14.443: Flags [S], seq 9, win 64240, length 0
TCPDUMP
# The image's monitor script records what tcpdump writes (--record-only reads tcpdump's lines from stdin)
mon() { TRAFFIC_LOG="$TL" TRAFFIC_FILTER="${LIB}/image/traffic-filter.awk" sh "${LIB}/image/traffic-monitor.sh" --record-only; }
mon < "${T}/tcpdump.txt"
assert_equal "records each new destination once: public IPs, the Mac (gateway, also .1), DNS names" \
  $'TCP\t93.184.215.14:443\nTCP\t192.168.64.1:5432\nTCP\t1.1.1.1:443\nDNS\texample.com' "$(cut -f2,3 "$TL")"
mon < "${T}/tcpdump.txt"
assert_equal "a restarted monitor does not repeat logged destinations" "4" "$(wc -l < "$TL" | tr -d ' ')"
# tcpdump keeps its pipe open for the whole session: a line must be recorded while it is still open
# (mawk otherwise holds it in its read buffer, and it is lost when the container stops)
: > "$TL"
{ print -r -- '12:20:51.958936 eth0  Out IP 192.168.64.89.43191 > 192.168.64.1.53: 41717+ A? live.example. (23)'; sleep 3; } | mon &
sleep 1.5
assert_equal "a connection is recorded while tcpdump is still running (not only when it stops)" $'DNS\tlive.example' "$(cut -f2,3 "$TL")"
wait

# ---------------------------------------------------------------------------
section "Image template (what init builds, and when an image counts as outdated)"
# ---------------------------------------------------------------------------
im() { zsh -c 'set -euo pipefail; source "$1/helpers.zsh"; source "$1/image.zsh"; eval "$2"' x "$LIB" "$1" 2>&1; }
CTX="${T}/ctx"
im "_image_context ubuntu24 '${CTX}'" >/dev/null
missing=""
for f in ${(f)"$(sed -n 's/^COPY //p' "${CTX}/Containerfile" | awk '{ for (i = 1; i < NF; i++) print $i }')"}; do
  [[ -f "${CTX}/${f}" ]] || missing+="${f} "
done
assert_equal "every file the Containerfile COPYs is in the build context" "" "$missing"
h1="$(im '_image_template_hash ubuntu24')"; h2="$(im '_image_template_hash ubuntu24')"
assert_equal "template hash is stable" "$h1" "$h2"
print 'RUN echo my-layer' > "${XDG_CONFIG_HOME}/agent-shadow/Dockerfile.ubuntu24.append"
im "_image_context ubuntu24 '${CTX}'" >/dev/null
assert_equal "the .append file is inserted before WORKDIR (so it runs as part of the image)" "RUN echo my-layer|WORKDIR /workspace" \
  "$(grep -E '^(RUN echo my-layer|WORKDIR)' "${CTX}/Containerfile" | paste -sd'|' -)"
h3="$(im '_image_template_hash ubuntu24')"
assert_equal "changing the .append file changes the template hash" "differs" "$([[ "$h3" != "$h1" ]] && print differs || print same)"
rm -f "${XDG_CONFIG_HOME}/agent-shadow/Dockerfile.ubuntu24.append"
h4="$(im 'MISE_VERSION=0.0.1; _image_template_hash ubuntu24')"
assert_equal "changing a pin (mise version) changes the template hash" "differs" "$([[ "$h4" != "$h1" ]] && print differs || print same)"
export XDG_STATE_HOME="${T}/state"
assert_equal "an image without a recorded template is outdated" "outdated" \
  "$(im '_image_is_current ubuntu24 agent-base:ubuntu24 && print current || print outdated')"
im 'mkdir -p "$IMAGE_STATE_DIR"; _image_template_hash ubuntu24 > "$(_image_stamp_file agent-base:ubuntu24)"' >/dev/null
assert_equal "an image built from the current template is current" "current" \
  "$(im '_image_is_current ubuntu24 agent-base:ubuntu24 && print current || print outdated')"
print 'RUN echo later' > "${XDG_CONFIG_HOME}/agent-shadow/Dockerfile.ubuntu24.append"
assert_equal "after the .append file changes it is outdated again" "outdated" \
  "$(im '_image_is_current ubuntu24 agent-base:ubuntu24 && print current || print outdated')"
rm -f "${XDG_CONFIG_HOME}/agent-shadow/Dockerfile.ubuntu24.append"

print -P "\n%B  Unit results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed (total ${TEST_COUNT})%b\n"
(( FAIL_COUNT == 0 ))
