#!/usr/bin/env sh
# Asks three questions and writes .env from .env.example with fresh secrets.
# It never overwrites an existing .env: regenerating FERNET_KEY would make
# every saved connector credential undecryptable.
set -eu

cd "$(dirname "$0")"

if [ -e .env ]; then
  echo "setup.sh: .env already exists; refusing to overwrite it." >&2
  echo "Edit .env by hand, or move it away first if you really want a fresh one." >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || {
  echo "setup.sh: openssl is required to generate secrets." >&2
  exit 1
}

token() { openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n'; }
fernet_key() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n'; }

ask() {
  printf '%s ' "$1" >&2
  read -r answer
  printf '%s' "$answer"
}

echo
echo "1/3  Address"
echo "     The domain (data.example.com) or server IP (203.0.113.10) people"
echo "     will type in their browser. No http://, no port."
address=""
while [ -z "$address" ]; do
  address="$(ask '     Address:')"
  case "$address" in
    *://* | */* | *:* | *" "*)
      echo "     Only the bare domain or IP, please." >&2
      address=""
      ;;
  esac
done

echo
echo "2/3  How should people connect?"
echo "     1) HTTPS, set up for me   (recommended; needs ports 80 and 443 free)"
echo "     2) HTTP, no encryption    (only on a private, trusted network)"
echo "     3) HTTPS through my own reverse proxy or tunnel"
web=""
while :; do
  web="$(ask '     Choice [1]:')"
  case "${web:-1}" in
    1) compose_files="docker-compose.yml:docker-compose.https.yml"; scheme=https; break ;;
    2) compose_files="docker-compose.yml:docker-compose.http.yml"; scheme=http; break ;;
    3) compose_files="docker-compose.yml"; scheme=https; break ;;
  esac
done
web="${web:-1}"

echo
echo "3/3  Database"
echo "     1) Bundled PostgreSQL on this server   (simplest)"
echo "     2) My own managed PostgreSQL           (AWS RDS, Cloud SQL, Neon, ...)"
while :; do
  db="$(ask '     Choice [1]:')"
  case "${db:-1}" in
    1)
      V_POSTGRES_PASSWORD="$(openssl rand -hex 24)"
      V_DATABASE_URL="postgresql+psycopg://datamoov:${V_POSTGRES_PASSWORD}@db:5432/datamoov?sslmode=require"
      compose_files="${compose_files}:docker-compose.localdb.yml"
      break
      ;;
    2)
      echo "     Paste the connection URL. It must end with ?sslmode=require"
      echo "     (or verify-ca / verify-full), for example:"
      echo "     postgresql+psycopg://USER:PASSWORD@HOST:5432/DATABASE?sslmode=require"
      V_DATABASE_URL="$(ask '     URL:')"
      case "$V_DATABASE_URL" in
        postgres://*) V_DATABASE_URL="postgresql+psycopg://${V_DATABASE_URL#postgres://}" ;;
        postgresql://*) V_DATABASE_URL="postgresql+psycopg://${V_DATABASE_URL#postgresql://}" ;;
      esac
      case "$V_DATABASE_URL" in
        postgresql+psycopg://*sslmode=require* | postgresql+psycopg://*sslmode=verify-ca* | postgresql+psycopg://*sslmode=verify-full*)
          V_POSTGRES_PASSWORD=""
          break
          ;;
      esac
      echo "     That URL is not a PostgreSQL URL with an accepted sslmode." >&2
      ;;
  esac
done

export V_DATABASE_URL V_POSTGRES_PASSWORD
export V_COMPOSE_FILE="$compose_files"
export V_ALLOWED_HOSTS="$address"
export V_CORS_ORIGINS="${scheme}://${address}"
export V_CSRF_TRUSTED_ORIGINS="${scheme}://${address}"
export V_PLATFORM_PUBLIC_URL="${scheme}://${address}"
export V_MCP_ALLOWED_ORIGINS="[\"${scheme}://${address}\"]"
export V_DATAMOOV_SITE_ADDRESS=""
export V_EDGE_HTTP_BIND_HOST="127.0.0.1"
[ "$web" = 1 ] && V_DATAMOOV_SITE_ADDRESS="$address"
[ "$web" = 2 ] && V_EDGE_HTTP_BIND_HOST="0.0.0.0"
V_SECRET_KEY="$(token)"
V_FERNET_KEY="$(fernet_key)"
V_QUERY_RUNNER_CREDENTIAL_KEY="$(fernet_key)"
V_INTERNAL_API_TOKEN="$(token)"
V_BOOTSTRAP_TOKEN="$(token)"
export V_SECRET_KEY V_FERNET_KEY V_QUERY_RUNNER_CREDENTIAL_KEY V_INTERNAL_API_TOKEN V_BOOTSTRAP_TOKEN

# Values come from the environment, never from sed patterns, so a database
# password may contain any character.
umask 077
awk '
  /^[A-Z_]+=/ {
    key = substr($0, 1, index($0, "=") - 1)
    if (("V_" key) in ENVIRON) { print key "=" ENVIRON["V_" key]; next }
  }
  { print }
' .env.example > .env

cat <<EOF

Created .env (readable only by you).

  Address:  ${scheme}://${address}
  Runs:     ${compose_files}

One-time setup token, needed once in the browser after the first start:

  ${V_BOOTSTRAP_TOKEN}

Back up .env somewhere safe. Without its FERNET_KEY, saved connector
credentials can never be decrypted again.

Next:  docker compose pull  &&  docker compose up -d --wait --wait-timeout 900
EOF
