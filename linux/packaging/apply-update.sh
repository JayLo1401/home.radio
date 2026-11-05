#!/bin/sh
# Installs the update the app downloaded (lib/data/services/update_service.dart).
# Runs as root through pkexec (polkit action at.jaycloud.home.radio.update).
# Takes no arguments and only ever installs this one fixed file, so the
# polkit rule can't be used to install anything else.
set -e
DEB_PATH="/tmp/home-radio-update.deb"
[ -f "$DEB_PATH" ] || { echo "no update at $DEB_PATH" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
exec apt-get install -y "$DEB_PATH"
