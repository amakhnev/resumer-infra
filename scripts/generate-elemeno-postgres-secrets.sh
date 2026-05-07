#!/usr/bin/env bash
set -euo pipefail

SOPS_CONFIG="${SOPS_CONFIG:-.sops.yaml}"
TARGET_FILE="${1:-elemeno-dev/secrets/postgres.secrets.sops.yaml}"
TMP_FILE="$(mktemp)"

cleanup() {
  rm -f "${TMP_FILE}"
}
trap cleanup EXIT

if ! command -v sops >/dev/null 2>&1; then
  echo "sops is required but not installed."
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required but not installed."
  exit 1
fi

if [[ ! -f "${SOPS_CONFIG}" ]]; then
  echo "Missing SOPS config at ${SOPS_CONFIG}."
  exit 1
fi

mkdir -p "$(dirname "${TARGET_FILE}")"

APP_PASSWORD="$(openssl rand -base64 48 | tr -d '\n' | tr -d '=+/')"
ROOT_PASSWORD="$(openssl rand -base64 48 | tr -d '\n' | tr -d '=+/')"

cat > "${TMP_FILE}" <<EOF
postgres_app_password: "${APP_PASSWORD}"
postgres_root_password: "${ROOT_PASSWORD}"
EOF

sops --config "${SOPS_CONFIG}" --filename-override "${TARGET_FILE}" --input-type yaml --output-type yaml -e "${TMP_FILE}" > "${TARGET_FILE}"

echo "Generated encrypted Postgres secrets at ${TARGET_FILE}"
