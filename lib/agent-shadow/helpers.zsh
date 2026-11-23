# helpers.zsh — shared utilities, constants, and registry functions
# Sourced by bin/agent-shadow before any command is dispatched.

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------
readonly AGENT_SHADOW_VERSION="0.1.4"

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
readonly CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-shadow"
readonly REGISTRY="${CONF_DIR}/workspaces"
readonly ALLOWLIST_FILE="${CONF_DIR}/allowlist"

# ---------------------------------------------------------------------------
# Default network traffic allowlist (trusted registries, git hosts, LLM APIs)
# ---------------------------------------------------------------------------
readonly -a DEFAULT_ALLOWLIST=(
  "registry.npmjs.org"
  "*.npmjs.org"
  "registry.yarnpkg.com"
  "pypi.org"
  "*.pypi.org"
  "files.pythonhosted.org"
  "crates.io"
  "static.crates.io"
  "github.com"
  "api.github.com"
  "raw.githubusercontent.com"
  "objects.githubusercontent.com"
  "*.github.com"
  "*.githubusercontent.com"
  "gitlab.com"
  "*.ubuntu.com"
  "mise.jdx.dev"
  "mise.run"
  "api.anthropic.com"
  "claude.ai"
  "api.openai.com"
  "generativelanguage.googleapis.com"
)

# ---------------------------------------------------------------------------
# Supported distros (this release: ubuntu24 and ubuntu26 only)
# ---------------------------------------------------------------------------
readonly -a SUPPORTED_DISTROS=(ubuntu24 ubuntu26)

# Standard base images (resolved natively by Apple Container via docker.io)
typeset -gA BASE_IMAGE=(
  ubuntu24 "ubuntu:24.04"
  ubuntu26 "ubuntu:26.04"
)

# Digest pins for the base images (multi-arch index digest, "sha256:…"). Empty = moving tag.
# Recorded 2026-11-21: matched between `container image inspect` on a Mac and the Docker Hub
# tag API. Updating them is a deliberate change (Ubuntu security updates arrive that way).
typeset -gA BASE_IMAGE_SHA=(
  ubuntu24 "sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289"
  ubuntu26 "sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db"
)

# mise release installed in the base image, and the SHA-256 of its linux-arm64 binary
# (Apple container runs arm64 Linux only). Recorded from the release's SHASUMS256.txt.
MISE_VERSION="2026.11.10"
MISE_SHA256_LINUX_ARM64="86ef275d541c5243cd20b1c0fcd16810e5f3601113d8db09278d0608617a3833"

# Shared toolchain volume. AGENT_SHADOW_MISE_VOLUME selects another one (the Mac test
# suite uses its own, so it never changes your real toolchains).
# Images are <prefix>-base:<distro> and <prefix>-proxy:latest. AGENT_SHADOW_IMAGE_PREFIX
# selects another set (the Mac test suite builds its own, so it never rebuilds yours).
: ${AGENT_SHADOW_IMAGE_PREFIX:=agent}
: ${AGENT_SHADOW_MISE_VOLUME:=mise-store}
typeset -gA MISE_VOLUME=(
  ubuntu24 "$AGENT_SHADOW_MISE_VOLUME"
  ubuntu26 "$AGENT_SHADOW_MISE_VOLUME"
)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
: ${DEFAULT_DISTRO:=ubuntu24}
: ${DEFAULT_CPUS:=4}
: ${DEFAULT_MEMORY:=4g}


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
_info()    { print -P "%F{208}[agent-shadow]%f $*" >&2; }   # 208 = orange: distinct from common zsh themes (e.g. robbyrussell cyan)
_ok()      { print -P "%F{green}  ✓%f $*" >&2; }
_warn()    { print -P "%F{yellow}  ⚠%f $*" >&2; }
_err()     { print -P "%F{red}  ✗ Error:%f $*" >&2; }
_die()     { _err "$*"; exit 1; }
_heading() { print -P "\n%B%F{blue}── $* ──%f%b" >&2; }

_reject_isolated_custom_network() {
  local command_name="$1" isolated_flag="$2" custom_net="$3"
  if (( isolated_flag )) && [[ -n "$custom_net" ]]; then
    _die "Cannot combine '--isolated' with '--network' for '${command_name}'.\n  Use '--isolated' for the workspace-managed internal network, or '--network NAME' without '--isolated' for a custom network."
  fi
}

# ---------------------------------------------------------------------------
# `container` command helpers
# ---------------------------------------------------------------------------
# Names of running containers, one per line (pass -a to include stopped ones).
# Apple `container` 1.x has no Go-template --format; its table's first column (ID)
# is the name given with --name.
_container_names() {
  command container ls "$@" 2>/dev/null | awk 'NR == 1 && $1 ~ /^[A-Z]+$/ { next } NF { print $1 }'
}

