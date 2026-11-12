#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Internal launcher: <own bun wrapper> <bootstrap.mjs> <main.ts> [arguments...].
# bun-purifier host-runtime dispatcher
set -euo pipefail

own_wrapper=$1
bootstrap=$2
main=$3
shift 3

is_purifier_wrapper() {
  local candidate=$1 magic='' line='' count=0
  IFS= read -r -N 2 magic < "$candidate" || true
  [[ $magic == '#!' ]] || return 1
  while IFS= read -r line && (( count < 128 )); do
    case "$line" in
      *'export BUN_PURIFIER_TOOL_WRAPPER='*|*'bun-purifier host-runtime dispatcher'*) return 0 ;;
    esac
    count=$((count + 1))
  done < "$candidate"
  return 1
}

remaining=${PATH-}
while :; do
  case "$remaining" in
    *:*) directory=${remaining%%:*}; remaining=${remaining#*:}; more=1 ;;
    *) directory=$remaining; more=0 ;;
  esac
  candidate="${directory:-.}/bun"
  if [[ -f $candidate && -x $candidate && ! $candidate -ef $own_wrapper ]] &&
    ! is_purifier_wrapper "$candidate"; then
    exec "$candidate" "$bootstrap" "$main" "$@"
  fi
  [[ $more == 1 ]] || break
done

echo 'bun-purifier: no existing Bun runtime found on PATH (purifier tool wrappers were skipped). Put your Bun runtime on PATH before local capture or prefetch.' >&2
exit 127
