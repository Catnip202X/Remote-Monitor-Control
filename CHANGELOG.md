# Changelog

All notable changes to Remote Monitor Control. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

When you release, move the **Unreleased** notes under a new version heading and push a `vX.Y.Z` tag. The release workflow uses that version's section as the GitHub release notes.

## [Unreleased]

### Added
- This changelog. GitHub releases now take their notes from it.

## [1.3.1] - 2026-10-21

### Changed
- Following a USB switch reacts 0.1 seconds after the keyboard comes back, down from 0.6 seconds. Leaving still waits 0.4 seconds so a flickering switch doesn't flip the monitor back and forth.
- Switching to the Mac's input wakes the Mac's display output before the monitor switches, then again after 1 and 2 seconds. The screen comes back without moving the mouse.
- `monitorctl usb watch` prints timestamps with milliseconds.

## [1.3.0] - 2026-10-21

### Added
- **Follow a USB switch.** Pick the keyboard on a USB sharing switch, such as the Sabrent USB-SW30. When it leaves this Mac, the monitor switches to Input B. When it comes back, the monitor switches to Input A.
- A **Follow USB switch** picker in the menu-bar app.
- `monitorctl usb` lists USB devices. `monitorctl usb follow VID:PID | off` sets the followed device, and `monitorctl usb watch [--dry-run]` shows events as they happen.

### Changed
- Switching to the Mac's input wakes the screen.
- `monitorctl` tells the running app when it changes settings, so the app picks them up without a restart.

## [1.2.0] - 2026-10-21

### Added
- **Automatic brand detection.** The app reads each monitor's manufacturer from its EDID and asks the monitor which DDC/CI commands it supports. The result is cached per monitor.
- An **Automatic** power method, now the default. It uses DDC power-off when the monitor supports it, and otherwise turns off the Mac's video signal first. Samsung monitors always get the video signal method, because they wake while they still receive video.
- LG models that don't support the standard input command switch inputs with LG's own command, VCP 0xF4.
- `monitorctl info` shows the brand, the supported commands and why a method was chosen.
- Siri shortcuts named the way you say them: **Turn Off My Monitor**, **Turn On My Monitor** and **Switch Inputs for My Monitor**.
- Built-in Siri phrases for turning the monitor on and off and for switching inputs.

### Changed
- Input B defaults to another input the monitor actually lists.

## [1.1.0] - 2026-10-21

First public release.

### Added
- Menu-bar app, the `monitorctl` command-line tool, Shortcuts and Siri actions, and a server on the local network for iPhone, iPad and Apple Watch shortcuts.
- Power method **DDC/CI + turn off video signal**. "Off" stops the Mac's video signal and then sends DDC power-off, so monitors that wake while receiving video stay off. Only the displays turn off; the Mac keeps running.
- `monitorctl method` shows or changes the power method.
- GitHub Actions builds the app on every push and publishes a release for each `v*` tag.
- Setting `RMC_DEBUG=1` prints the raw DDC replies.

### Changed
- Shortcuts are named **Remote Monitor Control On/Off** and **Remote Monitor Control Input Switching**.
- The remote server uses port 58888, since 8765 is often taken.
- Builds run in `~/Library/Caches`, because iCloud-synced folders add file metadata that breaks code signing.

### Fixed
- The project builds with current Xcode.
- DDC reads work. The read request had the wrong checksum and sub-address.
- A power reading of 0 means "not supported" and is no longer shown as "off".

[Unreleased]: https://github.com/Catnip202X/Remote-Monitor-Control/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/Catnip202X/Remote-Monitor-Control/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/Catnip202X/Remote-Monitor-Control/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/Catnip202X/Remote-Monitor-Control/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Catnip202X/Remote-Monitor-Control/releases/tag/v1.1.0