# "<name> <ip>[,<ip>…]" per running container, IPv4 masks stripped (empty if none).
# Reads the IP column of `container ls` by pattern (not by header name or position).
# Collects EVERY address on the row, however the runtime separates them ("a,b", "a, b",
# "a b"): the network checks must see all of a dual-homed container's addresses.
# IPv6 addresses are kept too, so checks that only understand IPv4 fail closed on them.
_container_addrs() {
  command container ls 2>/dev/null | awk '
    NR == 1 && $1 ~ /^[A-Z]+$/ { next }
    NF {
      addrs = ""
      for (i = 2; i <= NF; i++) {
        n = split($i, part, ",")
        for (j = 1; j <= n; j++) {
          a = part[j]
          if (a == "") continue
          v4 = (a ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/)
          # IPv6 has "::" or 8 groups (7 colons); a time like 15:03:29 has neither.
          v6 = 0
          if (a ~ /^[0-9a-fA-F:]+(\/[0-9]+)?$/) { t = a; c = gsub(/:/, ":", t); v6 = (a ~ /::/ || c == 7) }
          if (!v4 && !v6) continue
          sub(/\/[0-9]+$/, "", a)
          addrs = addrs (addrs == "" ? "" : ",") a
        }
      }
      print $1, addrs
    }'
}

# Network names, one per line (Apple container 1.x table, first column).
_network_names() {
  command container network ls 2>/dev/null | awk 'NR == 1 && $1 ~ /^[A-Z]+$/ { next } NF { print $1 }'
}

_run() {
  command container "$@"
}

# ---------------------------------------------------------------------------
# Ensure Apple container's service is running. Its guest kernel is Apple's business:
# `container system start` offers to install the recommended one when none is set.
# ---------------------------------------------------------------------------
_ensure_container_system() {
  command -v container &>/dev/null || return 0
  if ! command container system status &>/dev/null; then
    _info "Starting container system service (container system start)…"
    command container system start || true
  fi
}

# ---------------------------------------------------------------------------
# Slugify: basename → lowercase, non-alnum runs → '-', trim dashes
# ---------------------------------------------------------------------------
_slugify() {
  local name="${1:t}"
  name="${name:l}"
  name="${name//[^a-z0-9]/-}"
  while [[ "$name" == *--* ]]; do name="${name//--/-}"; done
  name="${name#-}"; name="${name%-}"
  print "$name"
}

# ---------------------------------------------------------------------------
# Distro validation — fails fast with a clear message if unsupported
# ---------------------------------------------------------------------------
_resolve_distro() {
  local distro="${1:-$DEFAULT_DISTRO}"
  if (( ! ${SUPPORTED_DISTROS[(Ie)$distro]} )); then
    _die "Distro '${distro}' is not supported in this release.\n  Supported: ${SUPPORTED_DISTROS[*]}\n  Run 'agent-shadow --help' for more information."
  fi
  print "$distro"
}

# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------

_registry_init() {
  mkdir -p "$CONF_DIR"
  [[ -f "$REGISTRY" ]] || touch "$REGISTRY"
}

# Write or update a registry entry: "slug|abspath|distro|network"
_registry_add() {
  local slug="$1" abspath="$2" distro="$3" network="${4:-shadow-net}"
  _registry_init
  local tmpfile="${REGISTRY}.tmp"
  grep -v "^${slug}|" "$REGISTRY" 2>/dev/null > "$tmpfile" || true
  print "${slug}|${abspath}|${distro}|${network}" >> "$tmpfile"
  mv "$tmpfile" "$REGISTRY"
}

# Remove a registry entry by slug
_registry_remove() {
  local slug="$1"
  _registry_init
  local tmpfile="${REGISTRY}.tmp"
  grep -v "^${slug}|" "$REGISTRY" 2>/dev/null > "$tmpfile" || true
  mv "$tmpfile" "$REGISTRY"
}

