//
//  MonitorProfile.swift
//  Remote Monitor Control
//
//  Works out how to control each monitor. Two sources of information:
//
//   1. The manufacturer ID from the monitor's EDID ("SAM", "GSM", "DEL", …).
//   2. The DDC/CI capabilities string the monitor reports about itself, e.g.
//        (prot(monitor)type(lcd)model(LEMON23)cmds(01 02 03 07 0C E3 F3)
//         vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60(11 0F ) 62 87 8D CC)…)
//      which lists every VCP code it supports and, for some, the allowed values.
//
//  With the Automatic power method the app uses DDC power control (0xD6) only when
//  the monitor says it supports it and its brand doesn't wake back up while the Mac
//  is still sending video; otherwise it turns off the video signal first.
//
//  To add a brand, add an entry to `BrandQuirks.table`.
//

import Foundation

// MARK: - Capabilities string

public struct MonitorCapabilities: Codable, Equatable, Sendable {
    public let raw: String
    /// Supported VCP codes, each with the values listed for it (often empty).
    public let vcp: [UInt8: [UInt16]]
    public let model: String?

    public init(raw: String) {
        self.raw = raw
        self.vcp = Self.parseVCP(raw)
        self.model = Self.group(named: "model", in: raw)?.trimmingCharacters(in: .whitespaces)
    }

    public func supports(_ code: UInt8) -> Bool { vcp[code] != nil }

    /// Input values (VCP 0x60) the monitor lists, in the order it lists them.
    public var inputs: [UInt16] { vcp[0x60] ?? [] }

    /// Contents of a top-level group such as `model(...)` or `vcp(...)`, with nesting.
    static func group(named name: String, in text: String) -> String? {
        let lower = text.lowercased()
        var searchStart = lower.startIndex
        while let range = lower.range(of: name + "(", range: searchStart..<lower.endIndex) {
            // Make sure we matched a whole name, not the tail of another one ("mccs_vcp(").
            if range.lowerBound != lower.startIndex {
                let before = lower[lower.index(before: range.lowerBound)]
                if before.isLetter || before == "_" {
                    searchStart = range.upperBound
                    continue
                }
            }
            var depth = 1
            var i = range.upperBound
            while i < text.endIndex {
                let c = text[i]
                if c == "(" { depth += 1 }
                if c == ")" {
                    depth -= 1
                    if depth == 0 { return String(text[range.upperBound..<i]) }
                }
                i = text.index(after: i)
            }
            // Some monitors never close the group: take the rest.
            return String(text[range.upperBound...])
        }
        return nil
    }

    static func parseVCP(_ raw: String) -> [UInt8: [UInt16]] {
        guard let body = group(named: "vcp", in: raw) else { return [:] }
        let chars = Array(body)
        var result: [UInt8: [UInt16]] = [:]
        var lastCode: UInt8?
        var i = 0

        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }

        /// Skips a parenthesised group starting at chars[i] == "(".
        func skipGroup() {
            var depth = 0
            while i < chars.count {
                if chars[i] == "(" { depth += 1 }
                if chars[i] == ")" { depth -= 1; if depth == 0 { i += 1; return } }
                i += 1
            }
        }

        while i < chars.count {
            let c = chars[i]
            if isWordChar(c) {
                var word = ""
                while i < chars.count, isWordChar(chars[i]) { word.append(chars[i]); i += 1 }
                if word.count <= 2, let code = UInt8(word, radix: 16) {
                    result[code] = result[code] ?? []
                    lastCode = code
                } else {
                    // A named section that some monitors leave inside vcp(...), such as
                    // "mccs_ver(2.0)": not a VCP code, so skip it and its group.
                    lastCode = nil
                    if i < chars.count, chars[i] == "(" { skipGroup() }
                }
            } else if c == "(" {
                // Values listed for the preceding code, e.g. "60(11 0F)".
                guard let code = lastCode else { skipGroup(); continue }
                i += 1
                var values: [UInt16] = []
                var token = ""
                while i < chars.count, chars[i] != ")" {
                    if chars[i] == "(" { skipGroup(); continue }
                    if chars[i].isHexDigit { token.append(chars[i]) } else if !token.isEmpty {
                        if let v = UInt16(token, radix: 16) { values.append(v) }
                        token = ""
                    }
                    i += 1
                }
                if let v = UInt16(token, radix: 16), !token.isEmpty { values.append(v) }
                i += 1
                result[code] = values
                lastCode = nil
            } else {
                i += 1
            }
        }
        return result
    }
}

// MARK: - Brands

public struct BrandQuirks: Sendable {
    public let name: String
    /// The monitor accepts DDC standby but wakes straight back up while it still
    /// receives video, so "off" must also stop the Mac's video signal.
    public let wakesOnSignal: Bool
    /// The monitor switches inputs with LG's alternate command (VCP 0xF4 sent from
    /// I2C source address 0x50) instead of the standard VCP 0x60.
    public let lgAlternateInput: Bool

    public init(name: String, wakesOnSignal: Bool = false, lgAlternateInput: Bool = false) {
        self.name = name
        self.wakesOnSignal = wakesOnSignal
        self.lgAlternateInput = lgAlternateInput
    }

