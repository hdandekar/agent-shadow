# image.zsh — builds agent-shadow's images from lib/agent-shadow/image/ and tells when one is
# older than its template.
#
# The base image is image/Containerfile plus the user's ~/.config/agent-shadow/Dockerfile.<distro>.append,
# inserted at the marker line. Pins (BASE_IMAGE_SHA, MISE_VERSION, MISE_SHA256_LINUX_ARM64) are passed
# as build arguments. After a build, the template's hash is stored per image tag; `run`, `start`,
# `doctor` and `init` warn (never rebuild) when the template has changed since.

typeset -g IMAGE_SRC="${${(%):-%x}:A:h}/image"
typeset -g IMAGE_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-shadow/images"
typeset -g IMAGE_APPEND_MARKER='# --- Dockerfile.<distro>.append is inserted here ---'

_base_tag()     { print -r -- "${AGENT_SHADOW_IMAGE_PREFIX}-base:$1"; }
_append_file()  { print -r -- "${CONF_DIR}/Dockerfile.$1.append"; }

# _image_exists <name:tag> : the image is in the local store (NAME may carry a registry prefix)
_image_exists() {
  command container image ls 2>/dev/null | awk -v n="${1%%:*}" -v t="${1##*:}" '
    NR == 1 && $1 ~ /^[A-Z]+$/ { next }
    ($1 == n || $1 ~ ("/" n "$")) && $2 == t { found = 1 }
    END { exit !found }'
}

# _image_context <distro|proxy> <dir> : write the build context (Containerfile + scripts) to <dir>
_image_context() {
  local name="$1" dir="$2" line append
  rm -rf "$dir"; mkdir -p "$dir"
  if [[ "$name" == proxy ]]; then
    cp "${IMAGE_SRC}/proxy.Containerfile" "${dir}/Containerfile"
    return 0
  fi
  cp "${IMAGE_SRC}"/{profile.sh,rm-guard.sh,entrypoint.sh,traffic-monitor.sh,traffic-filter.awk} "$dir/"
  append="$(_append_file "$name")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$IMAGE_APPEND_MARKER" ]]; then
      [[ -f "$append" ]] || continue
      print -r -- "# --- from ${append} ---"
      cat "$append"; print
    else
      print -r -- "$line"
    fi
  done < "${IMAGE_SRC}/Containerfile" > "${dir}/Containerfile"
}

# _image_build_args <distro|proxy> : --build-arg list (sets reply)
_image_build_args() {
  local d="$1"; [[ "$d" == proxy ]] && d=ubuntu24
  local base="${BASE_IMAGE[$d]}"
  [[ -n "${BASE_IMAGE_SHA[$d]:-}" ]] && base="${base}@${BASE_IMAGE_SHA[$d]}"
  reply=(--build-arg "BASE_IMAGE=${base}")
  [[ "$1" == proxy ]] || reply+=(--build-arg "MISE_VERSION=${MISE_VERSION}" --build-arg "MISE_SHA256=${MISE_SHA256_LINUX_ARM64}")
}

# _image_template_hash <distro|proxy> : SHA-256 of everything the build would use
_image_template_hash() {
  local ctx; ctx="$(mktemp -d "${TMPDIR:-/tmp}/agent-shadow-ctx.XXXXXX")"
  _image_context "$1" "$ctx"
  _image_build_args "$1"
  local f
  { for f in "$ctx"/*(N.on); do print -r -- "== ${f:t}"; cat "$f"; done; print -r -- "${reply[*]}"; } \
    | if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | awk '{print $1}'
  rm -rf "$ctx"
}

_image_stamp_file() { print -r -- "${IMAGE_STATE_DIR}/${1//[:\/]/_}.template"; }

# _image_is_current <distro|proxy> <tag> : built by agent-shadow from the current template
_image_is_current() {
  local stamp; stamp="$(_image_stamp_file "$2")"
  [[ -f "$stamp" && "$(<"$stamp")" == "$(_image_template_hash "$1")" ]]
}

# _image_warn_if_stale <distro|proxy> <tag> : one warning line; never rebuilds
_image_warn_if_stale() {
  _image_is_current "$1" "$2" && return 0
  local how="agent-shadow init --force" why="agent-shadow was updated"
  if [[ "$1" != proxy ]]; then
    how+=" --distro $1"; why+=", or $(_append_file "$1") changed"
  fi
  _warn "Image '$2' was built from an older template (${why})."
  _warn "  It still works; to use the new template: ${how}"
  return 0
}

# _image_ensure <distro|proxy> <tag> <force> : build if missing (or forced), then record the template
_image_ensure() {
  local name="$1" tag="$2" force="${3:-0}"
  if _image_exists "$tag" && (( ! force )); then
    _ok "Image '${tag}' is already built."
    _image_warn_if_stale "$name" "$tag"
    return 0
  fi
  local ctx="${CONF_DIR}/build/${name}"
  _image_context "$name" "$ctx"
  [[ "$name" != proxy && -f "$(_append_file "$name")" ]] && _info "Adding your layers from $(_append_file "$name")"
  _image_build_args "$name"
  _info "Building image ${tag} (the first build downloads the base image and packages; this takes a few minutes)…"
  command container build --tag "$tag" --file "${ctx}/Containerfile" "${reply[@]}" "$ctx" || \
    _die "Building '${tag}' failed (see the output above). Build files: ${ctx}"
  mkdir -p "$IMAGE_STATE_DIR"
  _image_template_hash "$name" > "$(_image_stamp_file "$tag")"
  _ok "Image '${tag}' built."
}
