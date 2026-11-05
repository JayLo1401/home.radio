#!/usr/bin/env bash
# Builds the Linux release and the .deb package.
#
#   linux/scripts/build-deb.sh <version> [build-number] [update-base-url]
#
# Output in build/linux-deb-output/: home-radio_<version>_amd64.deb and
# version.json (the update manifest, see lib/data/services/update_service.dart).
# Installs to /opt/home-radio; apply-update.sh + the polkit policy let the
# in-app updater install a downloaded .deb (fixed path) after pkexec.
set -euo pipefail

VERSION="${1:?version missing}"
BUILD_NUMBER="${2:-}"
UPDATE_BASE_URL="${3:-}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ARGS=(build linux --release "--build-name=$VERSION")
[ -n "$BUILD_NUMBER" ] && ARGS+=("--build-number=$BUILD_NUMBER")
[ -n "$UPDATE_BASE_URL" ] && ARGS+=("--dart-define=UPDATE_BASE_URL=$UPDATE_BASE_URL")
flutter "${ARGS[@]}"

BUNDLE="build/linux/x64/release/bundle"
OUT="build/linux-deb-output"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APPDIR="opt/home-radio"

mkdir -p "$STAGE/$APPDIR" "$STAGE/DEBIAN" "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/icons/hicolor/256x256/apps" "$STAGE/usr/share/polkit-1/actions" "$STAGE/usr/bin"
cp -a "$BUNDLE/." "$STAGE/$APPDIR/"
cp linux/packaging/apply-update.sh "$STAGE/$APPDIR/apply-update.sh"
cp linux/packaging/home-radio.desktop "$STAGE/usr/share/applications/"
cp linux/packaging/at.jaycloud.home.radio.policy "$STAGE/usr/share/polkit-1/actions/"
cp assets/icon/applogo1.png "$STAGE/usr/share/icons/hicolor/256x256/apps/home-radio.png"
ln -s "/$APPDIR/home_radio" "$STAGE/usr/bin/home-radio"

# Library dependencies from what the binaries actually link (package names
# differ between Ubuntu releases, e.g. the t64 renames). dpkg-shlibdeps
# needs a debian/control in the working directory.
mkdir -p "$STAGE/debian"
printf 'Source: home-radio\n\nPackage: home-radio\nArchitecture: amd64\n' > "$STAGE/debian/control"
DEPENDS="$(cd "$STAGE" && dpkg-shlibdeps -O --ignore-missing-info \
  -l"$APPDIR/lib" "$APPDIR/home_radio" "$APPDIR"/lib/*.so* | sed -n 's/^shlibs:Depends=//p')"
rm -rf "$STAGE/debian"
[ -n "$DEPENDS" ] || { echo "dpkg-shlibdeps found no dependencies" >&2; exit 1; }
# miniaudio loads ALSA/PulseAudio at runtime - shlibdeps can't see that.
DEPENDS="$DEPENDS, libasound2t64 | libasound2 | libpulse0, pkexec | policykit-1"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: home-radio
Version: $VERSION
Section: sound
Priority: optional
Architecture: amd64
Depends: $DEPENDS
Recommends: rtl-sdr
Maintainer: jaycloud <noreply@jaycloud.at>
Description: Home Radio
 DAB+, UKW und Internetradio in einer Senderliste, mit Wetter und Radar;
 Mithören auf CB-, Amateur-, Flug- und Militärfunk mit einem RTL-SDR-Stick.
EOF

chmod -R go-w "$STAGE"
chmod 755 "$STAGE/$APPDIR/home_radio" "$STAGE/$APPDIR/apply-update.sh"
chmod 644 "$STAGE/usr/share/polkit-1/actions/at.jaycloud.home.radio.policy"

mkdir -p "$OUT"
DEB="$OUT/home-radio_${VERSION}_amd64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"

SHA="$(sha256sum "$DEB" | cut -d' ' -f1)"
URL=""
[ -n "$UPDATE_BASE_URL" ] && URL="$UPDATE_BASE_URL/linux/release/$VERSION/home-radio_${VERSION}_amd64.deb"
cat > "$OUT/version.json" <<EOF
{
  "version": "$VERSION",
  "url": "$URL",
  "sha256": "$SHA"
}
EOF
echo "Package: $DEB"
