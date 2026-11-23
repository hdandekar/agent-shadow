# integrity.zsh — Workspace → Host change detection
#
# The agent can write anywhere under /workspace, including files that later
# execute on the macOS host *without* the developer deliberately running them
# (git hooks on `git commit`, direnv's .envrc on `cd`, IDE task files, …).
#
# Before a session we hash a list of such files; after the session we compare
# and warn about anything added, modified, or removed. Nothing is blocked.
#
# Patterns are zsh globs relative to the workspace root. Users can extend the
# defaults with one glob per line in ${CONF_DIR}/watch ('#' starts a comment).

readonly WATCH_FILE="${CONF_DIR}/watch"
readonly INTEGRITY_DIR="${CONF_DIR}/integrity"

# Files that can run code on the host automatically or routinely.
readonly -a DEFAULT_WATCH_PATTERNS=(
  # git: run on host `git commit` / `git push` / `git status`
  ".git/hooks/*"
  ".git/config"
  "*/.git/hooks/*"          # nested repos (one level deep)
  "*/.git/config"
  ".gitattributes"          # selects clean/smudge filters and diff drivers from .git/config
  ".git/info/attributes"
  ".gitmodules"
  ".husky/*"
  ".husky/_/*"
  ".pre-commit-config.yaml"
  # shell / direnv
  ".envrc"
  # IDE: executed or loaded by host VS Code / Cursor
  ".vscode/tasks.json"
  ".vscode/settings.json"
  ".vscode/launch.json"
  ".devcontainer/*"
  # package manager scripts & registry redirects (if npm is ever run on host)
  "package.json"
  ".npmrc"
  # build entrypoints commonly run on host
  "Makefile"
  # CI: runs with repository secrets once pushed
  ".github/workflows/*"
)

# ---------------------------------------------------------------------------
# Portable SHA-256 (shasum ships with macOS; sha256sum on Linux CI runners)
# ---------------------------------------------------------------------------
_sha256() {
  if command -v shasum &>/dev/null; then
    command shasum -a 256 "$@"
  elif command -v sha256sum &>/dev/null; then
    command sha256sum "$@"
  else
    _die "Neither 'shasum' nor 'sha256sum' found — cannot verify workspace integrity."
  fi
}

