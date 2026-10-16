#!/usr/bin/env bash
# Shared by the production installer and its rootless regression tests.

loom_write_update_channel() {
  local home="$1" repository="$2" branch="$3" source_dir="$4" env_path tmp value
  for value in "$repository" "$branch" "$source_dir"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  done
  env_path="$home/deploy/.env"
  [[ -f "$env_path" && ! -L "$env_path" ]] || return 1
  tmp="$(mktemp "$home/deploy/.loom-update-env.XXXXXX")" || return 1
  if ! cp --preserve=mode,ownership -- "$env_path" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  # The Manager prefers these explicit values over .loom-update-state.
  # Rewrite only channel metadata, preserving all production secret lines.
  if ! LOOM_SELECTED_REPOSITORY="$repository" LOOM_SELECTED_BRANCH="$branch" \
    LOOM_SELECTED_SOURCE_DIR="$source_dir" awk '
      BEGIN {
        keys[1]="LOOM_UPDATE_REPOSITORY"
        keys[2]="LOOM_UPDATE_BRANCH"
        keys[3]="LOOM_UPDATE_SOURCE_DIR"
        values[keys[1]]=ENVIRON["LOOM_SELECTED_REPOSITORY"]
        values[keys[2]]=ENVIRON["LOOM_SELECTED_BRANCH"]
        values[keys[3]]=ENVIRON["LOOM_SELECTED_SOURCE_DIR"]
      }
      {
        key=$0
        sub(/=.*/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        if (key in values) {
          if (!(key in seen)) print key "=" values[key]
          seen[key]=1
          next
        }
        print
      }
      END {
        for (i=1; i<=3; i++) {
          key=keys[i]
          if (!(key in seen)) print key "=" values[key]
        }
      }
    ' "$env_path" >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$env_path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

loom_write_install_state() {
  local home="$1" repository="$2" branch="$3" source_dir="$4" commit="$5" version="$6" tmp value
  for value in "$repository" "$branch" "$source_dir" "$commit" "$version"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  done
  [[ -z "$commit" || "$commit" =~ ^[a-fA-F0-9]{40}$ ]] || return 1
  mkdir -p "$home"
  tmp="$(mktemp "$home/.loom-update-state.XXXXXX")" || return 1
  chmod 0600 "$tmp"
  printf '%s\n' "installed_version=$version" "installed_commit=$commit" \
    "repository=$repository" "branch=$branch" "source_dir=$source_dir" >"$tmp"
  mv -f "$tmp" "$home/.loom-update-state"
}

loom_install_manager_binary() {
  local source="$1" target="$2" staged
  staged="$(mktemp "${target}.XXXXXX")" || return 1
  # Replacing the directory entry lets a running TUI finish safely; copying
  # over its executable can fail with ETXTBSY or leave a partially written file.
  if ! install -m 0755 "$source" "$staged"; then
    rm -f "$staged"
    return 1
  fi
  mv -f "$staged" "$target"
}
