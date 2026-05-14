# Restless

Restless is a tiny macOS menu bar app for keeping a MacBook awake with the lid closed, then letting it sleep again after a time or battery limit.

It is designed for cases like moving around with a MacBook closed while a download, sync, build, backup, server, or long-running task keeps working.

## Features

- Menu bar only: no Dock icon and no main window.
- One-click on/off control from a small display icon.
- Closed-lid keep-awake mode using macOS `pmset`.
- Optional close timer, such as 15 minutes, 30 minutes, 1 hour, or custom.
- Optional battery cutoff, such as 20%, 40%, or custom.
- Last closed-lid session metrics with time and battery used.
- Event-based battery, wake, screen-sleep, and screen-wake tracking with a polling fallback.
- Orange menu bar icon when Restless is enabled but the battery cutoff means it will not keep the Mac awake closed.
- Launch-at-login setting in the menu.
- One-time in-app setup so Restless can toggle its exact `pmset` command without asking every time.

## Download

Download [`Restless.zip`](dist/Restless.zip), unzip it, and move `Restless.app` to `/Applications`.

The app is not notarized yet. If macOS blocks it the first time:

1. Open Finder.
2. Go to `/Applications`.
3. Right-click `Restless.app`.
4. Choose **Open**.
5. Confirm **Open** again.

If macOS still says the app is quarantined, run:

```bash
xattr -dr com.apple.quarantine /Applications/Restless.app
```

## First Run

1. Open `Restless.app`.
2. Click the small display icon in the menu bar.
3. Click **Allow Restless** in the one-time setup banner.
4. Enter your Mac administrator password when macOS asks.

After that, Restless can turn closed-lid keep-awake on and off without asking for your password each time. The setup only allows these two commands:

```bash
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

It does not grant general passwordless sudo access. To start Restless automatically, turn on **Start at Login** in the same menu.

## How To Use

1. Click the display icon in the menu bar.
2. Choose **Turn On**.
3. Pick a close timer and battery cutoff if you want limits.
4. Close the lid.

When Restless is on, it keeps the Mac awake while closed. If the close timer or battery cutoff is reached, Restless lets the Mac sleep for that closed-lid session but stays enabled for the next time you close the lid.

Restless watches macOS power-source and wake events, so the menu updates when the battery changes, when the close timer expires, and when the lid opens again. The close timer resets every time a new closed-lid session starts. If the battery is already at or below your cutoff, the menu bar icon turns orange to show that closed-lid keep-awake will pause until the battery is above the limit or the cutoff is changed.

The menu shows:

- Current battery percentage.
- Last closed-lid session duration and battery use.
- Close timer.
- Battery cutoff.
- Start at login.

## Advanced Setup

The app handles setup from the menu. The release zip also includes terminal scripts for managed or repeat installs:

```bash
./script/install_passwordless_toggle.sh
./script/install_startup.sh
```

## Safety Notes

Keeping a laptop awake while closed can generate heat, especially if it is in a bag or under load. Use a conservative timer and battery cutoff, and avoid keeping the Mac running closed in a confined space.

Restless does not bypass macOS security. It uses the built-in `/usr/bin/pmset` tool and only changes the `disablesleep` setting.

## Build From Source

Requirements:

- macOS 13 or newer
- Xcode command line tools
- Swift 5.9 or newer

Build and run:

```bash
swift build
./script/build_and_run.sh
```

Create a release zip:

```bash
./script/package_release.sh
```

The packaged app is written to:

```bash
dist/Restless.zip
```

## Uninstall

Quit Restless from Activity Monitor or Terminal:

```bash
pkill -x Restless
```

Remove the app:

```bash
rm -rf /Applications/Restless.app
```

Remove launch-at-login:

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.andrewturner.Restless.plist"
rm -f "$HOME/Library/LaunchAgents/com.andrewturner.Restless.plist"
```

Remove the passwordless `pmset` rule:

```bash
sudo rm -f /etc/sudoers.d/restless-pmset
```

Restore normal sleep behavior:

```bash
sudo /usr/bin/pmset -a disablesleep 0
```

## License

Restless is released under the Apache License 2.0. See [LICENSE](LICENSE).
