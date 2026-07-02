#!/usr/bin/env bash
# Worker for the Remote Play resolution service. You do not run this directly;
# install.sh wires it into a systemd user service. Subcommands:
#   watch  follow Steam's Remote Play log, switch on start, restore on stop
#   down   switch to the mode that best fits the device that connected
#   up     restore whatever resolution was active before
#   focus  raise the Steam window (what watch does when a game exits mid-session)
#
# The target mode is chosen per session from the resolution the remote device
# asks for, not from a fixed value. When a device connects Steam writes a line
# like 'Maximum capture: 2352x2160 60.00 FPS' to the streaming log; that is the
# device's own screen. Most devices ask for a size the monitor cannot produce
# exactly (a fold phone's near-square 2352x2160, a phone's 1920x1008), so
# STRATEGY in ./config decides which of the modes the monitor CAN produce we map
# it onto:
#   bestfit   nearest aspect ratio, so the device screen is filled with the
#             least letterboxing. A near-square fold lands on the closest-to-
#             square mode the monitor has (1280x1024 here).
#   sharpest  the highest-resolution mode that is not upscaled to reach the
#             device, for the crispest picture, accepting more letterboxing
#             (the fold lands on 2560x1440 instead).
# A device the monitor can match exactly (an Apple TV asking for 1920x1080)
# lands on that same mode under either strategy.
#
# Modes are set by kscreen-doctor mode ID, because kscreen-doctor refuses a
# decimal refresh string like 5120x1440@119.97 but always accepts the ID.
set -euo pipefail

SELF="$(readlink -f "$0")"
DIR="$(dirname "$SELF")"
CONF="$DIR/config"
STATE="${XDG_RUNTIME_DIR:-/tmp}/remote-play-resolution.lastmode"
LOG="$HOME/.local/share/Steam/logs/streaming_log.txt"
# Seconds a Remote Play stream must stay stopped before we restart Steam. Long
# enough to ride out the drop/reconnect flaps Remote Play does within a second
# or two, and to let the stream pipeline finish tearing down so 'steam -shutdown'
# is not racing it. Shutting Steam down while the stream is still tearing down
# crashes it (SIGSEGV in the 32-bit client), which is why this delay exists.
RESTART_DELAY=5

command -v kscreen-doctor >/dev/null \
  || { echo "kscreen-doctor not found. Needs KDE Plasma on Wayland." >&2; exit 1; }

strip() { sed -r 's/\x1B\[[0-9;]*[mGKH]//g'; }
# Modes line of the active monitor (the one carrying the '*' marker)
modes() { kscreen-doctor -o 2>/dev/null | strip | awk '/Modes:/ && /\*/{print; exit}'; }
active_output() {
  kscreen-doctor -o 2>/dev/null | strip \
    | awk '/^Output:/{n=$3} /Modes:/ && /\*/{print n; exit}'
}
active_id()    { modes | grep -oE '[0-9]+:[0-9]+x[0-9]+@[0-9.]+\*' | head -1 | cut -d: -f1; }
active_label() { modes | grep -oE '[0-9]+x[0-9]+@[0-9.]+\*' | head -1 | tr -d '*'; }

