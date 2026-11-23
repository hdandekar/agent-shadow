#!/bin/zsh
# mutants.zsh — prove the tests catch real failures by breaking the code on purpose.
#
# Each mutant copies the repository to a temp folder, makes one deliberate change that
# re-introduces a bug (e.g. mounts /opt/mise read-write, drops the 127.0.0.1 binding), and runs
# the tests that should notice. A test run that FAILS means the mutant was caught: KILLED (good).
# A run that still passes means no test noticed: SURVIVED (bad, the test needs work).
#
#   zsh tests/mutants.zsh --unit            host-only mutants (fast; any OS)
#   zsh tests/mutants.zsh --mac             mutants checked by the real-Mac suite (slow)
#   zsh tests/mutants.zsh --only NAME[,…]   just these mutants
#   zsh tests/mutants.zsh --check           only check every mutant still applies (no tests)
#   zsh tests/mutants.zsh --list
#
# Your working tree is never modified. Before the mutants, the unmodified copy is tested once
# (baseline) — mutants only mean something if that passes. --no-baseline skips it.
# Mutants that change the Containerfile are not listed: `init` keeps an existing image, so
# they would not reach the containers.

set -uo pipefail
REPO_ROOT="${${(%):-%x}:A:h:h}"

# name | suite (unit or mac:<sections>) | file | text to find (exact) | replacement | bug re-introduced
local -a M=()
m() { M+=("${(pj:\x1f:)@}"); }

# ---- host-only (tests/unit_test.zsh) --------------------------------------------------------
m slug-collision unit lib/agent-shadow/helpers.zsh \
  '  if ! _registry_lookup_by_slug "$base"; then' '  if true; then' \
  "two folders with the same name share one slug (and one /root)"
m watch-no-hooks unit lib/agent-shadow/integrity.zsh \
  $'  ".git/hooks/*"\n' '' "new git hooks are not reported"
m watch-no-gitattributes unit lib/agent-shadow/integrity.zsh \
  $'  ".gitattributes"' $'  # ".gitattributes"' ".gitattributes changes are not reported"
m watch-no-envrc unit lib/agent-shadow/integrity.zsh \
  $'  ".envrc"\n' '' ".envrc changes are not reported"
m integrity-loses-exit-code unit lib/agent-shadow/integrity.zsh \
  $'  _integrity_report "$root" "$before" "$after" "this session"\n  return $rc' \
  $'  _integrity_report "$root" "$before" "$after" "this session"\n  return 0' \
  "the agent's exit code is replaced by 0"
m git-hooks-enabled unit lib/agent-shadow/cmd_git.zsh \
  $'    -c core.hooksPath=/dev/null\n' '' "agent-shadow git runs repository hooks"
m git-credential-kept unit lib/agent-shadow/cmd_git.zsh \
  '    -c credential.helper=          #' '    #' "the repository's credential.helper runs"
m git-editor-from-repo unit lib/agent-shadow/cmd_git.zsh \
  'GIT_PAGER="$pager" GIT_EDITOR="$editor" \' 'GIT_PAGER="$pager" \' "the repository's core.editor runs"
m egress-unanchored unit lib/agent-shadow/egress.zsh \
  'print -r -- "^${prefix}${p}\$"' 'print -r -- "${prefix}${p}"' \
  "allowlist patterns match look-alike hosts (npmjs.org.evil.com)"
m egress-validator-open unit lib/agent-shadow/egress.zsh \
  '  [[ -n "$h" && ${#h} -le 253 ]] || return 1' '  return 0' \
  "any string (incl. AppleScript) is accepted as a host"
m proxy-default-allow-unit unit lib/agent-shadow/egress.zsh \
  'FilterDefaultDeny Yes' 'FilterDefaultDeny No' "the proxy allows every host"

m install-uses-cwd unit install.sh \
  $'if ! [[ -f "$SCRIPT_PATH" && "${SCRIPT_PATH:t}" == install.sh && -f "${SCRIPT_PATH:A:h}/bin/agent-shadow" ]]; then' \
  $'if ! [[ -f "${PWD}/bin/agent-shadow" ]]; then' \
  "curl … | zsh inside a checkout installs the unverified local files"
m guardrail-allows-workspace unit lib/agent-shadow/image/rm-guard.sh \
  '      /|/root|/workspace|"$HOME"|' '      /|/root|"$HOME"|' "rm -rf /workspace is no longer blocked"
