# Remote Monitor Control

Turn your external monitor **on/off** and **switch its input** from the macOS menu bar, the Shortcuts app, Siri, the command line, or your iPhone, iPad or Apple Watch.

It works like the Windows tools (ControlMyMonitor, Twinkle Tray, Monitorian): it sends **DDC/CI** commands over the video cable.

| Command | DDC/CI VCP code | Values |
|---|---|---|
| Power | `0xD6` | `0x01` on · `0x04` standby/off · `0x05` hard off |
| Input | `0x60` | `0x11` HDMI 1 · `0x12` HDMI 2 · `0x0F` DP 1 · `0x10` DP 2 · `0x1B` USB-C |

## Install

### Download

1. Download the latest zip from [Releases](https://github.com/Catnip202X/Remote-Monitor-Control/releases), unzip it and move **Remote Monitor Control.app** to Applications.
2. The app isn't notarized by Apple, so macOS blocks it the first time. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Remote Monitor Control.app"
   ```

3. Optional: link the command-line tool.

   ```bash
   ln -sf "/Applications/Remote Monitor Control.app/Contents/MacOS/monitorctl" /opt/homebrew/bin/monitorctl
   ```

4. In the menu-bar app, choose **Export iPhone Shortcuts…**. The shortcuts are made on your Mac because each one contains your Mac's network name and its secret token.

Every push to `main` is built by GitHub Actions, and pushing a `v*` tag publishes a release. See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

### Build from source

You need Xcode (full Xcode, not just the Command Line Tools) and Homebrew. The script installs XcodeGen if it's missing.

```bash
git clone https://github.com/Catnip202X/Remote-Monitor-Control.git
cd Remote-Monitor-Control
./build.sh
```

The script builds in `~/Library/Caches/RemoteMonitorControl` (iCloud-synced folders such as Documents add file metadata that breaks code signing). It:

1. builds the app,
2. installs it to `/Applications`,
3. links the `monitorctl` command,
4. launches the app (it has a display icon in the menu bar), and
5. writes the iPhone shortcuts into `./Shortcuts`.

Before the first run, turn on **DDC/CI** in your monitor's on-screen menu. It's usually under *System* or *Other*.

> **Mac mini port note:** the HDMI port on the **M1** Mac mini doesn't pass DDC. If nothing responds, connect the monitor with **USB-C/Thunderbolt** (a USB-C→DisplayPort or USB-C→HDMI cable works). On M2 and later, the HDMI port works.

## Siri

Say any of these to Siri on your Mac, iPhone or Apple Watch:

| Say | What happens |
|---|---|
| "Turn off my monitor" | Turns the monitor off |
| "Turn on my monitor" | Turns it back on |
| "Switch inputs for my monitor" | Flips between Input A and Input B |
| "Remote Monitor Control On/Off" | Toggles power |

The first three are shortcuts named exactly as you say them, because Siri runs a shortcut when you say its name. Import **Turn Off My Monitor**, **Turn On My Monitor** and **Switch Inputs for My Monitor** from the `Shortcuts/` folder once, and iCloud syncs them to your iPhone and Watch. They reach the Mac over your Wi-Fi.

The app also has built-in Siri phrases that work with no import. Apple requires those to contain the app's name, for example "*Turn off my monitor with Remote Monitor Control*".

## Follow a USB switch

If your keyboard and mouse go through a USB sharing switch (for example the Sabrent USB-SW30) shared with another computer, the monitor can follow the switch. Press the switch's button once and both the keyboard and the screen move.

1. In the menu-bar app, set **Follow USB switch** to your keyboard. Or run `monitorctl usb` to list devices, then `monitorctl usb follow 1532:0257` with your keyboard's ID.
2. When the keyboard leaves this Mac, the monitor switches to **Input B**, the other computer. When it comes back, the monitor switches to **Input A**, this Mac, and the Mac wakes the screen.

Pick the keyboard rather than the switch itself. Many switches use a generic hub chip that other hubs share. Your shortcuts keep working as before. To test without switching, run `monitorctl usb watch --dry-run` and press the switch's button.

This only works when the switch moves the keyboard. A switch with only a button on the box can't be pressed by a shortcut. A button-pressing gadget such as a SwitchBot Bot, triggered from the Home app, can do that, and the monitor then follows.

## Monitor brands

The app works out how to control each monitor by itself. It reads the manufacturer from the monitor's EDID and asks the monitor for its DDC/CI capabilities, the list of commands it supports. With the default power method, **Automatic**, it then picks:

| Monitor | Power off | Input switching |
|---|---|---|
| Supports DDC power (0xD6), most Dell, LG, ASUS, BenQ, HP, Lenovo | DDC power-off only; the video signal stays on | Standard VCP 0x60 |
| Doesn't list DDC power | Turns off the Mac's video signal, then sends DDC power-off | Standard VCP 0x60 |
| Samsung | Turns off the Mac's video signal, then sends DDC power-off, because Samsung monitors wake again while they still receive video | Standard VCP 0x60 |
| LG models that don't list VCP 0x60 | As above | LG's alternate command (VCP 0xF4 with LG's input codes) |

Run `monitorctl info` to see what was detected and why. The capabilities are read once and cached; `monitorctl info --refresh` reads them again. To force a method for every monitor, pick it in the menu or run `monitorctl method ddc`, `ddc+signal` or `signal`.

Only the Samsung Odyssey G5 has been tested on real hardware. The other rules follow the DDC/CI standard and the brands' known quirks. To add or correct a brand, edit the table in `Sources/Core/MonitorProfile.swift` and open a pull request with your monitor's `monitorctl info` output.

## The two buttons

| Shortcut | What one press does |
|---|---|
| **Remote Monitor Control On/Off** | If the monitor is on, it turns it off; if it's off, it turns it on. With the default method, "off" first stops the Mac's video signal and then sends the DDC power-off command. |
| **Remote Monitor Control Input Switching** | Flips between **Input A** and **Input B**. On A it goes to B; on anything else it goes to A. |

Set Input A and Input B in the menu-bar app. On first launch, A is set to whichever input the Mac is using. You can also set them from the command line: `monitorctl input-pair dp1 hdmi1`.

If a monitor doesn't answer status reads (some don't in standby), the app falls back to the last state it set.

## 1. Shortcuts on the Mac (App Intents)

After the first launch, **Remote Monitor Control On/Off** and **Remote Monitor Control Input Switching** appear in the Shortcuts app on their own, with no setup. You can pin them to the menu bar, give them a keyboard shortcut, or use Siri: "*Remote Monitor Control On/Off*" / "*Remote Monitor Control Input Switching*" (the shorter "*Remote Monitor Control power*" / "*… input*" also work).

For automations, there are also these actions (search Shortcuts for "Monitor"): *Turn Monitor On/Off*, *Set Monitor Power*, *Is Monitor On?*, *Switch Monitor Input* (to a specific input), and *Get Monitor Input*. Each one has an optional **Monitor** parameter. Leave it empty to control every external monitor.

Other Mac options:

- URL scheme: `remotemonitor://toggle`, `remotemonitor://toggle-input`, `remotemonitor://on`, `remotemonitor://off`, `remotemonitor://input?source=hdmi2`
- Shell (or a Shortcuts *Run Shell Script* action): `monitorctl toggle`, `monitorctl input toggle`

## 2. Remote control from iPhone / iPad / Apple Watch

The app runs a small server on your home network at port **58888**. A secret token protects it.

**Easy way:** after `./build.sh`, the `Shortcuts/` folder holds six signed shortcuts: **Remote Monitor Control On/Off**, **Remote Monitor Control Input Switching**, **Monitor Status**, and the three Siri shortcuts **Turn Off My Monitor**, **Turn On My Monitor** and **Switch Inputs for My Monitor**. Double-click them on the Mac to import them. Shortcuts names each one after its file, and a file name can't contain "/", so rename **Remote Monitor Control On:Off** to **On/Off** after importing. They sync to your iPhone and Watch through iCloud, or you can AirDrop them. You can also re-export them from the menu-bar app with **Export iPhone Shortcuts…**.

**Manual way:** in Shortcuts on the iPhone, add a **Get Contents of URL** action with
`http://<your-mac>.local:58888/toggle?token=<token>`.
To get the exact URL, use **Copy URL** in the menu-bar app or run `monitorctl config`.

Endpoints: `/toggle`, `/toggle-input`, `/on`, `/off`, `/status`, `/input` (read the current input), and `/input?source=hdmi1|hdmi2|dp1|dp2|usbc|0x11`. Add `&display=2` or `&display=Dell` to target one monitor.

Notes:

- The first time the iPhone connects, macOS may ask to allow **local network** or incoming connections. Allow it.
- **Keep Mac awake** (on by default) stops the Mac from going idle-to-sleep, so it can still receive commands. The display can still sleep.
- Away from home? Install **Tailscale** on the Mac and the iPhone, then use the Mac's Tailscale name instead of `.local`.
- **New Security Token** (under *Copy URL*) blocks old URLs. Export the shortcuts again afterwards.

## 3. Command line

```
monitorctl list
monitorctl toggle                # one-button power
monitorctl input toggle          # one-button input A ⇄ B
monitorctl input-pair dp1 hdmi1  # set A and B
monitorctl off | on | status     [-d 1 | -d "DELL"]
monitorctl input                 # shows the current input (raw code)
monitorctl input hdmi2           # hdmi1 hdmi2 dp1 dp2 usbc dvi vga or 0x11
monitorctl get 0x10              # read any VCP code (0x10 = brightness)
monitorctl set 0x10 70
monitorctl info                  # brand, capabilities and the method Automatic picked
monitorctl usb                   # list USB devices; usb follow VID:PID | off; usb watch --dry-run
monitorctl method auto           # how on/off work: auto (default), ddc+signal, ddc, signal
monitorctl export-shortcuts ~/Desktop
monitorctl config
```

## Troubleshooting

- **The monitor blinks but doesn't turn off:** many monitors, including the Samsung Odyssey G5, accept the DDC standby command and then wake straight back up because the Mac is still sending video. The **Automatic** method detects this: for these monitors it first stops the Mac's video output, then sends the DDC power-off command, so the monitor stays off. Only the displays turn off; the Mac keeps running. Change it with `monitorctl method auto|ddc+signal|ddc|signal` or the *Method* picker in the menu.
- **"Off" works but "On" doesn't:** set *Off mode* to **Standby (0x04)**, which is the default. Under *Power off (0x05)*, many monitors shut down their DDC chip and can't be woken remotely. If the monitor still won't wake, switch *Method* to **Turn off video signal only**. That works with any monitor.
- **Input switching uses odd codes:** some brands, LG in particular, don't use the standard numbers. Put the monitor on each input by hand and run `monitorctl input` to see its code. Then use that number, for example `monitorctl input 0x90` or **Custom code** in Shortcuts.
- **Switching back from another computer:** after the monitor changes input, the Mac usually still has a DDC link and can switch it back. Some monitors drop DDC from inactive inputs; for those, switch back from the monitor's buttons.
- **Debugging reads:** run any command with `RMC_DEBUG=1` (for example `RMC_DEBUG=1 monitorctl get 0x60`) to print the raw DDC reply bytes.
- **Power status:** some monitors, including the Samsung Odyssey G5, answer a power read (0xD6) with 0, which means "not supported". With the default method the app reads whether the Mac's video signal is on instead; with *DDC/CI only* it uses the last state it set.
- **Nothing detected:** run `monitorctl list`. Check the cable and port (see the note above), and check that DDC/CI is on in the monitor's menu.

## Project layout

```
Sources/Core/   DDC/CI over IOAVService, display discovery, brand profiles, power + input logic, config, shortcut exporter
Sources/App/    SwiftUI menu-bar app, App Intents (Shortcuts/Siri), LAN HTTP server
Sources/CLI/    monitorctl
project.yml     XcodeGen spec (build.sh generates the .xcodeproj)
```

Settings live in `~/Library/Application Support/Remote Monitor Control/config.json`.
