#!/usr/bin/env sh
set -e

REPO="treagod/meridian"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="meridian"

# ── OS check ──────────────────────────────────────────────────────────────────
OS="$(uname -s)"
if [ "$OS" != "Linux" ]; then
  echo "error: Meridian pre-built binaries are only available for Linux." >&2
  echo "       Build from source: https://github.com/${REPO}#from-source" >&2
  exit 1
fi

# ── Architecture detection ────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    ARCH_SUFFIX="linux-x86_64"
    ;;
  aarch64 | arm64)
    ARCH_SUFFIX="linux-arm64"
    ;;
  *)
    echo "error: Unsupported architecture: $ARCH" >&2
    echo "       Build from source: https://github.com/${REPO}#from-source" >&2
    exit 1
    ;;
esac

# ── Resolve latest version ────────────────────────────────────────────────────
echo "Fetching latest Meridian release..."
VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"tag_name"' \
  | sed 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/')"

if [ -z "$VERSION" ]; then
  echo "error: Could not determine latest release version." >&2
  exit 1
fi
echo "Latest version: ${VERSION}"

# ── Build download URLs ───────────────────────────────────────────────────────
ARTIFACT="${BINARY_NAME}-${VERSION}-${ARCH_SUFFIX}"
BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"
BINARY_URL="${BASE_URL}/${ARTIFACT}"
CHECKSUM_URL="${BASE_URL}/checksums.txt"

# ── Download binary and checksums ─────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Downloading ${ARTIFACT}..."
curl -fsSL --progress-bar -o "${TMP_DIR}/${ARTIFACT}" "${BINARY_URL}"

echo "Downloading checksums.txt..."
curl -fsSL -o "${TMP_DIR}/checksums.txt" "${CHECKSUM_URL}"

# ── Verify SHA-256 checksum ───────────────────────────────────────────────────
echo "Verifying checksum..."
EXPECTED="$(grep "${ARTIFACT}" "${TMP_DIR}/checksums.txt" | awk '{print $1}')"
if [ -z "$EXPECTED" ]; then
  echo "error: No checksum entry found for ${ARTIFACT} in checksums.txt" >&2
  exit 1
fi

ACTUAL="$(sha256sum "${TMP_DIR}/${ARTIFACT}" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "error: Checksum mismatch for ${ARTIFACT}" >&2
  echo "  expected: ${EXPECTED}" >&2
  echo "  actual:   ${ACTUAL}" >&2
  exit 1
fi
echo "Checksum verified."

# ── Install ───────────────────────────────────────────────────────────────────
echo "Installing to ${INSTALL_DIR}/${BINARY_NAME}..."
if [ -w "$INSTALL_DIR" ]; then
  mv "${TMP_DIR}/${ARTIFACT}" "${INSTALL_DIR}/${BINARY_NAME}"
  chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
else
  sudo mv "${TMP_DIR}/${ARTIFACT}" "${INSTALL_DIR}/${BINARY_NAME}"
  sudo chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
fi

echo ""
echo "Meridian ${VERSION} installed successfully."
echo "Run: ${BINARY_NAME} --version"
