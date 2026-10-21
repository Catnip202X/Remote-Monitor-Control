//
//  MonitorController.swift
//  Remote Monitor Control
//
//  High-level on / off / toggle / status used by the app, App Intents, the LAN
//  server and the CLI.
//

import CoreGraphics
import Foundation
import IOKit.pwr_mgt

public enum MonitorError: LocalizedError {
    case noExternalDisplays
    case displayNotFound(String)
    case ddcFailed([String])
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noExternalDisplays:
            return "No external monitor with DDC/CI was found. Check the cable/port and that DDC/CI is enabled in the monitor's on-screen menu."
        case .displayNotFound(let query):
            return "No monitor matches “\(query)”."
        case .ddcFailed(let names):
            return "The monitor didn't accept the DDC command: \(names.joined(separator: ", ")). Enable DDC/CI in the monitor's menu, or try another port (the M1 Mac mini's HDMI port doesn't pass DDC — use USB-C/Thunderbolt)."
        case .commandFailed(let msg):
            return msg
        }
    }
}

public struct MonitorStatus: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// nil = unknown
    public let isOn: Bool?
    /// "monitor" (read over DDC), "last known" or "unknown"
    public let source: String

    public var stateText: String {
        guard let isOn else { return "unknown" }
        return isOn ? "ON" : "OFF"
    }
}

public final class MonitorController {
    public static let shared = MonitorController()
    private let lock = NSRecursiveLock()

    public init() {}

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Discovery

    public func displays() -> [ExternalDisplay] {
        locked { DisplayDiscovery.externalDisplays() }
    }

    /// Thread-safe display lookup used by extensions.
    func resolve(_ query: String?) throws -> [ExternalDisplay] {
        try locked { try targets(query) }
    }

    /// `query` may be an id, a 1-based number from `displays()`, or part of the name. nil/"" = all.
    private func targets(_ query: String?) throws -> [ExternalDisplay] {
        let all = DisplayDiscovery.externalDisplays()
        guard !all.isEmpty else { throw MonitorError.noExternalDisplays }
        guard let query, !query.isEmpty, query.lowercased() != "all" else { return all }
        if let d = all.first(where: { $0.id == query }) { return [d] }
        if let n = Int(query), n >= 1, n <= all.count { return [all[n - 1]] }
        let matches = all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        if !matches.isEmpty { return matches }
        throw MonitorError.displayNotFound(query)
    }

    // MARK: Power

    @discardableResult
    public func setPower(_ on: Bool, displayID: String? = nil, config: AppConfig = ConfigStore.load()) throws -> String {
        try locked {
            // Waking the Mac's display pipeline first makes "on" reliable even if macOS
            // had put the displays to sleep in the meantime.
            if on { Self.declareUserActivity() }

            switch config.method {
            case .displaySleep:
                if on {
                    return "Displays woken"
                }
                try Self.run("/usr/bin/pmset", ["displaysleepnow"])
                return "Displays put to sleep"

            case .ddc:
                let list = try targets(displayID)
                var failed: [String] = []
                var done: [String] = []
                for display in list {
                    let value: UInt16 = on ? 0x01 : UInt16(config.ddcOffValue)
                    if DDC.write(display.service, vcp: DDC.vcpPowerMode, value: value) {
                        ConfigStore.setLastKnownPower(on, for: display.id)
                        done.append(display.name)
                    } else {
                        failed.append(display.name)
                    }
                }
                if done.isEmpty { throw MonitorError.ddcFailed(failed) }
                var message = "\(done.joined(separator: ", ")) turned \(on ? "on" : "off")"
                if !failed.isEmpty { message += " (no response from \(failed.joined(separator: ", ")))" }
                return message
            }
        }
    }

    @discardableResult
    public func toggle(displayID: String? = nil, config: AppConfig = ConfigStore.load()) throws -> String {
        switch config.method {
        case .displaySleep:
            let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
            return try setPower(asleep, displayID: displayID, config: config)
        case .ddc:
            let states = status(displayID: displayID)
            // Unknown counts as "on" so the first toggle turns things off.
            let anyOn = states.isEmpty || states.contains { $0.isOn ?? true }
            return try setPower(!anyOn, displayID: displayID, config: config)
        }
    }

    public func status(displayID: String? = nil) -> [MonitorStatus] {
        locked {
            guard let list = try? targets(displayID) else { return [] }
            let cache = ConfigStore.lastKnownPower()
            return list.map { display in
                // Valid power-mode values are 0x01…0x05. Some monitors (e.g. Samsung Odyssey)
                // answer the read with 0, which means "not supported", not "off".
                if let reply = DDC.read(display.service, vcp: DDC.vcpPowerMode), (0x01...0x05).contains(reply.current) {
                    let on = reply.current == 0x01
                    ConfigStore.setLastKnownPower(on, for: display.id)
                    return MonitorStatus(id: display.id, name: display.name, isOn: on, source: "monitor")
                }
                if let cached = cache[display.id] {
                    return MonitorStatus(id: display.id, name: display.name, isOn: cached, source: "last known")
                }
                return MonitorStatus(id: display.id, name: display.name, isOn: nil, source: "unknown")
            }
        }
    }

    // MARK: Raw VCP access (CLI / debugging)

    public func readVCP(_ vcp: UInt8, displayID: String? = nil) throws -> (current: UInt16, max: UInt16) {
        try locked {
            guard let display = try targets(displayID).first else { throw MonitorError.noExternalDisplays }
            guard let r = DDC.read(display.service, vcp: vcp) else { throw MonitorError.ddcFailed([display.name]) }
            return r
        }
    }

    public func writeVCP(_ vcp: UInt8, value: UInt16, displayID: String? = nil) throws {
        try locked {
            for display in try targets(displayID) {
                guard DDC.write(display.service, vcp: vcp, value: value) else { throw MonitorError.ddcFailed([display.name]) }
            }
        }
    }

    // MARK: Helpers

    /// Equivalent of moving the mouse: wakes sleeping displays.
    public static func declareUserActivity() {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity("Remote Monitor Control" as CFString,
                                                      kIOPMUserActiveLocal, &assertionID)
        if result == kIOReturnSuccess {
            let id = assertionID
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { IOPMAssertionRelease(id) }
        }
    }

    static func run(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw MonitorError.commandFailed("\(path) exited with status \(process.terminationStatus)")
        }
    }
}
