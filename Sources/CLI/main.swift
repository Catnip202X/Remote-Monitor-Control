//
//  main.swift — monitorctl
//  Remote Monitor Control command-line tool.
//
//  Use it from Terminal, from a Shortcuts "Run Shell Script" action, or over SSH
//  (iPhone Shortcuts → "Run Script over SSH").
//

import Foundation

let usage = """
monitorctl — turn external monitors on/off over DDC/CI

USAGE
  monitorctl list                         list external monitors
  monitorctl on   [-d DISPLAY]            turn monitor(s) on
  monitorctl off  [-d DISPLAY]            turn monitor(s) off
  monitorctl toggle [-d DISPLAY]          flip power
  monitorctl status [-d DISPLAY]          show power state
  monitorctl input [SOURCE] [-d DISPLAY]  show input, or switch to SOURCE:
                                          hdmi1 hdmi2 dp1 dp2 usbc dvi vga, or a number (0x11)
  monitorctl input toggle [-d DISPLAY]    flip between input A and input B
  monitorctl input-pair [A B]             show / set the two inputs used by toggle
  monitorctl get VCP [-d DISPLAY]         read any VCP code   (e.g. get 0xD6)
  monitorctl set VCP VALUE [-d DISPLAY]   write any VCP code  (e.g. set 0x10 50 = brightness 50)
  monitorctl export-shortcuts [DIR] [--host HOST]
                                          create iPhone .shortcut files for the remote server
  monitorctl config                       show settings (incl. remote token)

OPTIONS
  -d, --display DISPLAY   number from `list`, part of the name, or the id (default: all)
  -m, --method ddc|sleep  override the power method for this command
"""

var args = Array(CommandLine.arguments.dropFirst())

func takeOption(_ names: [String]) -> String? {
    guard let i = args.firstIndex(where: { names.contains($0) }) else { return nil }
    guard i + 1 < args.count else {
        FileHandle.standardError.write(Data("Missing value for \(args[i])\n".utf8))
        exit(2)
    }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func number(_ text: String) -> UInt16? {
    let t = text.lowercased()
    if t.hasPrefix("0x") { return UInt16(t.dropFirst(2), radix: 16) }
    return UInt16(t)
}

let display = takeOption(["-d", "--display"])
let methodOption = takeOption(["-m", "--method"])
let hostOption = takeOption(["--host"])

var config = ConfigStore.load()
if let m = methodOption?.lowercased() {
    config.method = (m == "sleep" || m == "displaysleep") ? .displaySleep : .ddc
}

guard let command = args.first?.lowercased() else {
    print(usage)
    exit(0)
}

let controller = MonitorController.shared

do {
    switch command {
    case "list":
        let displays = controller.displays()
        if displays.isEmpty {
            print("No external DDC/CI monitors found.")
        }
        for d in displays {
            print("\(d.index). \(d.name)    id: \(d.id)")
        }

    case "on", "off":
        print(try controller.setPower(command == "on", displayID: display, config: config))

    case "toggle":
        print(try controller.toggle(displayID: display, config: config))

    case "status":
        let statuses = controller.status(displayID: display)
        if statuses.isEmpty { fail("No external DDC/CI monitors found.") }
        for s in statuses {
            print("\(s.name): \(s.stateText) (\(s.source))")
        }

    case "input" where args.count >= 2 && args[1].lowercased() == "toggle":
        print(try controller.toggleInput(displayID: display, config: config))

    case "input-pair":
        if args.count >= 3 {
            guard let a = InputSource.parseValue(args[1]), let b = InputSource.parseValue(args[2]) else {
                fail("usage: monitorctl input-pair hdmi1 dp1")
            }
            config.inputA = a
            config.inputB = b
            config.inputsAutoDetected = true
            ConfigStore.save(config)
        }
        print("Input A: \(InputSource.describe(config.inputA))")
        print("Input B: \(InputSource.describe(config.inputB))")

    case "input":
        if args.count >= 2 {
            guard let value = InputSource.parseValue(args[1]) else {
                fail("Unknown input “\(args[1])”. Use hdmi1, hdmi2, dp1, dp2, usbc, dvi, vga or a number like 0x11.")
            }
            print(try controller.setInput(value, displayID: display))
        } else {
            let inputs = controller.currentInputs(displayID: display)
            if inputs.isEmpty { fail("No external DDC/CI monitors found.") }
            for i in inputs {
                print("\(i.name): \(i.value.map(InputSource.describe) ?? "no answer")")
            }
        }

    case "get":
        guard args.count >= 2, let vcp = number(args[1]), vcp <= 0xFF else { fail("usage: monitorctl get VCP") }
        let r = try controller.readVCP(UInt8(vcp), displayID: display)
        print("VCP 0x\(String(vcp, radix: 16, uppercase: true)): current=\(r.current) max=\(r.max)")

    case "set":
        guard args.count >= 3, let vcp = number(args[1]), vcp <= 0xFF, let value = number(args[2]) else {
            fail("usage: monitorctl set VCP VALUE")
        }
        try controller.writeVCP(UInt8(vcp), value: value, displayID: display)
        print("OK")

    case "export-shortcuts":
        let dir = args.count >= 2 ? args[1] : FileManager.default.currentDirectoryPath
        let result = try ShortcutExporter.export(to: URL(fileURLWithPath: dir), host: hostOption, config: config)
        print(result.message)
        if !result.signed { exit(3) }

    case "config":
        print("Config file: \(ConfigStore.configURL.path)")
        print("Method:      \(config.method.label)")
        print("Off value:   0x0\(String(config.ddcOffValue, radix: 16))")
        print("Remote:      \(config.serverEnabled ? "on" : "off") — \(ShortcutExporter.baseURL(config: config))")
        print("Inputs:      A = \(InputSource.describe(config.inputA)), B = \(InputSource.describe(config.inputB))")
        print("Token:       \(config.token)")
        print("Example:     \(ShortcutExporter.commandURL("off", config: config))")

    case "help", "-h", "--help":
        print(usage)

    default:
        fail("Unknown command “\(command)”.\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
