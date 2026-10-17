#!/usr/bin/env bash
# Explicit local HTTPS certificates, independent of Node identity and release keys.
loom_tls_name_kind() {
  local name="$1" octet
  if [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    local -a octets
    IFS=. read -r -a octets <<< "$name"
    for octet in "${octets[@]}"; do
      [[ ${#octet} -le 3 && ( "$octet" == 0 || "$octet" != 0* ) ]] && ((10#$octet <= 255)) || return 2
    done
    printf IP
  elif [[ ${#name} -le 253 && "$name" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$name" != *..* ]]; then
    printf DNS
  else
    echo 'Enter a hostname or IPv4 address without a scheme, port or path.' >&2
    return 2
  fi
}

loom_local_certificate() (
  set -euo pipefail
  local directory="$1" host="$2" kind stage
  kind="$(loom_tls_name_kind "$host")" || return
  [[ ! -L "$directory" ]] || { echo 'Refusing symlinked TLS directory.' >&2; return 2; }
  umask 077
  mkdir -p -- "$directory"
  chmod 0700 "$directory"
  if [[ -e "$directory/fullchain.pem" || -e "$directory/privkey.pem" ]]; then
    [[ -s "$directory/fullchain.pem" && -s "$directory/privkey.pem" && ! -L "$directory/fullchain.pem" && ! -L "$directory/privkey.pem" ]] || {
      echo 'Incomplete local TLS material; refusing to replace it.' >&2; return 2;
    }
    local option=-verify_hostname
    [[ "$kind" != IP ]] || option=-verify_ip
    openssl x509 -in "$directory/fullchain.pem" -noout -checkend 0 >/dev/null
    openssl verify -CAfile "$directory/fullchain.pem" "$option" "$host" "$directory/fullchain.pem" >/dev/null
    [[ "$(openssl x509 -in "$directory/fullchain.pem" -pubkey -noout)" == "$(openssl pkey -in "$directory/privkey.pem" -pubout 2>/dev/null)" ]] || {
      echo 'Local TLS certificate/key mismatch; refusing replacement.' >&2; return 2;
    }
    return
  fi
  stage="$(mktemp -d "$directory/.issue.XXXXXXXX")"
  trap 'rm -rf -- "$stage"' EXIT
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
    -subj '/CN=Loom Local HTTPS' \
    -addext "subjectAltName=$kind:$host" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
    -addext 'extendedKeyUsage=serverAuth' \
    -keyout "$stage/privkey.pem" -out "$stage/fullchain.pem" >/dev/null 2>&1
  chmod 0600 "$stage/privkey.pem"
  chmod 0644 "$stage/fullchain.pem"
  mv -- "$stage/privkey.pem" "$directory/privkey.pem"
  mv -- "$stage/fullchain.pem" "$directory/fullchain.pem"
)