# Pick the kscreen-doctor mode ID to switch to for a device that wants
# WCxHC at FC Hz, under STRATEGY (bestfit|sharpest). Prints the ID, or nothing
# if no mode is usable. The whole choice is float math over the monitor's mode
# list, done in awk because the shell cannot do it:
#   fill  fraction of the device screen the mode covers once it is scaled to
#         fit preserving aspect ratio. Depends only on aspect: 1.0 for an exact
#         aspect match, less as the shapes diverge. Maximising fill minimises
#         letterboxing.
#   s     the scale the mode is drawn at to fit the device. s<=1 means the mode
#         is at least as large as the device in the binding dimension, so it is
#         downscaled (crisp); s>1 means it is upscaled (soft).
# bestfit  picks the highest fill. sharpest picks the highest fill among modes
#          that are not upscaled (s<=1). Both break ties toward the mode closest
#          to the device's own pixel count (so an exact match wins and we do not
#          waste the GPU driving more pixels than the device can show), then
#          toward the refresh nearest FC.
select_mode_id() {
  local wc=$1 hc=$2 fc=$3 strat=$4
  modes | grep -oE '[0-9]+:[0-9]+x[0-9]+@[0-9.]+' \
    | awk -v wc="$wc" -v hc="$hc" -v fc="$fc" -v strat="$strat" '
        function abs(x){ return x<0 ? -x : x }
        BEGIN{ eps=0.0001; have=0; fb_area=-1; fb_id=""; fb_rf=0 }
        {
          split($0, a, /[:x@]/)          # id : W x H @ refresh
          id=a[1]+0; w=a[2]+0; h=a[3]+0; rf=a[4]+0
          if (w<=0 || h<=0) next
          ac=wc/hc; ah=w/h
          fill=(ac<=ah) ? ac/ah : ah/ac
          s=(wc/w < hc/h) ? wc/w : hc/h
          areadiff=abs(w*h - wc*hc)
          rfdiff=abs(rf - fc)
          if (strat=="sharpest") {
            # remember the largest mode as a last resort if nothing is downscaled
            if (w*h > fb_area || (w*h==fb_area && rfdiff<fb_rf)) { fb_area=w*h; fb_id=id; fb_rf=rfdiff }
            if (s > 1+eps) next          # skip upscaled modes for sharpest
          }
          if (!have || fill>bf+eps \
              || (fill>bf-eps && (areadiff<ba || (areadiff==ba && rfdiff<br)))) {
            have=1; bf=fill; ba=areadiff; br=rfdiff; bid=id
          }
        }
        END{
          if (have) print bid
          else if (strat=="sharpest" && fb_id!="") print fb_id
        }'
}

down() {
  [ -f "$STATE" ] && return 0          # already switched
  [ -f "$CONF" ] || { echo "Not configured. Run install.sh" >&2; return 1; }
  . "$CONF"
  local strat="${STRATEGY:-bestfit}"
  # The device announces its screen as 'Maximum capture: WxH FPS' when it
  # connects, just before the desktop stream starts, so the newest such line is
  # this session's. There is no fixed fallback resolution any more, so if we
  # cannot read it we refuse to switch rather than guess a wrong size: you get
  # the full desktop on the device, which is at least visibly not-switched.
  local cap wc hc fc
  cap=$(grep -aoE 'Maximum capture: [0-9]+x[0-9]+ [0-9.]+ FPS' "$LOG" 2>/dev/null | tail -1)
  if [[ "$cap" =~ ([0-9]+)x([0-9]+)\ ([0-9.]+) ]]; then
    wc=${BASH_REMATCH[1]}; hc=${BASH_REMATCH[2]}; fc=${BASH_REMATCH[3]}
  else
    echo "No 'Maximum capture' line in $LOG; cannot tell what the device wants, not switching." >&2
    return 1
  fi
  local out id label target
  out=$(active_output); id=$(active_id); label=$(active_label)
  [ -n "$out" ] && [ -n "$id" ] || { echo "Cannot read the active mode." >&2; return 1; }
  target=$(select_mode_id "$wc" "$hc" "$fc" "$strat")
  [ -n "$target" ] || { echo "No usable mode for ${wc}x${hc} on $out." >&2; return 1; }
  printf '%s %s %s\n' "$out" "$id" "$label" > "$STATE"
  kscreen-doctor "output.$out.mode.$target" >/dev/null
}

up() {
  [ -f "$STATE" ] || return 0          # already native
  local out id label
  read -r out id label < "$STATE"
  kscreen-doctor "output.$out.mode.$id" >/dev/null
  rm -f "$STATE"
}

