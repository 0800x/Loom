#!/usr/bin/env bash
set -euo pipefail

# Manual migration for a legacy Manager that cannot install verified releases.
# The operator supplies an independently trusted full commit, never a branch.
# Normal unattended discovery still uses /etc/loom/approved-releases.
revision="${1:-}"
[[ $# -eq 1 && "$revision" =~ ^[a-f0-9]{40}$ ]] || {
  echo 'Usage: repair-update.sh TRUSTED_FULL_COMMIT_SHA' >&2; exit 2;
}
[[ $EUID -eq 0 ]] || { echo 'Run this installed recovery helper as root' >&2; exit 2; }
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
unset BASH_ENV ENV CDPATH GLOBIGNORE
token_file='/opt/loom-node/.loom-update-token'
[[ -f "$token_file" && ! -L "$token_file" ]] || {
  echo 'Saved Node Manager update token is missing; no credentials were changed' >&2; exit 1;
}
[[ "$(stat -c %u "$token_file")" == 0 ]] || exit 1
token="$(cat "$token_file")"
[[ ${#token} -ge 20 && ${#token} -le 512 && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || exit 1
header="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 -w0)"
unset token
download="$(mktemp -d /var/tmp/loom-repair-download.XXXXXXXX)"
stage="$(mktemp -d /var/tmp/loom-repair-install.XXXXXXXX)"
trap 'rm -rf -- "$download" "$stage"' EXIT
chmod 700 "$download" "$stage"
chown 65534:65534 "$download"

# No token in command arguments, Git helpers, root network process or user hooks.
printf '%s\n' "$header" | /usr/sbin/runuser -u nobody -- \
  /usr/bin/env -i PATH=/usr/bin:/bin HOME="$download" \
  /bin/bash --noprofile --norc -c '
    set -euo pipefail
    IFS= read -r header
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
    export GIT_CONFIG_VALUE_0="$header"
    unset header
    git_safe() {
      /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        -c credential.helper= -c protocol.file.allow=never -c protocol.ext.allow=never "$@"
    }
    git_safe init -q "$1/repo"
    git_safe -C "$1/repo" fetch --quiet --depth=1 https://github.com/0800x/Loom.git "$2"
    [[ "$(git_safe -C "$1/repo" rev-parse FETCH_HEAD)" == "$2" ]]
  ' loom-recovery "$download" "$revision"
unset header

# Freeze the downloaded objects in a root-private directory. Verify object
# integrity offline and derive the canonical archive from the operator's pin.
cp -a "$download/repo" "$stage/repo"
chown -R 0:0 "$stage/repo"
offline_git() {
  /usr/bin/env -i PATH=/usr/bin:/bin HOME=/nonexistent \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c credential.helper= -c protocol.file.allow=never -c protocol.ext.allow=never \
    -C "$stage/repo" "$@"
}
offline_git fsck --strict
actual_commit="$(offline_git cat-file commit "$revision" | offline_git hash-object -t commit --stdin)"
[[ "$actual_commit" == "$revision" ]] || { echo 'Pinned commit integrity check failed' >&2; exit 1; }
offline_git archive --format=tar --output="$stage/release.tar" "$revision"
mkdir "$stage/source"
tar --no-same-owner --no-same-permissions -xf "$stage/release.tar" -C "$stage/source"
printf '%s\n' "$revision" > "$stage/source/.loom-verified-source"
chmod 600 "$stage/source/.loom-verified-source"

/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  LOOM_SOURCE_COMMIT="$revision" \
  /bin/bash --noprofile --norc \
  "$stage/source/services/loom_server/scripts/linux/install-production.sh" \
  --update-branch main --update-repository 0800x/Loom \
  --update-source-dir '' --proxy auto --skip-dns-check --no-tui
