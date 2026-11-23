# session.zsh — what `run` and `start` share: their options and the container arguments built
# from them. One copy, so a fix (or a test) covers both commands.

# _session_reset : clear the shared options (`connect` calls `start`, so always reset first)
_session_reset() {
  typeset -g S_DISTRO="" S_NET="" S_CPUS="$DEFAULT_CPUS" S_MEMORY="$DEFAULT_MEMORY" S_ISOLATED=0
  typeset -ga S_PUBLISH=() S_ENV=() S_ENV_FILES=()
}

# _session_opt <args…> : take one shared option; REPLY = arguments used (returns 1 if not one)
_session_opt() {
  case "$1" in
    --isolated|-i) S_ISOLATED=1; REPLY=1; return 0 ;;
    --distro|-d|--cpus|--memory|-m|--publish|-p|--network|--env|--env-file)
      (( $# >= 2 )) || _die "Option '$1' needs a value." ;;
    *) REPLY=0; return 1 ;;
  esac
  case "$1" in
    --distro|-d)  S_DISTRO="$2" ;;
    --cpus)       S_CPUS="$2" ;;
    --memory|-m)  S_MEMORY="$2" ;;
    --publish|-p) S_PUBLISH+=("$2") ;;
    --network)    S_NET="$2" ;;
    --env)        S_ENV+=("$2") ;;
    --env-file)   S_ENV_FILES+=("$2") ;;
  esac
  REPLY=2
}

# _session_network <slug> <registered-network> : the network the options ask for
_session_network() {
  if [[ -n "$S_NET" ]]; then print -r -- "$S_NET"
  elif (( S_ISOLATED )); then print -r -- "shadow-$1-net"
  else print -r -- "$2"
  fi
}

# _session_env_args : --env KEY=VAL / --env KEY / --env-file as container arguments (sets reply).
# Used for a new container and when attaching to a running one.
_session_env_args() {
  local item file line
  reply=()
  for item in "${S_ENV[@]}"; do
    if [[ "$item" == *=* ]]; then reply+=(--env "$item"); else reply+=(--env "${item}=${(P)item}"); fi
  done
  for file in "${S_ENV_FILES[@]}"; do
    [[ -f "$file" ]] || _die "Environment file not found: ${file}"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      reply+=(--env "$line")
    done < "$file"
  done
}

# _session_container_args <name> <network> <root> <slug> <distro> <workdir> : the arguments every
# new workspace container gets (sets reply). Published ports are always bound to the Mac's
# 127.0.0.1, whatever address was given.
_session_container_args() {
  local name="$1" net="$2" root="$3" slug="$4" distro="$5" workdir="$6"
  local -a a=(
    --name "$name"
    --network "$net"
    --volume "${root}:/workspace"
    --volume "home-${slug}:/root"
    --volume "${MISE_VOLUME[$distro]}:/opt/mise:ro"
    --workdir "$workdir"
    --cpus "$S_CPUS"
    --memory "$S_MEMORY"
  )
  local git_name git_email
  git_name="$(git config --global user.name 2>/dev/null || true)"
  git_email="$(git config --global user.email 2>/dev/null || true)"
  [[ -n "$git_name" ]] && a+=(--env "GIT_FALLBACK_NAME=${git_name}")
  [[ -n "$git_email" ]] && a+=(--env "GIT_FALLBACK_EMAIL=${git_email}")
  # /root/.local/bin last: user-level installs (pip --user, uv tool, install scripts) live in the
  # persistent /root volume and should be found next session, without shadowing system tools.
  a+=(--env "PATH=/opt/mise/shims:/opt/mise/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/root/.local/bin")
  a+=(--env "MISE_GLOBAL_CONFIG_FILE=/opt/mise/config.toml" --env "TERM=${TERM:-xterm-256color}")
  a+=(--env "AGENT_SHADOW_WORKSPACE=${slug}")   # shown in the shell prompt (profile.sh)
  local pub host_port container_port
  for pub in "${S_PUBLISH[@]}"; do
    case "$pub" in
      *:*:*) host_port="${pub#*:}"; host_port="${host_port%%:*}"; container_port="${pub##*:}" ;;
      *:*)   host_port="${pub%%:*}"; container_port="${pub##*:}" ;;
      *)     _die "Invalid --publish format '${pub}'. Expected HOST:CONTAINER or IP:HOST:CONTAINER." ;;
    esac
    a+=(--publish "127.0.0.1:${host_port}:${container_port}")
  done
  _session_env_args
  reply=("${a[@]}" "${reply[@]}")
}
