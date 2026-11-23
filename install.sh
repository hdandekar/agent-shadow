#!/usr/bin/env zsh
# install.sh — install agent-shadow from this checkout (for development).
# Users install with Homebrew:
#   brew tap hdandekar/agent-shadow https://github.com/hdandekar/agent-shadow && brew install agent-shadow
#
# Installs into ${XDG_DATA_HOME:-~/.local/share}/agent-shadow and links ${XDG_BIN_HOME:-~/.local/bin}/agent-shadow.
# Remove with: agent-shadow uninstall
#
# SPDX-License-Identifier: MIT

set -euo pipefail

_info() { print -P "%F{208}[agent-shadow-installer]%f $*"; }
_ok()   { print -P "%F{green}  ✓%f $*"; }
_warn() { print -P "%F{yellow}  ⚠%f $*"; }
_err()  { print -P "%F{red}  ✗ Error:%f $*"; }

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/agent-shadow"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
ZSH_COMPLETION_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions"

if [[ "${1:-}" == (--uninstall|uninstall) ]]; then
  _err "Uninstall moved into the command itself: agent-shadow uninstall [--purge]"
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  _err "agent-shadow runs only on macOS 26+ with Apple's 'container' (detected: $(uname -s))."
  exit 1
fi

# Only from a file in a checkout (./install.sh). Piped (curl … | zsh) there is no file, and
# whatever happens to be in the current directory must not be installed.
SCRIPT_PATH="${(%):-%x}"
if ! [[ -f "$SCRIPT_PATH" && "${SCRIPT_PATH:t}" == install.sh && -f "${SCRIPT_PATH:A:h}/bin/agent-shadow" ]]; then
  _err "Run ./install.sh inside a checkout of agent-shadow, or install with Homebrew:"
  _err "  brew tap hdandekar/agent-shadow https://github.com/hdandekar/agent-shadow && brew install agent-shadow"
  exit 1
fi
SOURCE_DIR="${SCRIPT_PATH:A:h}"

_info "Installing from ${SOURCE_DIR} into ${INSTALL_DIR}…"
mkdir -p "${INSTALL_DIR}/bin" "${INSTALL_DIR}/completions" "$BIN_DIR" "$ZSH_COMPLETION_DIR"
cp -f "${SOURCE_DIR}/bin/agent-shadow" "${INSTALL_DIR}/bin/agent-shadow"
rm -rf "${INSTALL_DIR}/lib/agent-shadow"   # drop files an older version had
mkdir -p "${INSTALL_DIR}/lib"
cp -R "${SOURCE_DIR}/lib/agent-shadow" "${INSTALL_DIR}/lib/agent-shadow"
cp -f "${SOURCE_DIR}/completions/_agent-shadow" "${INSTALL_DIR}/completions/_agent-shadow"
cp -f "${SOURCE_DIR}/completions/_agent-shadow" "${ZSH_COMPLETION_DIR}/_agent-shadow"
chmod +x "${INSTALL_DIR}/bin/agent-shadow"
ln -sf "${INSTALL_DIR}/bin/agent-shadow" "${BIN_DIR}/agent-shadow"
_ok "Installed: ${BIN_DIR}/agent-shadow -> ${INSTALL_DIR}/bin/agent-shadow"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  _warn "${BIN_DIR} is not in your PATH. Add to ~/.zshrc:"
  print -r -- "    export PATH=\"${BIN_DIR}:\$PATH\""
fi

# Installing Apple's container (and its guest kernel) is Apple's job, not ours
if command -v container &>/dev/null; then
  container system status &>/dev/null || container system start || true
else
  _warn "Apple 'container' CLI is required: brew install container (or https://github.com/apple/container/releases),"
  _warn "  then: container system start"
fi
_info "Next: agent-shadow init"
