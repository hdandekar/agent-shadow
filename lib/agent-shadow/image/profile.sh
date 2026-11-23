# /etc/profile.d/mise.sh — environment for every shell in an agent-shadow container
export PATH="/opt/mise/shims:/opt/mise/bin:/usr/local/bin:$PATH"
export MISE_DATA_DIR=/opt/mise
export MISE_GLOBAL_CONFIG_FILE=/opt/mise/config.toml
export RUSTUP_HOME=/opt/mise/rustup
export CARGO_HOME=/root/.cargo

# /opt/mise is read-only in sessions: explain instead of failing with a read-only error
mise() {
  case "$1" in
    install|use|upgrade|uninstall|rm|prune)
      if [ ! -w "/opt/mise" ]; then
        printf "\033[1;33m⚠️  [agent-shadow notice]\033[0m\n" >&2
        printf "   Shared tools in \033[1m/opt/mise\033[0m are mounted \033[1mREAD-ONLY\033[0m in workspace containers.\n" >&2
        printf "   👉 To modify tools in the shared store, run on your macOS host:\n" >&2
        printf "      \033[1;32magent-shadow tools %s %s\033[0m\n\n" "$1" "${*:2}" >&2
        return 1
      fi
      ;;
  esac
  command mise "$@"
}

# Git identity fallback from the Mac's global ~/.gitconfig (passed in by run/start)
if [ -n "${GIT_FALLBACK_NAME:-}" ] && ! git config --global user.name >/dev/null 2>&1; then
  git config --global user.name "$GIT_FALLBACK_NAME"
fi
if [ -n "${GIT_FALLBACK_EMAIL:-}" ] && ! git config --global user.email >/dev/null 2>&1; then
  git config --global user.email "$GIT_FALLBACK_EMAIL"
fi
