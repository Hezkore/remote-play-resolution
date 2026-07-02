#!/usr/bin/env bash
# Remove the service and put the display back to normal.
set -uo pipefail

DIR="$(dirname "$(readlink -f "$0")")"
UNIT="$HOME/.config/systemd/user/remote-play-resolution.service"

systemctl --user disable --now remote-play-resolution.service >/dev/null 2>&1 || true
"$DIR/remote-play-resolution.sh" up >/dev/null 2>&1 || true
rm -f "$UNIT" "$DIR/config" "${XDG_RUNTIME_DIR:-/tmp}/remote-play-resolution.lastmode"
systemctl --user daemon-reload >/dev/null 2>&1 || true

echo "Removed. Your display is back to normal."
