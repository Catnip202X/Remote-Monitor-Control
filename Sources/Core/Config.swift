//
//  Config.swift
//  Remote Monitor Control
//
//  Settings shared by the menu-bar app, its App Intents and the `monitorctl` CLI.
//  Stored at ~/Library/Application Support/Remote Monitor Control/config.json
//

import Foundation

public enum PowerMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Pick per monitor from its brand and the capabilities it reports (see MonitorProfile).
    case automatic
    /// Send VCP 0xD6 over DDC/CI *and* turn off the Mac's video signal. Many monitors
    /// (Samsung Odyssey, for one) accept the DDC standby command but wake straight back
    /// up while the Mac is still sending video; stopping the signal keeps them off.
    /// Only the displays turn off; the Mac itself keeps running.
    case ddcAndSignalOff
    /// Send VCP 0xD6 over DDC/CI only — the monitor itself powers down (like the Windows apps).
    case ddc
    /// Only turn off the Mac's video signal (works with any monitor; the monitor goes to
    /// its own standby when the signal stops). The Mac itself keeps running.
    case displaySleep

    public var id: String { rawValue }

    /// Whether "off" stops the Mac's video signal.
    public var cutsSignal: Bool { self == .ddcAndSignalOff || self == .displaySleep }

    public var label: String {
        switch self {
        case .automatic: return "Automatic (per monitor)"
        case .ddcAndSignalOff: return "DDC/CI + turn off video signal"
        case .ddc: return "DDC/CI only"
        case .displaySleep: return "Turn off video signal only"
        }
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var method: PowerMethod = .automatic
    /// Value written to VCP 0xD6 to turn off: 0x04 (DPM off / standby — most monitors can
    /// be woken again over DDC) or 0x05 (hard power off — often can't be woken remotely).
    public var ddcOffValue: UInt8 = 0x04
    public var serverEnabled: Bool = true
    public var port: UInt16 = 58888
    public var token: String = AppConfig.makeToken()
    public var keepMacAwake: Bool = true
    /// The two inputs "Remote Monitor Control Input Switching" flips between (raw VCP 0x60 values).
    public var inputA: UInt16 = 0x11   // HDMI 1 — replaced by the Mac's actual input on first launch
    public var inputB: UInt16 = 0x0F   // DisplayPort 1
    public var inputsAutoDetected: Bool = false
    /// "Follow USB switch": the watched USB device as "vendor:product" hex (e.g. "1532:0257"),
    /// or nil when off. Gone → Input B, back → Input A.
    public var followUSB: String? = nil
    public var followUSBName: String? = nil

    public init() {}

    public static func makeToken(length: Int = 20) -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    // Tolerant decoding so a config written by an older version never breaks.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        method = (try? c.decode(PowerMethod.self, forKey: .method)) ?? d.method
        ddcOffValue = (try? c.decode(UInt8.self, forKey: .ddcOffValue)) ?? d.ddcOffValue
        serverEnabled = (try? c.decode(Bool.self, forKey: .serverEnabled)) ?? d.serverEnabled
        port = (try? c.decode(UInt16.self, forKey: .port)) ?? d.port
        token = (try? c.decode(String.self, forKey: .token)) ?? d.token
        keepMacAwake = (try? c.decode(Bool.self, forKey: .keepMacAwake)) ?? d.keepMacAwake
        inputA = (try? c.decode(UInt16.self, forKey: .inputA)) ?? d.inputA
        inputB = (try? c.decode(UInt16.self, forKey: .inputB)) ?? d.inputB
        inputsAutoDetected = (try? c.decode(Bool.self, forKey: .inputsAutoDetected)) ?? d.inputsAutoDetected
        followUSB = try? c.decodeIfPresent(String.self, forKey: .followUSB)
        followUSBName = try? c.decodeIfPresent(String.self, forKey: .followUSBName)
    }
}

public enum ConfigStore {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Remote Monitor Control", isDirectory: true)
    }
    public static var configURL: URL { directory.appendingPathComponent("config.json") }
    static var stateURL: URL { directory.appendingPathComponent("state.json") }
    static var inputStateURL: URL { directory.appendingPathComponent("input-state.json") }
    static var capabilitiesURL: URL { directory.appendingPathComponent("capabilities.json") }

    /// Cached DDC capabilities strings, keyed by display id.
    public static func capabilitiesCache() -> [String: String] {
        guard let data = try? Data(contentsOf: capabilitiesURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    public static func saveCapabilitiesCache(_ dict: [String: String]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(dict).write(to: capabilitiesURL, options: .atomic)
    }

    public static func load() -> AppConfig {
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        let cfg = AppConfig()
        save(cfg)
        return cfg
    }

    /// Posted (across processes) when `monitorctl` changes settings, so the running app reloads them.
    public static let changedNotification = Notification.Name("com.dekun.RemoteMonitorControl.configChanged")

    public static func notifyChanged() {
        DistributedNotificationCenter.default().postNotificationName(changedNotification, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    public static func save(_ cfg: AppConfig) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(cfg).write(to: configURL, options: .atomic)
    }

    /// Last power state we successfully set per display (used when a monitor in
    /// standby doesn't answer DDC reads).
    public static func lastKnownPower() -> [String: Bool] {
        guard let data = try? Data(contentsOf: stateURL),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return dict
    }

    public static func setLastKnownPower(_ on: Bool, for id: String) {
        var dict = lastKnownPower()
        dict[id] = on
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(dict).write(to: stateURL, options: .atomic)
    }

    /// Last input we switched each display to (used when the monitor doesn't answer reads).
    public static func lastKnownInput() -> [String: UInt16] {
        guard let data = try? Data(contentsOf: inputStateURL),
              let dict = try? JSONDecoder().decode([String: UInt16].self, from: data) else { return [:] }
        return dict
    }

    public static func setLastKnownInput(_ value: UInt16, for id: String) {
        var dict = lastKnownInput()
        dict[id] = value
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(dict).write(to: inputStateURL, options: .atomic)
    }
}
