#!/bin/sh
# /usr/local/bin/rm — catches accidental recursive deletes of /, /root and /workspace.
# Not a security control: /bin/rm, find -delete etc. bypass it.
IS_RECURSIVE=0
for arg in "$@"; do
  case "$arg" in
    -r|-R|-rf|-fr|-rfi|-fir|-rI|--recursive)
      IS_RECURSIVE=1 ;;
    -[!-]*)
      case "$arg" in *r*|*R*) IS_RECURSIVE=1 ;; esac ;;
  esac
done
if [ "$IS_RECURSIVE" -eq 1 ]; then
  for arg in "$@"; do
    p="$arg"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    case "$p" in */.) p="${p%/.}"; [ -z "$p" ] && p=/ ;; esac
    # Only the roots themselves, and literal unexpanded globs ("/root/*"); quoted so
    # that /* is NOT a pattern matching every absolute path.
    case "$p" in
      /|/root|/workspace|"$HOME"|"~"|"/*"|"/root/*"|"/workspace/*"|"$HOME/*"|"~/*")
        printf "\033[1;31m🔴 [agent-shadow guardrail]\033[0m Blocked destructive recursive rm on: %s\n" "$arg" >&2
        printf "   To protect your workspace and persistent state, recursive deletion of root mount points is forbidden.\n" >&2
        printf "   Use \033[1magent-shadow wash\033[0m on the host to cleanly reset workspace state.\n" >&2
        exit 1 ;;
      .)
        cwd="$(pwd 2>/dev/null || true)"
        case "$cwd" in
          /|/root|/workspace|"$HOME")
            printf "\033[1;31m🔴 [agent-shadow guardrail]\033[0m Blocked destructive recursive rm in: %s\n" "$cwd" >&2
            printf "   Use \033[1magent-shadow wash\033[0m on the host to cleanly reset workspace state.\n" >&2
            exit 1 ;;
        esac ;;
    esac
  done
fi
exec /bin/rm "$@"
