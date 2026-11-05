#!/usr/bin/env bash
# Installs the latest Home Radio .deb from the update server:
#   curl -fsSL <base>/linux/release/latest/install.sh | bash
set -euo pipefail
BASE="${HOME_RADIO_BASE:-__UPDATE_BASE_URL__}"
MANIFEST="$(curl -fsSL "$BASE/linux/release/latest/version.json")"
VERSION="$(printf '%s' "$MANIFEST" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')"
SHA="$(printf '%s' "$MANIFEST" | sed -n 's/.*"sha256": *"\([^"]*\)".*/\1/p')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DEB="$TMP/home-radio_${VERSION}_amd64.deb"
curl -fsSL -o "$DEB" "$BASE/linux/release/latest/home-radio-latest.deb"
echo "$SHA  $DEB" | sha256sum -c -
sudo apt-get install -y "$DEB"
echo "Home Radio $VERSION installiert."
