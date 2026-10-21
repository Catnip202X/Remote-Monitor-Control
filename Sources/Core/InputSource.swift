//
//  InputSource.swift
//  Remote Monitor Control
//
//  Monitor input switching over DDC/CI — VCP feature 0x60 ("Input Source").
//  Standard MCCS values are listed below. Some brands (notably LG) use their own
//  codes; use `monitorctl input` to read the current value on each input and use
//  the number directly (e.g. `monitorctl input 0x90`).
//

import Foundation

public enum InputSource: String, CaseIterable, Identifiable, Sendable {
    case vga1, dvi1, dvi2, displayPort1, displayPort2, hdmi1, hdmi2, usbC

    public static let vcp: UInt8 = 0x60

    public var id: String { rawValue }

    public var value: UInt16 {
        switch self {
        case .vga1: return 0x01
        case .dvi1: return 0x03
        case .dvi2: return 0x04
        case .displayPort1: return 0x0F
        case .displayPort2: return 0x10
        case .hdmi1: return 0x11
        case .hdmi2: return 0x12
        case .usbC: return 0x1B
        }
    }

    public var label: String {
        switch self {
        case .vga1: return "VGA"
        case .dvi1: return "DVI 1"
        case .dvi2: return "DVI 2"
        case .displayPort1: return "DisplayPort 1"
        case .displayPort2: return "DisplayPort 2"
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        case .usbC: return "USB-C"
        }
    }

    /// The inputs worth showing in menus.
    public static let common: [InputSource] = [.hdmi1, .hdmi2, .displayPort1, .displayPort2, .usbC]

    public static func from(value: UInt16) -> InputSource? {
        allCases.first { $0.value == (value & 0xFF) }
    }

    /// Accepts "hdmi1", "HDMI 1", "dp2", "displayport1", "usbc", "usb-c", or a number ("0x11", "17").
    public static func parseValue(_ text: String) -> UInt16? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let aliases: [String: InputSource] = [
            "vga": .vga1, "vga1": .vga1,
            "dvi": .dvi1, "dvi1": .dvi1, "dvi2": .dvi2,
            "dp": .displayPort1, "dp1": .displayPort1, "displayport": .displayPort1, "displayport1": .displayPort1,
            "dp2": .displayPort2, "displayport2": .displayPort2,
            "hdmi": .hdmi1, "hdmi1": .hdmi1, "hdmi2": .hdmi2,
            "usbc": .usbC, "typec": .usbC, "thunderbolt": .usbC,
        ]
        if let source = aliases[t] { return source.value }
        if t.hasPrefix("0x") { return UInt16(t.dropFirst(2), radix: 16) }
        return UInt16(t)
    }

    public static func describe(_ value: UInt16) -> String {
        if let s = from(value: value) { return "\(s.label) (0x\(String(format: "%02X", value & 0xFF)))" }
        return "0x\(String(format: "%02X", value))"
    }
}

extension MonitorController {
    /// Switch input. `value` is the raw VCP 0x60 value (see `InputSource`).
    @discardableResult
    public func setInput(_ value: UInt16, displayID: String? = nil) throws -> String {
        try locked { try _setInput(value, displayID: displayID) }
    }

    private func _setInput(_ value: UInt16, displayID: String?) throws -> String {
        var done: [String] = []
        var failed: [String] = []
        for display in try resolve(displayID) {
            let style = profile(for: display).inputStyle
            let written: Bool
            switch style {
            case .standard:
                written = DDC.write(display.service, vcp: InputSource.vcp, value: value)
            case .lgAlternate:
                written = DDC.write(display.service, vcp: 0xF4, value: InputStyle.lgValue(for: value), source: 0x50)
            }
            if written {
                ConfigStore.setLastKnownInput(value, for: display.id)
                done.append(display.name)
            } else {
                failed.append(display.name)
            }
        }
        if done.isEmpty { throw MonitorError.ddcFailed(failed) }
        // Switching back to this Mac's input: the monitor re-syncs to the Mac's signal,
        // and macOS may not redraw until it sees activity. Act like a mouse move now and
        // again once the monitor has settled.
        if value & 0xFF == ConfigStore.load().inputA & 0xFF {
            Self.declareUserActivity()
            usleep(1_500_000)
            Self.declareUserActivity()
        }
        var message = "\(done.joined(separator: ", ")) switched to \(InputSource.describe(value))"
        if !failed.isEmpty { message += " (no response from \(failed.joined(separator: ", ")))" }
        return message
    }

    /// Current input of each monitor (raw value, nil if the monitor didn't answer).
    public func currentInputs(displayID: String? = nil) -> [(name: String, value: UInt16?)] {
        locked {
        guard let list = try? resolve(displayID) else { return [] }
        return list.map { display in
            // LG's alternate input can't be read back; the toggle then uses the last input it set.
            guard profile(for: display).inputStyle == .standard else { return (display.name, nil) }
            return (display.name, DDC.read(display.service, vcp: InputSource.vcp).map { $0.current & 0xFF })
        }
        }
    }

    /// Flip between config.inputA and config.inputB. If the monitor is on A it goes to B,
    /// otherwise it goes to A (so from "some other input" you always come back to the Mac).
    @discardableResult
    public func toggleInput(displayID: String? = nil, config: AppConfig = ConfigStore.load()) throws -> String {
        try locked {
            let list = try resolve(displayID)
            let cache = ConfigStore.lastKnownInput()
            var messages: [String] = []
            var lastError: Error?
            for display in list {
                let current = DDC.read(display.service, vcp: InputSource.vcp).map { $0.current & 0xFF } ?? cache[display.id]
                let target = (current == config.inputA) ? config.inputB : config.inputA
                do {
                    messages.append(try setInput(target, displayID: display.id))
                } catch {
                    lastError = error
                }
            }
            if messages.isEmpty, let lastError { throw lastError }
            return messages.joined(separator: "\n")
        }
    }

    /// On first launch, remember the input the Mac is currently on as input A.
    public func autoDetectInputPair() {
        var config = ConfigStore.load()
        guard !config.inputsAutoDetected else { return }
        guard let current = currentInputs().first?.value, current != 0 else { return }
        config.inputA = current
        // Prefer another input the monitor actually lists in its capabilities.
        let listed = displays().first.map { profile(for: $0).capabilities?.inputs ?? [] } ?? []
        if let other = listed.map({ $0 & 0xFF }).first(where: { $0 != current }) {
            config.inputB = other
        } else if config.inputB == current {
            config.inputB = current == InputSource.hdmi1.value ? InputSource.displayPort1.value : InputSource.hdmi1.value
        }
        config.inputsAutoDetected = true
        ConfigStore.save(config)
    }
}
