#!/usr/bin/env bash
# Set up (or update) automatic resolution switching for Steam Remote Play.
# Asks how to map a connecting device onto the modes your monitor can produce,
# whether to restart Steam after a session, and whether to focus Steam when a
# game exits, then enables a tiny user service that does the switching.
set -euo pipefail

DIR="$(dirname "$(readlink -f "$0")")"
UNIT="$HOME/.config/systemd/user/remote-play-resolution.service"

echo "Steam Remote Play resolution switcher"
echo
echo "When you play on another device with Steam Remote Play, a host running at a"
echo "very high resolution (like an ultrawide) shows up tiny and can even freeze"
echo "the session. This switches your monitor to a mode that fits the device that"
echo "connects, from the resolution that device asks for, and restores your"
echo "desktop when you stop. Nothing else is changed."
echo

command -v kscreen-doctor >/dev/null \
  || { echo "This needs KDE Plasma on Wayland (kscreen-doctor is missing)."; exit 1; }

echo "Most devices ask for a resolution your monitor cannot produce exactly (a"
echo "fold phone is nearly square, a phone is a bit taller than 16:9). How should"
echo "such a device be mapped onto the modes your monitor does have?"
echo
echo "  Best Fit    fill the device screen, least letterboxing (softer image)"
echo "  Sharpest    crispest image, more letterboxing (black bars)"
echo
select ANS in "Best Fit - Less Letterboxing" "Sharpest Image - More Letterboxing"; do
  [ -n "${ANS:-}" ] && break
done
case "${ANS:-}" in
  Best*)     STRATEGY=bestfit ;;
  Sharpest*) STRATEGY=sharpest ;;
  *) echo "Cancelled."; exit 1 ;;
esac

echo
echo "Restart Steam after a session ends?"
echo "(cleanly closes Steam and starts it again when you stop streaming)"
select ANS in "No" "Yes"; do [ -n "${ANS:-}" ] && break; done
[ "${ANS:-}" = "Yes" ] && RESTART_STEAM=yes || RESTART_STEAM=no

echo
echo "Focus Steam when you exit a game mid-session?"
echo "(brings the Steam window back to the front so you land on it)"
select ANS in "No" "Yes"; do [ -n "${ANS:-}" ] && break; done
[ "${ANS:-}" = "Yes" ] && FOCUS_STEAM=yes || FOCUS_STEAM=no

printf 'STRATEGY=%s\nRESTART_STEAM=%s\nFOCUS_STEAM=%s\n' \
  "$STRATEGY" "$RESTART_STEAM" "$FOCUS_STEAM" > "$DIR/config"

mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<EOF
[Unit]
Description=Auto-switch display resolution during Steam Remote Play
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$DIR/remote-play-resolution.sh watch
ExecStopPost=$DIR/remote-play-resolution.sh up
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload >/dev/null 2>&1
systemctl --user reenable remote-play-resolution.service >/dev/null 2>&1
systemctl --user restart  remote-play-resolution.service >/dev/null 2>&1

echo
echo "Done. Remote Play will switch to fit the device that connects ($STRATEGY),"
echo "then restore your desktop when you stop."