# ---------------------------------------------------------------------------
# Print the effective watch patterns (defaults + user watch file)
# ---------------------------------------------------------------------------
_integrity_patterns() {
  print -rl -- "${DEFAULT_WATCH_PATTERNS[@]}"
  [[ -f "$WATCH_FILE" ]] || return 0
  local pat
  while IFS= read -r pat || [[ -n "$pat" ]]; do
    pat="${pat#"${pat%%[![:space:]]*}"}"   # trim leading whitespace
    pat="${pat%"${pat##*[![:space:]]}"}"   # trim trailing whitespace
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    # Patterns must stay inside the workspace (reported by _integrity_validate_watch)
    [[ "$pat" == /* || "$pat" == *..* ]] && continue
    print -r -- "$pat"
  done < "$WATCH_FILE"
}

# Warn once per session about watch patterns that would escape the workspace
_integrity_validate_watch() {
  [[ -f "$WATCH_FILE" ]] || return 0
  local pat
  while IFS= read -r pat || [[ -n "$pat" ]]; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    if [[ "$pat" == /* || "$pat" == *..* ]]; then
      _warn "Ignoring watch pattern outside workspace (${WATCH_FILE}): ${pat}"
    fi
  done < "$WATCH_FILE"
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot: one line per watched file — "<sha256> <relative path>", sorted
# ---------------------------------------------------------------------------
_integrity_snapshot() {
  local root="$1"
  [[ -d "$root" ]] || return 0

  local pat f
  local -a files=() matches=()
  local -A seen=()
  for pat in "${(@f)$(_integrity_patterns)}"; do
    [[ -z "$pat" ]] && continue
    # (N) no error if no match, (-.) regular files incl. symlink targets, (D) dotfiles
    matches=("${root}"/${~pat}(N-.D))
    for f in "${matches[@]}"; do
      (( ${+seen[$f]} )) && continue
      seen[$f]=1
      files+=("$f")
    done
  done
  (( ${#files} )) || return 0

  local h p
  local -a lines=()
  while read -r h p; do
    [[ -z "$h" || -z "$p" ]] && continue
    lines+=("${h} ${p#${root}/}")
  done < <(_sha256 "${files[@]}" 2>/dev/null)
  print -rl -- "${(o)lines[@]}"
}

# ---------------------------------------------------------------------------
# Compare two snapshots and warn about changes. Always returns 0.
#   $1 workspace root   $2 before   $3 after   $4 label (e.g. "this session")
# ---------------------------------------------------------------------------
_integrity_report() {
  local root="$1" before="$2" after="$3" label="${4:-this session}"
  local -A b=() a=()
  local line p

  for line in "${(@f)before}"; do
    [[ -z "$line" ]] && continue
    b[${line#* }]="${line%% *}"
  done
  for line in "${(@f)after}"; do
    [[ -z "$line" ]] && continue
    a[${line#* }]="${line%% *}"
  done

  local -a changes=()
  for p in "${(@k)a}"; do
    if (( ! ${+b[$p]} )); then
      changes+=("added     ${p}$(_integrity_git_note "$root" "$p")")
    elif [[ "${b[$p]}" != "${a[$p]}" ]]; then
      changes+=("modified  ${p}$(_integrity_git_note "$root" "$p")")
    fi
  done
  for p in "${(@k)b}"; do
    (( ${+a[$p]} )) || changes+=("removed   ${p}")
  done

  (( ${#changes} )) || return 0

  print "" >&2
  _warn "Files that can run code on your Mac changed since ${label} started:"
  local c
  for c in "${(o)changes[@]}"; do
    print -r -- "       ${c}" >&2
  done
  _info "Review them before running git, npm, make, or opening the project in an IDE on the host:"
  _info "  cd ${(q)root} && git diff   (only shows tracked files — open files marked above and .git/ directly)"
  _info "Commit with hooks disabled: agent-shadow git commit …"
  return 0
}

# ---------------------------------------------------------------------------
# Run a command bracketed by snapshot → compare. Preserves the exit code.
#   _integrity_run <workspace_root> <cmd...>
# ---------------------------------------------------------------------------
# Suffix for a changed path that `git diff` will NOT show: git-ignored or untracked.
# Runs host git with fsmonitor/hooks disabled (the repo config may be agent-written).
_integrity_git_note() {
  local root="$1" p="$2"
  [[ "$p" == .git/* || "$p" == */.git/* ]] && return 0
  command -v git >/dev/null 2>&1 || return 0
  local -a g=(command git -C "$root" -c core.fsmonitor=false -c core.hooksPath=/dev/null)
  "${g[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if "${g[@]}" check-ignore -q -- "$p" 2>/dev/null; then
    print -rn -- "   (git-ignored: not in git diff)"
  elif ! "${g[@]}" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    print -rn -- "   (untracked: not in git diff)"
  fi
}

# ---------------------------------------------------------------------------
_integrity_run() {
  local root="$1"; shift
  local before after rc=0
  _integrity_validate_watch
  before="$(_integrity_snapshot "$root")"
  "$@" || rc=$?
  after="$(_integrity_snapshot "$root")"
  _integrity_report "$root" "$before" "$after" "this session"
  return $rc
}

# ---------------------------------------------------------------------------
# Persisted snapshots for background containers (start → stop)
# ---------------------------------------------------------------------------
_integrity_save() {
  local slug="$1" root="$2"
  mkdir -p "$INTEGRITY_DIR"
  _integrity_validate_watch
  _integrity_snapshot "$root" > "${INTEGRITY_DIR}/${slug}.start"
}

_integrity_check_saved() {
  local slug="$1" root="$2"
  local f="${INTEGRITY_DIR}/${slug}.start"
  [[ -f "$f" ]] || return 0
  local before
  before="$(<"$f")"
  _integrity_report "$root" "$before" "$(_integrity_snapshot "$root")" "'agent-shadow start'"
  rm -f "$f"
}

_integrity_forget() {
  rm -f "${INTEGRITY_DIR}/${1}.start" 2>/dev/null || true
}
