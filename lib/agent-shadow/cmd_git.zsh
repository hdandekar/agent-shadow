# cmd_git.zsh — `agent-shadow git` command
# Runs the host's git with the most common repository-controlled commands turned off.
#
# The agent can write .git/config and .git/hooks/ inside /workspace. Git reads
# repo-local config *after* global config, so a global setting cannot protect you.
# Command-line `-c` options and GIT_* environment variables take precedence over
# repo-local config, so we pin these to your own (global) values or safe defaults:
#   - core.hooksPath           → /dev/null      (pre-commit, post-checkout, pre-push, …)
#   - core.fsmonitor           → false          (runs a command on `git status`)
#   - core.sshCommand          → GIT_SSH_COMMAND       (global value or `ssh`)
#   - core.pager               → GIT_PAGER             (global / $PAGER / less)
#   - core.editor              → GIT_EDITOR            (global / $VISUAL / $EDITOR / vi)
#   - sequence.editor          → GIT_SEQUENCE_EDITOR   (global sequence.editor / the editor)
#   - core.askPass             → GIT_ASKPASS           (yours, or empty = no askpass)
#   - credential.helper        → reset, then your global helpers re-added
#   - gpg{,.ssh,.x509}.program → global values or gpg / ssh-keygen / gpgsm
#
# NOT covered (not a complete list): clean/smudge filters, diff.external and diff/merge
# drivers (textconv, command, merge.*.driver), include.path / includeIf, aliases,
# pager.<cmd>, remote.*.uploadpack / receivepack, core.gitProxy. This is not a security
# boundary for an untrusted repository; the session-exit warning flags .git/config
# changes so you can review them first.

_git_global() { command git config --global --get "$1" 2>/dev/null || true; }

cmd_git() {
  local ssh_cmd pager editor seq_editor askpass
  ssh_cmd="${GIT_SSH_COMMAND:-$(_git_global core.sshCommand)}"; : ${ssh_cmd:=ssh}
  pager="${GIT_PAGER:-$(_git_global core.pager)}";               : ${pager:=${PAGER:-less}}
  editor="${GIT_EDITOR:-$(_git_global core.editor)}";            : ${editor:=${VISUAL:-${EDITOR:-vi}}}
  seq_editor="${GIT_SEQUENCE_EDITOR:-$(_git_global sequence.editor)}"; : ${seq_editor:=$editor}
  # Empty GIT_ASKPASS makes git skip core.askPass from the repository.
  askpass="${GIT_ASKPASS-$(_git_global core.askPass)}"

  local gpg_prog gpg_ssh gpg_x509
  gpg_prog="$(_git_global gpg.program)";       : ${gpg_prog:=gpg}
  gpg_ssh="$(_git_global gpg.ssh.program)";    : ${gpg_ssh:=ssh-keygen}
  gpg_x509="$(_git_global gpg.x509.program)";  : ${gpg_x509:=gpgsm}

  local -a safe_args=(
    -c core.hooksPath=/dev/null
    -c core.fsmonitor=false
    -c "gpg.program=${gpg_prog}"
    -c "gpg.ssh.program=${gpg_ssh}"
    -c "gpg.x509.program=${gpg_x509}"
    -c credential.helper=          # empty value resets the helper list (incl. the repo's)
  )
  local h
  for h in ${(f)"$(command git config --global --get-all credential.helper 2>/dev/null || true)"}; do
    [[ -n "$h" ]] && safe_args+=(-c "credential.helper=${h}")
  done


  GIT_SSH_COMMAND="$ssh_cmd" GIT_PAGER="$pager" GIT_EDITOR="$editor" \
    GIT_SEQUENCE_EDITOR="$seq_editor" GIT_ASKPASS="$askpass" \
    command git "${safe_args[@]}" "$@"
}
