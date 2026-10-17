#!/usr/bin/env bash
set -euo pipefail

# This bootstrap must itself be obtained through a trusted channel. The archive
# digest and revision must come from authenticated release/operator metadata,
# never from a checksum downloaded beside an untrusted artifact.
REPOSITORY="${LOOM_REPOSITORY:-0800x/Loom}"
REF="${LOOM_REF:-}"
EXPECTED_SHA256="${LOOM_SOURCE_SHA256:-}"
[[ "$REPOSITORY" == '0800x/Loom' ]] || { echo 'Unapproved repository' >&2; exit 2; }
[[ "$REF" =~ ^[a-f0-9]{40}$ ]] || { echo 'LOOM_REF must be an immutable full commit SHA' >&2; exit 2; }
[[ "$EXPECTED_SHA256" =~ ^[a-f0-9]{64}$ ]] || { echo 'LOOM_SOURCE_SHA256 is required from a trusted release channel' >&2; exit 2; }
# The root path uses the same isolated Git configuration and root-private
# verification as sudo. No hooks or downloaded code run during acquisition.
preview=0
entry=install-production.sh
if [[ "${1:-}" == --wizard ]]; then entry=setup.sh; shift; fi
if [[ "${1:-}" == --preview-wizard ]]; then entry=setup.sh; preview=1; shift; fi
if [[ "${1:-}" == --diagnose ]]; then entry=diagnose-node.sh; shift; fi
for tool in git sha256sum tar; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; run the top-level install.sh bootstrap." >&2; exit 2; }
done
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
git_env=(env -i PATH=/usr/bin:/bin HOME="$TMP_DIR" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0)
token="${LOOM_UPDATE_GITHUB_TOKEN:-}"
if [[ -n "$token" ]]; then
  [[ ${#token} -ge 20 && ${#token} -le 512 && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || exit 2
  git_env+=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader "GIT_CONFIG_VALUE_0=Authorization: Basic $(printf 'x-access-token:%s' "$token" | /usr/bin/base64 -w0)")
fi
git_safe=(-c core.hooksPath=/dev/null -c protocol.file.allow=never -c protocol.ext.allow=never -c credential.helper=)
"${git_env[@]}" /usr/bin/git "${git_safe[@]}" init -q "$TMP_DIR/source"
"${git_env[@]}" /usr/bin/git "${git_safe[@]}" -C "$TMP_DIR/source" fetch --quiet --depth=1 "https://github.com/$REPOSITORY.git" "$REF"
"${git_env[@]}" /usr/bin/git "${git_safe[@]}" -C "$TMP_DIR/source" archive --format=tar "$REF" > "$TMP_DIR/source.tar"
actual="$(/usr/bin/sha256sum "$TMP_DIR/source.tar")"
[[ "${actual%% *}" == "$EXPECTED_SHA256" ]] || { echo 'Release checksum mismatch' >&2; exit 1; }

if [[ $preview -eq 1 ]]; then
  mkdir "$TMP_DIR/preview"
  tar --no-same-owner --no-same-permissions -xf "$TMP_DIR/source.tar" -C "$TMP_DIR/preview"
  /bin/bash --noprofile --norc "$TMP_DIR/preview/services/loom_server/scripts/linux/setup.sh" --plan "$@"
  exit
fi

# Privileged side copies first, then verifies its own immutable private copy.
# No downloaded shell code runs until that verification succeeds.
elevate=()
[[ $EUID -eq 0 ]] || elevate=(/usr/bin/sudo)
"${elevate[@]}" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM="${TERM:-dumb}" /bin/bash --noprofile --norc -s -- "$TMP_DIR/source.tar" "$EXPECTED_SHA256" "$REF" "$entry" "$@" <<'ROOT_INSTALL'
set -euo pipefail
archive="$1"; digest="$2"; revision="$3"; entry="$4"; shift 4
[[ "$entry" == setup.sh || "$entry" == install-production.sh || "$entry" == diagnose-node.sh ]] || exit 2
[[ "$digest" =~ ^[a-f0-9]{64}$ && "$revision" =~ ^[a-f0-9]{40}$ ]] || exit 2
stage="$(mktemp -d /var/tmp/loom-release.XXXXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
umask 077
cp -- "$archive" "$stage/release.tar"
[[ "$(sha256sum "$stage/release.tar" | cut -d' ' -f1)" == "$digest" ]] || { echo 'Privileged release checksum mismatch' >&2; exit 1; }
mkdir "$stage/source"
tar --no-same-owner --no-same-permissions -xf "$stage/release.tar" -C "$stage/source"
printf '%s\n' "$revision" > "$stage/source/.loom-verified-source"
chmod 0600 "$stage/source/.loom-verified-source"
printf '%s\n' "$digest" > "$stage/source/.loom-source-sha256"
LOOM_SOURCE_COMMIT="$revision" /bin/bash --noprofile --norc "$stage/source/services/loom_server/scripts/linux/$entry" "$@"
ROOT_INSTALL