    /// EDID manufacturer IDs → brand behaviour. Unknown IDs use the standard rules.
    public static let table: [String: BrandQuirks] = [
        "SAM": BrandQuirks(name: "Samsung", wakesOnSignal: true),
        "SEC": BrandQuirks(name: "Samsung", wakesOnSignal: true),
        "GSM": BrandQuirks(name: "LG", lgAlternateInput: true),
        "DEL": BrandQuirks(name: "Dell"),
        "AUS": BrandQuirks(name: "ASUS"),
        "ACI": BrandQuirks(name: "ASUS"),
        "ACR": BrandQuirks(name: "Acer"),
        "BNQ": BrandQuirks(name: "BenQ"),
        "HWP": BrandQuirks(name: "HP"),
        "HPN": BrandQuirks(name: "HP"),
        "LEN": BrandQuirks(name: "Lenovo"),
        "PHL": BrandQuirks(name: "Philips"),
        "AOC": BrandQuirks(name: "AOC"),
        "MSI": BrandQuirks(name: "MSI"),
        "GBT": BrandQuirks(name: "Gigabyte"),
        "VSC": BrandQuirks(name: "ViewSonic"),
        "IVM": BrandQuirks(name: "iiyama"),
        "EIZ": BrandQuirks(name: "EIZO"),
        "ENC": BrandQuirks(name: "EIZO"),
        "SNY": BrandQuirks(name: "Sony"),
        "HKC": BrandQuirks(name: "HKC"),
        "KTC": BrandQuirks(name: "KTC"),
        "XMI": BrandQuirks(name: "Xiaomi"),
    ]

    public static func lookup(_ manufacturerID: String?) -> BrandQuirks {
        guard let id = manufacturerID?.uppercased(), !id.isEmpty else { return BrandQuirks(name: "Unknown brand") }
        return table[id] ?? BrandQuirks(name: id)
    }
}

// MARK: - Resolved profile

public enum InputStyle: String, Codable, Sendable {
    /// Standard MCCS: VCP 0x60, values from `InputSource`.
    case standard
    /// LG: VCP 0xF4 from I2C source address 0x50, with LG's own values.
    case lgAlternate

    /// LG's input values for the standard inputs.
    static func lgValue(for standard: UInt16) -> UInt16 {
        switch standard & 0xFF {
        case 0x11: return 0x90   // HDMI 1
        case 0x12: return 0x91   // HDMI 2
        case 0x0F: return 0xD0   // DisplayPort 1
        case 0x10, 0x1B: return 0xD1   // DisplayPort 2 / USB-C
        default: return standard   // already an LG code (e.g. 0x90) or something custom
        }
    }
}

public struct MonitorProfile: Sendable {
    public let brand: String
    public let manufacturerID: String?
    public let capabilities: MonitorCapabilities?
    /// The method Automatic uses for this monitor (.ddc or .ddcAndSignalOff).
    public let automaticPowerMethod: PowerMethod
    public let inputStyle: InputStyle
    /// One line explaining the choice, shown by `monitorctl info` and in the menu.
    public let reason: String

    public var supportsDDCPower: Bool? { capabilities.map { $0.supports(0xD6) } }

    static func resolve(manufacturerID: String?, capabilities: MonitorCapabilities?) -> MonitorProfile {
        let quirks = BrandQuirks.lookup(manufacturerID)

        let power: PowerMethod
        let reason: String
        switch (capabilities?.supports(0xD6), quirks.wakesOnSignal) {
        case (true?, false):
            power = .ddc
            reason = "supports DDC power control"
        case (true?, true):
            power = .ddcAndSignalOff
            reason = "\(quirks.name) monitors wake up again while the video signal is on"
        case (false?, _):
            power = .ddcAndSignalOff
            reason = "doesn't list DDC power control, so the video signal is turned off too"
        case (nil, true):
            power = .ddcAndSignalOff
            reason = "\(quirks.name) monitors wake up again while the video signal is on"
        case (nil, false):
            power = .ddcAndSignalOff
            reason = "couldn't read its capabilities, so the video signal is turned off too"
        }

        // LG's alternate input command is only needed on models that don't list VCP 0x60.
        let input: InputStyle =
            quirks.lgAlternateInput && capabilities?.supports(0x60) == false ? .lgAlternate : .standard

        return MonitorProfile(brand: quirks.name, manufacturerID: manufacturerID, capabilities: capabilities,
                              automaticPowerMethod: power, inputStyle: input, reason: reason)
    }
}

// MARK: - Lookup with cache

extension MonitorController {
    /// The profile for a display. The capabilities string is read once over DDC (it
    /// takes about a second) and cached in Application Support; pass `refresh: true`
    /// to read it again.
    public func profile(for display: ExternalDisplay, refresh: Bool = false) -> MonitorProfile {
        locked {
            var cache = ConfigStore.capabilitiesCache()
            var raw = refresh ? nil : cache[display.id]
            if raw == nil, let read = DDC.capabilities(display.service) {
                raw = read
                cache[display.id] = read
                ConfigStore.saveCapabilitiesCache(cache)
            }
            let caps = raw.map(MonitorCapabilities.init(raw:))
            return MonitorProfile.resolve(manufacturerID: display.manufacturerID, capabilities: caps)
        }
    }

    /// The power method actually used for `display` under `config`.
    func effectiveMethod(for display: ExternalDisplay, config: AppConfig) -> PowerMethod {
        config.method == .automatic ? profile(for: display).automaticPowerMethod : config.method
    }
}
