#!/usr/bin/env bash
# Generate the self-signed TLS certificate the compose ingress serves for
# $DOMAIN. Stands in for cert-manager, which only exists on the k8s path.
#
# Idempotent: re-running is a no-op while the existing cert still matches
# $DOMAIN and isn't about to expire. Pass -f to force a new one.
#
# Output (gitignored - it's a private key):
#   _scripts/proxy/certs/tls.crt
#   _scripts/proxy/certs/tls.key
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
certs="$here/certs"
force=false

usage() {
  cat <<EOF
Usage: ${0##*/} [-f] [-h]

  -f  regenerate even if a valid cert for \$DOMAIN already exists
  -h  show this help

Reads DOMAIN from $repo_root/.env (default: ping-local.test.bbl).
EOF
}

while getopts ':fh' opt; do
  case "$opt" in
    f) force=true ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

if [ -f "$repo_root/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$repo_root/.env"
  set +a
fi
DOMAIN="${DOMAIN:-ping-local.test.bbl}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "error: openssl not found on PATH" >&2
  exit 1
fi

if [ "$force" = false ] && [ -f "$certs/tls.crt" ] && [ -f "$certs/tls.key" ]; then
  # -checkend 604800: still valid a week from now, so a soon-to-expire cert
  # gets replaced before it breaks a running stack.
  if openssl x509 -in "$certs/tls.crt" -noout -checkend 604800 >/dev/null 2>&1 &&
     openssl x509 -in "$certs/tls.crt" -noout -ext subjectAltName 2>/dev/null |
       grep -q "DNS:$DOMAIN"; then
    echo "cert for $DOMAIN already valid: $certs/tls.crt (use -f to replace)"
    exit 0
  fi
fi

mkdir -p "$certs"
echo "generating self-signed cert for $DOMAIN ..."
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout "$certs/tls.key" \
  -out "$certs/tls.crt" \
  -subj "/O=forgeops-compose/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" \
  2>/dev/null

# Readable by the traefik container (it does not run as root).
chmod 644 "$certs/tls.crt" "$certs/tls.key"

echo "wrote $certs/tls.crt"
echo
echo "Next: point $DOMAIN at the proxy, then start the stack:"
echo "  echo '127.0.0.1 $DOMAIN' | sudo tee -a /etc/hosts"
echo "  docker compose up -d"
echo
echo "The cert is self-signed - browsers will warn. Trust $certs/tls.crt,"
echo "or use 'curl -k'. On WSL2 browsing from Windows, add the hosts entry"
echo "and trust the cert on the Windows side too."