m traffic-hides-dot1 unit lib/agent-shadow/image/traffic-filter.awk \
  'if (ip !~ /^127\./ && ip != "0.0.0.0")' 'if (ip !~ /^127\./ && ip !~ /\.1$/ && ip != "0.0.0.0")' \
  "traffic hides every address ending in .1, including the Mac (gateway) and 1.1.1.1"
m run-accepts-version unit lib/agent-shadow/cmd_run.zsh \
  '  [[ "$agent" == *@* && "$agent" != */* ]] && \' '  false && \' \
  "run agy@latest gets no hint (and fails later with an invalid container name)"
m image-append-dropped unit lib/agent-shadow/image.zsh \
  '      cat "$append"; print' '      true' "the user's .append layers are left out of the image"
m image-hash-ignores-pins unit lib/agent-shadow/image.zsh \
  '; print -r -- "${reply[*]}"; }' '; }' "a changed pin (base digest, mise version) doesn't mark images outdated"
m image-always-current unit lib/agent-shadow/image.zsh \
  '  [[ -f "$stamp" && "$(<"$stamp")" == "$(_image_template_hash "$1")" ]]' '  true' \
  "outdated images are never reported"
m completion-drift unit completions/_agent-shadow \
  "    'uninstall:Remove workspaces, their volumes and the config (--purge: images and toolchains too)'" '' \
  "a command is missing from the zsh completion"

# ---- real Mac (tests/mac_e2e_test.zsh --only <sections>) -------------------------------------
m stop-skips-change-check mac:lifecycle lib/agent-shadow/cmd_stop.zsh \
  $'  _ok "Stopped workspace container \'${cname}\'."\n  _integrity_check_saved "$slug" "$workspace_root"' \
  $'  _ok "Stopped workspace container \'${cname}\'."' \
  "stop no longer reports files changed since start"
m reuse-unchecked mac:network lib/agent-shadow/egress.zsh \
  '  _container_only_on "$cname" "$net" && return 0' '  return 0' \
  "run/connect reuse a container that is on another network"
m isolated-not-internal mac:egress lib/agent-shadow/cmd_register.zsh \
  '[[ -z "$custom_net" ]] && (( isolated_flag )) && net_args+=(--internal)' 'true' \
  "--isolated networks get direct internet access"
m proxy-default-allow mac:egress lib/agent-shadow/egress.zsh \
  'FilterDefaultDeny Yes' 'FilterDefaultDeny No' "the proxy allows every host"
m proxy-left-running mac:egress lib/agent-shadow/egress.zsh \
  $'  _egress_stop_proxy_if_idle "$slug"\n  return $rc' '  return $rc' "the proxy keeps running after the session"
m tools-forces-tty mac:tools lib/agent-shadow/cmd_tools.zsh \
  '  [[ -t 0 ]] && tty_arg=(--tty)' '  tty_arg=(--tty)' \
  "tools can't run without a terminal (scripts, CI)"
m tools-gate-off mac:tools lib/agent-shadow/cmd_tools.zsh \
  '  _tools_check_running_agents "$vol"' '  true' "tools writes the store while sessions mount it"
m wash-noop mac:wash lib/agent-shadow/cmd_wash.zsh \
  '  command container volume rm "$vol_home" >/dev/null 2>&1 || true' '  true' "wash leaves the old /root in place"
m slug-collision-mac mac:registry lib/agent-shadow/helpers.zsh \
  '  if ! _registry_lookup_by_slug "$base"; then' '  if true; then' \
  "two folders with the same name share one /root"
m stopall-unscoped mac:stopall lib/agent-shadow/cmd_stop.zsh \
  '      _shadow_owns_container "$c" || continue' '      [[ "$c" == agent-* || "$c" == shadow-proxy-* ]] || continue' \
  "stop --all stops other tools' agent-* containers"
m mise-writable mac:run lib/agent-shadow/session.zsh \
  '    --volume "${MISE_VOLUME[$distro]}:/opt/mise:ro"' '    --volume "${MISE_VOLUME[$distro]}:/opt/mise"' \
  "sessions can change the shared toolchains"
m workspace-readonly mac:run lib/agent-shadow/session.zsh \
  '    --volume "${root}:/workspace"' '    --volume "${root}:/workspace:ro"' "the agent cannot write the project"
m home-not-persistent mac:run lib/agent-shadow/session.zsh \
  $'    --volume "home-${slug}:/root"\n' '' "/root is lost after every session"