# Move the host pointer to the middle of the screen. A Remote Play session leaves
# the cursor frozen where it was; the compositor only hides and refreshes it once
# it sees fresh input. ydotoold's virtual device exposes no absolute axis (EV=7:
# SYN/KEY/REL only), so 'mousemove --absolute' misbehaves and lands in the
# top-left. We use relative moves instead: an oversized negative move clamps the
# pointer into the top-left corner, then a relative move of half the resolution
# steps it to the middle. The session runs at whatever mode 'down' switched us
# to, so we read that live from the active output (active_label is like
# 1280x1024@60.02) rather than from config. This assumes 1:1 pointer motion
# (KDE's default flat acceleration, measured here); if mouse acceleration is
# enabled the centering would drift. If ydotool is not installed we skip
# silently.
center_cursor() {
  command -v ydotool >/dev/null || return 0
  local label w h
  label=$(active_label)
  w=${label%%x*}; h=${label#*x}; h=${h%%@*}
  if [ "${w:-x}" -gt 0 ] 2>/dev/null && [ "${h:-x}" -gt 0 ] 2>/dev/null; then
    ydotool mousemove -- -30000 -30000 >/dev/null 2>&1 || true   # home to top-left
    ydotool mousemove -x $((w/2)) -y $((h/2)) >/dev/null 2>&1 || true
  else
    echo "center_cursor: could not read the active resolution; skipping." >&2
  fi
}

# When a stream starts, unfreeze the host cursor: center it (3s in), then tap a
# key (4s in) so the compositor sees fresh input and hides it again. 105 is
# KEY_LEFT; it only moves a selection left, so unlike Space (57, which types and
# can activate a focused button or jump in a game) it never confirms or launches
# anything on the desktop or in Steam/Big Picture. ydotool is the Wayland uinput
# tool; if it is not installed we skip silently, and if the keypress fails
# (usually ydotoold not running) we say so loudly.
nudge() {
  command -v ydotool >/dev/null || return 0
  sleep 3
  center_cursor
  sleep 1
  ydotool key 105:1 105:0 >/dev/null 2>&1 \
    || echo "ydotool is installed but the keypress failed; is ydotoold running?" >&2
}

# When RESTART_STEAM=yes in config, fully restart Steam after a session ends.
# 'steam -shutdown' is Steam's own clean-exit command; we wait for the process
# to actually disappear, then relaunch it in its own transient systemd unit.
# The relaunch MUST land outside this service's cgroup. A process forked from
# here inherits our cgroup, and setsid does not change that: setsid starts a new
# session (process-group leadership), it does not move the process between
# cgroups. Because the unit runs with the default KillMode=control-group, a
# Steam left inside our cgroup gets SIGTERM/SIGKILL every time the service stops
# or restarts (Restart=on-failure, a re-run of install.sh, or logout), which
# tears the whole Steam tree and any running game down and crashes them.
# 'systemd-run --user' asks the user manager to start Steam as an independent
# transient unit, a sibling cgroup that this service's lifecycle never touches.
# --collect removes that unit once Steam exits so the fixed name is free next
# time. This is tied to the stream-stopped event only, never to the service
# stopping, so logging out does not relaunch Steam.
restart_steam() {
  [ -f "$CONF" ] || return 0
  . "$CONF"
  [ "${RESTART_STEAM:-no}" = "yes" ] || return 0
  command -v steam >/dev/null \
    || { echo "RESTART_STEAM=yes but the steam command was not found." >&2; return 0; }
  command -v systemd-run >/dev/null \
    || { echo "RESTART_STEAM=yes but systemd-run is missing; refusing to relaunch Steam inside this service's cgroup." >&2; return 0; }
  steam -shutdown >/dev/null 2>&1 || true
  local n=0
  while pgrep -x steam >/dev/null && [ "$n" -lt 40 ]; do sleep 0.5; n=$((n+1)); done
  if pgrep -x steam >/dev/null; then
    echo "Steam did not exit within 20s; not relaunching to avoid two instances." >&2
    return 0
  fi
  # '-silent' is Steam's own flag for starting minimized to the system tray, so it
  # comes back quietly instead of popping a window onto the desktop after a
  # session.
  systemd-run --user --collect --unit=steam-remote-play-relaunch steam -silent >/dev/null 2>&1 \
    || echo "systemd-run failed to relaunch Steam." >&2
}

# Bring Steam's main window to the foreground. steam://open/main is forwarded to
# the already-running client over ~/.steam/steam.pipe and raises whatever the main
# window currently is. Verified here across every state: it restores the window
# from the system tray (where its X window is withdrawn, so a window manager
# cannot even see it to raise it), it focuses the window when it was merely behind
# others, and it leaves Big Picture in Big Picture instead of dropping to the
# desktop client. We bail if Steam is not already running: not because it might
# be absent (this whole tool follows Steam's own log, so it obviously is) but
# because with no client up the steam wrapper would launch one, and it would
# start inside this service's cgroup, the exact breakage restart_steam() exists
# to avoid.
raise_steam() {
  pgrep -x steam >/dev/null || return 0
  steam steam://open/main >/dev/null 2>&1 \
    || echo "steam://open/main failed though Steam is running." >&2
}

# What we do when a game the remote user was playing exits: raise Steam so they
# land back on it (only if FOCUS_STEAM=yes), and center the cursor (the same
# unfreeze trick as a stream start, but no keypress, so nothing gets triggered
# inside Steam).
back_to_steam() {
  [ -f "$CONF" ] && . "$CONF"
  [ "${FOCUS_STEAM:-yes}" = "yes" ] && raise_steam
  center_cursor
}

# Two different signals live in this log and must not be confused:
#
#   >>> Starting/Stopped desktop stream   toggles every time the stream switches
#     between the desktop and a game. Launching a game stops the *desktop*
#     stream while the session keeps running, so these do NOT mark the session
#     ending. They drive the resolution switch only.
#
#   Streaming started to <device> / PipeWire: Deinitializing streaming
#     bracket a whole Remote Play session: one real client connect and one real
#     disconnect per session. These drive the Steam restart.
#
# Restarting on "Stopped desktop stream" was wrong: it fired when a game was
# launched, restarting Steam a few seconds into play. The restart is tied to
# "Deinitializing streaming" (the true disconnect) and debounced by
# RESTART_DELAY, so a client that reconnects right away ("Streaming started to"
# during the wait) cancels it and 'steam -shutdown' runs only once the session
# is really over and its pipeline has settled.
watch() {
  while [ ! -f "$LOG" ]; do sleep 5; done
  local pending=""   # PID of a scheduled-but-not-yet-fired Steam restart
  local in_game=""   # set while a game has taken the stream over from the desktop
  # tail blocks on inotify (no CPU while idle); grep filters in C so the shell
  # only wakes for these markers; -F survives Steam recreating the log.
  tail -n0 -F "$LOG" 2>/dev/null \
    | grep --line-buffered -E '>>> (Starting|Stopped) desktop stream|Streaming started to|Deinitializing streaming' \
    | while IFS= read -r line; do
        case "$line" in
          *"Starting desktop stream"*)                                      # desktop is back on the stream
            "$SELF" down || true
            if [ -n "$in_game" ]; then in_game=""; back_to_steam &          # a game just exited: focus Steam + center the cursor
            else nudge & fi ;;                                              # a fresh stream: center the cursor, then the arrow-key tap
          *"Stopped desktop stream"*)  "$SELF" up || true; in_game=1 ;;     # a game took the stream over from the desktop
          *"Streaming started to"*)                                       # a session connected: cancel any pending restart
            [ -n "$pending" ] && kill "$pending" 2>/dev/null || true       # job may already be gone; that is fine, do not let set -e kill the loop
            pending="" ;;
          *"Deinitializing streaming"*)                                   # the session disconnected: restore, then arm a restart
            "$SELF" up || true
            [ -n "$pending" ] && kill "$pending" 2>/dev/null || true       # same: an already-finished restart job must not trip set -e
            { sleep "$RESTART_DELAY"; restart_steam; } &
            pending=$! ;;
        esac
      done
}

case "${1:-}" in
  watch) watch ;;
  down)  down ;;
  up)    up ;;
  focus) raise_steam ;;
  *) echo "Usage: $0 {watch|down|up|focus}" >&2; exit 1 ;;
esac