# Look up a registered workspace from an absolute path or any parent.
# On success sets: REPLY_SLUG, REPLY_ROOT, REPLY_DISTRO, REPLY_NETWORK
_registry_lookup() {
  local search="${1:A}"   # registry paths are stored resolved (${dir:A})
  _registry_init
  local line slug abspath distro network
  while IFS='|' read -r slug abspath distro network; do
    [[ -z "$slug" || "$slug" == \#* ]] && continue
    if [[ "$search" == "$abspath" || "$search" == "$abspath/"* ]]; then
      REPLY_SLUG="$slug"
      REPLY_ROOT="$abspath"
      REPLY_DISTRO="$distro"
      REPLY_NETWORK="${network:-shadow-net}"
      return 0
    fi
  done < "$REGISTRY"
  return 1
}

# Look up a registered workspace by its exact (resolved) root path; parents don't count.
# On success sets: REPLY_SLUG, REPLY_ROOT, REPLY_DISTRO, REPLY_NETWORK
_registry_lookup_path() {
  local want="${1:A}"
  _registry_init
  local slug abspath distro network
  while IFS='|' read -r slug abspath distro network; do
    [[ -z "$slug" || "$slug" == \#* ]] && continue
    if [[ "$abspath" == "$want" ]]; then
      REPLY_SLUG="$slug"; REPLY_ROOT="$abspath"; REPLY_DISTRO="$distro"
      REPLY_NETWORK="${network:-shadow-net}"
      return 0
    fi
  done < "$REGISTRY"
  return 1
}

# Slug for a directory: its existing slug if registered; otherwise the folder name, or,
# if another folder already uses that name, the name plus 6 hex digits of the path's
# SHA-256 (~/a/app -> app, ~/b/app -> app-1c3f9a). Volumes and containers are named
# after the slug, so two folders must never share one.
_registry_slug_for() {
  local dir="${1:A}" base hash
  if _registry_lookup_path "$dir"; then
    print -r -- "$REPLY_SLUG"; return 0
  fi
  base="$(_slugify "$dir")"
  [[ -n "$base" ]] || _die "Cannot derive a workspace name from '${dir}' (no letters or digits)."
  if ! _registry_lookup_by_slug "$base"; then
    print -r -- "$base"; return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    hash="$(print -rn -- "$dir" | command shasum -a 256)"
  else
    hash="$(print -rn -- "$dir" | command sha256sum)"
  fi
  print -r -- "${base}-${hash[1,6]}"
}

# 0 if a container name belongs to a registered workspace (agent-<slug>, agent-<agent>-<slug>,
# shadow-proxy-<slug>). Commands that act on "all" containers use this, never a bare
# name prefix: other tools' containers can also be called agent-*.
_shadow_owns_container() { _container_owner "$1"; }

# _container_owner <container name> : which registered workspace a container belongs to, and what
# it is. Sets REPLY_SLUG and REPLY_ROLE ("background" for start, "proxy", or the program a run
# session started, e.g. "bash"); returns 1 if it belongs to none. The longest matching slug wins:
# agent-bash-wheres-shadow is a bash session of 'wheres-shadow', not a 'bash-wheres' session of 'shadow'.
_container_owner() {
  local name="$1" slug rest best="" role=""
  [[ -f "$REGISTRY" ]] || return 1
  while IFS='|' read -r slug rest; do
    [[ -z "$slug" || "$slug" == \#* ]] && continue
    (( ${#slug} > ${#best} )) || continue
    case "$name" in
      "agent-${slug}")        best="$slug"; role="background" ;;
      "shadow-proxy-${slug}") best="$slug"; role="proxy" ;;
      agent-?*-"${slug}")     best="$slug"; role="${${name#agent-}%-${slug}}" ;;
    esac
  done < "$REGISTRY"
  [[ -n "$best" ]] || return 1
  REPLY_SLUG="$best"; REPLY_ROLE="$role"
}

# Look up a registered workspace by exact slug.
# On success sets: REPLY_SLUG, REPLY_ROOT, REPLY_DISTRO, REPLY_NETWORK
_registry_lookup_by_slug() {
  local search_slug="$1"
  _registry_init
  local line slug abspath distro network
  while IFS='|' read -r slug abspath distro network; do
    [[ -z "$slug" || "$slug" == \#* ]] && continue
    if [[ "$search_slug" == "$slug" ]]; then
      REPLY_SLUG="$slug"
      REPLY_ROOT="$abspath"
      REPLY_DISTRO="$distro"
      REPLY_NETWORK="${network:-shadow-net}"
      return 0
    fi
  done < "$REGISTRY"
  return 1
}

# Resolves workspace by argument (slug or directory path) or current working directory.
_resolve_workspace_target() {
  local target="${1:-}"
  if [[ -n "$target" ]]; then
    if _registry_lookup_by_slug "$target"; then
      return 0
    elif [[ -d "$target" ]] && _registry_lookup "${target:A}"; then
      return 0
    fi
    _die "Target '${target}' is not a registered workspace (neither matching slug nor path).\n  Run 'agent-shadow list' to view registered workspaces."
  fi

  if ! _registry_lookup "${PWD:A}"; then
    _die "Current directory is not within a registered workspace.\n  To register: agent-shadow register .\n  To view registered: agent-shadow list"
  fi
  return 0
}
