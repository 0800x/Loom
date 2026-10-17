#!/usr/bin/env bash
loom_require_install_path() {
  local value="$1" canonical
  [[ "$value" == /opt/loom-node ]] || { echo 'Unsafe/unapproved installation path' >&2; return 1; }
  [[ ! -L /opt && ! -L "$value" ]] || return 1
  canonical="$(realpath -m -- "$value")" || return 1
  [[ "$canonical" == /opt/loom-node ]] || return 1
}
loom_require_root_owned() {
  local path="$1" mode uid
  [[ -e "$path" && ! -L "$path" ]] || return 1
  uid="$(stat -c %u -- "$path")" || return 1
  mode="$(stat -c %a -- "$path")" || return 1
  [[ "$uid" == 0 ]] && (( (8#$mode & 0022) == 0 ))
}
loom_require_install_owner() {
  local path="$1"
  loom_require_install_path "$path" || return 1
  loom_require_root_owned /opt && loom_require_root_owned "$path" &&
    loom_require_root_owned "$path/.loom-install-owner" || return 1
  [[ -f "$path/.loom-install-owner" ]] || return 1
  [[ "$(cat "$path/.loom-install-owner")" == 'loom-install-v1:/opt/loom-node' ]] || return 1
}
