#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
ACTION="${2:-encrypt}"
SOPS_CONFIG="${SOPS_CONFIG:-.sops.yaml}"

if ! command -v sops >/dev/null 2>&1; then
  echo "sops is required but not installed."
  exit 1
fi

if [[ ! -f "${SOPS_CONFIG}" ]]; then
  echo "Missing SOPS config at ${SOPS_CONFIG}."
  exit 1
fi

encrypt_files() {
  local found=0

  # Dotenv files
  while IFS= read -r -d '' file; do
    found=1
    sops --config "${SOPS_CONFIG}" --input-type dotenv --output-type dotenv -e "${file}" > "${file}.enc"
    echo "Encrypted ${file} -> ${file}.enc"
  done < <(
    find "${ROOT_DIR}" -type f \( -name ".env.*.local" -o -name ".env" \) \
      ! -name "*.enc" \
      ! -name "*.example" \
      ! -path "*/.git/*" \
      ! -path "*/node_modules/*" \
      -print0
  )

  # Cloudflared credentials JSON files
  while IFS= read -r -d '' file; do
    found=1
    sops --config "${SOPS_CONFIG}" --input-type json --output-type json -e "${file}" > "${file}.enc"
    echo "Encrypted ${file} -> ${file}.enc"
  done < <(
    find "${ROOT_DIR}" -type f -name "credentials.json" \
      ! -name "*.enc" \
      ! -name "*.example" \
      ! -path "*/.git/*" \
      ! -path "*/node_modules/*" \
      -print0
  )

  if [[ ${found} -eq 0 ]]; then
    echo "No plaintext files (.env or cloudflared credentials.json) found under ${ROOT_DIR}."
  fi
}

decrypt_files() {
  local found=0

  # Dotenv files
  while IFS= read -r -d '' file; do
    found=1
    sops --config "${SOPS_CONFIG}" --input-type dotenv --output-type dotenv -d "${file}" > "${file%.enc}"
    echo "Decrypted ${file} -> ${file%.enc}"
  done < <(
    find "${ROOT_DIR}" -type f \( -name ".env.*.local.enc" -o -name ".env.enc" \) \
      ! -path "*/.git/*" \
      ! -path "*/node_modules/*" \
      -print0
  )

  # Cloudflared credentials JSON files
  while IFS= read -r -d '' file; do
    found=1
    sops --config "${SOPS_CONFIG}" --input-type json --output-type json -d "${file}" > "${file%.enc}"
    echo "Decrypted ${file} -> ${file%.enc}"
  done < <(
    find "${ROOT_DIR}" -type f -name "credentials.json.enc" \
      ! -path "*/.git/*" \
      ! -path "*/node_modules/*" \
      -print0
  )

  if [[ ${found} -eq 0 ]]; then
    echo "No encrypted files (.env*.enc or cloudflared credentials.json.enc) found under ${ROOT_DIR}."
  fi
}

case "${ACTION}" in
  encrypt)
    encrypt_files
    ;;
  decrypt)
    decrypt_files
    ;;
  *)
    echo "Usage: $0 [root-dir] [encrypt|decrypt]"
    exit 1
    ;;
esac
