# Linux Steam Remote Play Auto-Resolution

This is a Linux helper that automatically lowers your desktop resolution while you are in a Steam Remote Play session, and restores it the moment you stop.

It exists because playing from a high-resolution host, such as an ultrawide 5120x1440 desktop, makes the picture tiny and unreadable on the device you play on, and Steam Remote Play on Linux freezes outright when the host resolution is too high: [steam-for-linux#7130](https://github.com/ValveSoftware/steam-for-linux/issues/7130). Steam's own "change desktop resolution to match streaming client" option does nothing on Linux: [steam-for-linux#6577](https://github.com/ValveSoftware/steam-for-linux/issues/6577), so this does it for you.

## Introduction

The install script performs the following:

1. Asks how to match a connecting device to your monitor: best fit (fill the device screen, least letterboxing) or sharpest image (crispest picture, more letterboxing).
2. Asks whether to restart Steam when a session ends.
3. Asks whether to focus Steam when you exit a game mid-session.
4. Saves your choices and enables a small systemd user service.

From then on the service watches Steam's Remote Play log. When a device connects, Steam records the resolution that device asks for; the service reads it and switches your monitor to the closest mode it can actually produce, following the match you chose. A device whose exact resolution your monitor supports (an Apple TV asking for 1920x1080) lands on that mode either way. When the session ends it restores whatever you were on before. If you opted in, it then cleanly closes Steam with `steam -shutdown` and starts it again. It waits on a kernel inotify event, so it uses no CPU until a session actually starts or stops, and it never touches your display at any other time.

## Usage

To set it up, run the install script in your terminal.\
It will ask how to match devices, whether to restart Steam, and whether to focus it, then enable the service.

	./install.sh

To remove it and put your display back to normal:

	./uninstall.sh

## Note

This only works on KDE Plasma running a Wayland session, because it changes the mode through `kscreen-doctor`.

Running Steam itself inside gamescope and playing through that does not work on a Linux host; it connects and then freezes: [gamescope#1596](https://github.com/ValveSoftware/gamescope/issues/1596). Switching the real desktop resolution avoids that problem entirely.