m env-file-ignored mac:run lib/agent-shadow/session.zsh \
  '      reply+=(--env "$line")' '      true' "--env-file never reaches the container"
m publish-all-interfaces mac:lifecycle lib/agent-shadow/session.zsh \
  '    a+=(--publish "127.0.0.1:${host_port}:${container_port}")' '    a+=(--publish "$pub")' \
  "the address given with -p (e.g. 0.0.0.0) is passed through instead of 127.0.0.1 (needs an address on en0/en1)"
m attach-drops-env mac:lifecycle lib/agent-shadow/cmd_run.zsh \
  '    exec_args+=("${env_args[@]}" "${egress_env[@]}")' '    exec_args+=("${egress_env[@]}")' \
  "--env/--env-file are dropped when run attaches to a running container"
m traffic-own-matcher mac:traffic lib/agent-shadow/cmd_traffic.zsh \
  '_traffic_known() { _allowlist_match "$1" "${eres[@]}"; }' \
  '_traffic_known() { local p; for p in "${DEFAULT_ALLOWLIST[@]}" ${(f)"$(_egress_read_list "$ALLOWLIST_FILE")"}; do [[ "${1%:*}" == $~p ]] && return 0; done; return 1; }' \
  "traffic matches the allowlist differently from the proxy ('*.x' not covering x)"
m doctor-ignores-missing-folder mac:doctor lib/agent-shadow/cmd_doctor.zsh \
  '    if [[ -d "$abspath" ]]; then' '    if true; then' "doctor doesn't notice a registered folder that is gone"
m doctor-skips-outdated-image mac:doctor lib/agent-shadow/cmd_doctor.zsh \
  '      _image_is_current "$distro" "$tag" || { _image_warn_if_stale "$distro" "$tag"; all_ok=0; }' '      true' \
  "doctor doesn't report an image built from an older template"
# Running containers only: the suite refuses to start while any of yours run, so this mutant
# can only hit the test's own containers.
m uninstall-unscoped mac:uninstall lib/agent-shadow/cmd_uninstall.zsh \
  '  for c in ${(f)"$(_container_names -a)"}; do _shadow_owns_container "$c" && cnames+=("$c"); done' \
  '  for c in ${(f)"$(_container_names)"}; do [[ "$c" == agent-* ]] && cnames+=("$c"); done' \
  "uninstall removes other tools' agent-* containers"

m run-unsafe-container-name mac:run lib/agent-shadow/cmd_run.zsh \
  '  agent_id="${${agent_id//[^a-z0-9]/-}:-agent}"' '  true' \
  "a program name with '@' or '.' becomes an invalid container name"
# Last on purpose: it changes an image file, so the test image is rebuilt for it (and once more by
# the next normal run). Only the image's awk (mawk) buffers pipes; macOS's awk can't show it.
m traffic-awk-buffered mac:traffic lib/agent-shadow/image/traffic-monitor.sh \
  'awk -W version </dev/null 2>/dev/null | grep mawk >/dev/null && AWK="awk -W interactive"' 'true' \
  "connections of a short session are never recorded (mawk buffers the pipe)"


# ---------------------------------------------------------------------------
MODE="unit" ONLY="" CHECK=0 BASELINE=1
while (( $# )); do
  case "$1" in
    --unit) MODE=unit ;; --mac) MODE=mac ;; --all) MODE=all ;;
    --only) shift; ONLY="${1:-}"; MODE=all ;;
    --check) CHECK=1; MODE=all ;;
    --no-baseline) BASELINE=0 ;;
    --list) for e in "${M[@]}"; do f=("${(@ps:\x1f:)e}"); printf '%-28s %-16s %s\n' "${f[1]}" "${f[2]}" "${f[6]}"; done; exit 0 ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

T="${$(mktemp -d "${TMPDIR:-/tmp}/agent-shadow-mutants.XXXXXX"):A}"
LOGS="${REPO_ROOT}/tests/tmp/mutants-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
trap 'rm -rf "$T"' EXIT

