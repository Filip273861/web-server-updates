#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://raw.githubusercontent.com/GeorgiKatushev/web-server-updates/main"
WEB_SERVER="172.16.1.10"
WEB_PATH="/var/www/html"
DEPLOY_USER="student"
WORKDIR="${HOME}/update-workdir"
PUBLIC_KEY_PATH="${HOME}/public.key"

log() {
  echo "[+] $1"
}

fail() {
  echo "[!] $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

cleanup() {
  rm -rf "${WORKDIR}/extracted"
}
trap cleanup EXIT

require_cmd curl
require_cmd wget
require_cmd gpg
require_cmd unzip
require_cmd clamscan
require_cmd scp

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "=============================="
echo " AUTO SECURE UPDATE PIPELINE "
echo "=============================="

log "Checking latest version..."
LATEST="$(curl -fsSL "${REPO_URL}/latest.txt")" || fail "Failed to fetch latest version"
[[ -n "${LATEST}" ]] || fail "Latest version is empty"

echo "Latest version: ${LATEST}"

UPDATE_ZIP="${LATEST}.zip"
UPDATE_SIG="${LATEST}.sig"

log "Downloading update files..."
rm -f "$UPDATE_ZIP" "$UPDATE_SIG"

wget -q -O "$UPDATE_ZIP" "${REPO_URL}/${UPDATE_ZIP}" || fail "Failed to download ${UPDATE_ZIP}"
wget -q -O "$UPDATE_SIG" "${REPO_URL}/${UPDATE_SIG}" || fail "Failed to download ${UPDATE_SIG}"

[[ -f "$UPDATE_ZIP" ]] || fail "ZIP file missing after download"
[[ -f "$UPDATE_SIG" ]] || fail "Signature file missing after download"

echo "✅ Download complete"

log "Importing public key..."
[[ -f "$PUBLIC_KEY_PATH" ]] || fail "Public key not found at ${PUBLIC_KEY_PATH}"
gpg --import "$PUBLIC_KEY_PATH" >/dev/null 2>&1 || fail "Failed to import GPG public key"

log "Verifying GPG signature..."
gpg --verify "$UPDATE_SIG" "$UPDATE_ZIP" || fail "Signature verification FAILED"

echo "✅ Signature valid"

log "Extracting update..."
rm -rf extracted
mkdir -p extracted
unzip -q "$UPDATE_ZIP" -d extracted || fail "Extraction failed"

echo "✅ Extraction complete"

log "Scanning for malware..."
SCAN_RESULT="$(clamscan -r extracted/ || true)"
echo "$SCAN_RESULT"

echo "$SCAN_RESULT" | grep -q "Infected files: 0" || fail "Malware detected. Update BLOCKED"

echo "✅ No malware detected"

log "Deploying to web server..."
if [[ -d "extracted/${LATEST}" ]]; then
  scp -r "extracted/${LATEST}/"* "${DEPLOY_USER}@${WEB_SERVER}:${WEB_PATH}" || fail "Deployment failed"
else
  scp -r extracted/* "${DEPLOY_USER}@${WEB_SERVER}:${WEB_PATH}" || fail "Deployment failed"
fi

echo "✅ Deployment successful"