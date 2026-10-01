#!/bin/sh
# Create .env with fresh S3 keys and the on-disk directories.
set -eu
cd "$(dirname "$0")/.."

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to generate S3 keys." >&2
  exit 1
fi

if [ ! -f .env ]; then
  access="$(openssl rand -hex 16)"
  secret="$(openssl rand -hex 32)"
  admin_password="$(openssl rand -hex 24)"
  cat > .env <<EOF
DATA_DIR=./data
S3_BIND=127.0.0.1
S3_PORT=8333
ADMIN_BIND=127.0.0.1
ADMIN_PORT=23646
WEED_ADMIN_USER=admin
WEED_ADMIN_PASSWORD=${admin_password}
S3_ACCESS_KEY=${access}
S3_SECRET_KEY=${secret}
VOLUME_SIZE_LIMIT_MB=10240
MASTER_MEMORY_LIMIT=1g
VOLUME_MEMORY_LIMIT=4g
FILER_MEMORY_LIMIT=2g
EOF
  chmod 600 .env
  echo "Wrote .env. Point DATA_DIR at a dedicated disk before the first start."
else
  echo ".env already exists; left existing keys unchanged."
  if ! grep -q '^WEED_ADMIN_PASSWORD=.' .env; then
    admin_password="$(openssl rand -hex 24)"
    printf '\nADMIN_BIND=%s\nADMIN_PORT=23646\nWEED_ADMIN_USER=admin\nWEED_ADMIN_PASSWORD=%s\n' \
      "$(grep '^S3_BIND=' .env | cut -d= -f2- || echo 127.0.0.1)" \
      "${admin_password}" >> .env
    echo "Added a Web UI password to .env."
  fi
fi

# shellcheck disable=SC1091
. ./.env

mkdir -p "${DATA_DIR}/master" "${DATA_DIR}/volume" "${DATA_DIR}/filer" "${DATA_DIR}/config" "${DATA_DIR}/admin"
echo "Data directories are under ${DATA_DIR}."
echo "Next: docker compose up -d"