# Copy of the working tree (uncommitted changes included), without .git and old logs
snapshot() {
  mkdir -p "$1"
  (cd "$REPO_ROOT" && tar -cf - --exclude ./.git --exclude ./tests/tmp .) | (cd "$1" && tar -xf -)
}
# apply <copy> <file> <from> <to> : exact text replacement of the first occurrence; 3 = not found
apply() {
  FROM="$3" TO="$4" perl -0777 -pi -e '$n += s/\Q$ENV{FROM}\E/$ENV{TO}/; END { exit($n ? 0 : 3) }' "$1/$2"
}
# run_suite <copy> <suite> <log> : 0 = tests passed
run_suite() {
  local dir="$1" suite="$2" log="$3"
  if [[ "$suite" == unit ]]; then
    zsh "${dir}/tests/unit_test.zsh" > "$log" 2>&1
  else
    zsh "${dir}/tests/mac_e2e_test.zsh" --only "${suite#mac:}" > "$log" 2>&1
  fi
}
wanted() {   # wanted <name> <suite>
  [[ -n "$ONLY" ]] && { (( ${${(s:,:)ONLY}[(Ie)$1]} )); return; }
  case "$MODE" in unit) [[ "$2" == unit ]] ;; mac) [[ "$2" == mac:* ]] ;; *) true ;; esac
}

BASE="${T}/base"; snapshot "$BASE"
local -a todo=()
for e in "${M[@]}"; do f=("${(@ps:\x1f:)e}"); wanted "${f[1]}" "${f[2]}" && todo+=("$e"); done
(( ${#todo} )) || { print "No mutants selected."; exit 2; }

if (( BASELINE && ! CHECK )); then
  local -a suites=()
  for e in "${todo[@]}"; do f=("${(@ps:\x1f:)e}"); suites+=("${f[2]}"); done
  local -a mac_secs=(${(u)${(s:,:)${(j:,:)${${(M)suites:#mac:*}#mac:}}}})
  print -P "%B── baseline: unmodified copy ──%b"
  if (( ${suites[(I)unit]} )); then
    run_suite "$BASE" unit "${LOGS}/baseline-unit.log" || { print "Baseline unit tests FAIL — fix them first (${LOGS}/baseline-unit.log)."; exit 1; }
    print "  unit tests pass"
  fi
  if (( ${#mac_secs} )); then
    run_suite "$BASE" "mac:${(j:,:)mac_secs}" "${LOGS}/baseline-mac.log" || { print "Baseline Mac tests FAIL — fix them first (${LOGS}/baseline-mac.log)."; exit 1; }
    print "  Mac tests pass (${(j:,:)mac_secs})"
  fi
fi

print -P "\n%B── mutants ──%b"
killed=0 survived=0 stale=0
local -a bad=()
for e in "${todo[@]}"; do
  f=("${(@ps:\x1f:)e}")
  name="${f[1]}" suite="${f[2]}" file="${f[3]}" from="${f[4]}" to="${f[5]}" why="${f[6]}"
  copy="${T}/${name}"; rm -rf "$copy"; cp -R "$BASE" "$copy"
  if ! apply "$copy" "$file" "$from" "$to"; then
    stale=$(( stale + 1 )); bad+=("${name}: STALE (text not found in ${file})")
    print -P "%F{yellow}  ? STALE%f    ${name}: the text to change is no longer in ${file}"
    rm -rf "$copy"; continue
  fi
  if (( CHECK )); then print -P "%F{green}  ✓ applies%f  ${name}"; rm -rf "$copy"; continue; fi
  log="${LOGS}/${name}.log"
  if run_suite "$copy" "$suite" "$log"; then
    survived=$(( survived + 1 )); bad+=("${name}: SURVIVED — ${why}")
    print -P "%F{red}  ✗ SURVIVED%f ${name}  (${why}) — no test noticed; log: ${log}"
  else
    killed=$(( killed + 1 ))
    caught="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E '✗ (\[FAIL\]|FAIL)' | head -2 | sed -E 's/^ *✗ (\[FAIL\]|FAIL) */"/; s/$/"/' | paste -sd ';' -)"
    print -P "%F{green}  ✓ KILLED%f   ${name}  (${why})"
    print -r -- "               caught by: ${caught:-the suite exited non-zero}"
  fi
  rm -rf "$copy"
done

if (( CHECK )); then
  print -P "\n%B  Mutants: $(( ${#todo} - stale )) apply, ${stale} stale%b"
  rm -rf "$LOGS"
else
  print -P "\n%B  Mutants: ${killed} killed, ${survived} survived, ${stale} stale%b  (logs: ${LOGS})"
fi
(( ${#bad} )) && print -l "${bad[@]/#/  - }"
(( survived == 0 && stale == 0 ))
