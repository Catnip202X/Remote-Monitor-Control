//
//  TelevisionAccessory.swift
//  Remote Monitor Control
//
//  The monitor as a HomeKit Television: the power button is the monitor's power
//  and each input (HDMI 1, DisplayPort…) is an input source you can pick in the
//  Home app, in Control Center's remote, in scenes and in automations.
//
//  Accessory layout (aid 1):
//    iid 1    Accessory Information      2 Identify · 3 Manufacturer · 4 Model · 5 Name · 6 Serial · 7 Firmware
//    iid 8    Protocol Information       9 Version
//    iid 10   Television (primary)       11 Active · 12 Active Identifier · 13 Configured Name
//                                        14 Sleep Discovery Mode · 15 Remote Key · 16 Name
//    iid 100+10n  Input Source n         +1 Configured Name · +2 Input Source Type · +3 Is Configured
//                                        +4 Current Visibility State · +5 Identifier · +6 Name
//

import Foundation

final class TelevisionAccessory {
    static let aid = 1
    /// HomeKit accessory category: Television.
    static let category = 31

    enum IID {
        static let info = 1
        static let identify = 2
        static let manufacturer = 3
        static let model = 4
        static let name = 5
        static let serial = 6
        static let firmware = 7
        static let protocolService = 8
        static let protocolVersion = 9
        static let tvService = 10
        static let active = 11
        static let activeIdentifier = 12
        static let configuredName = 13
        static let sleepDiscovery = 14
        static let remoteKey = 15
        static let tvName = 16
        static let inputBase = 100
        static let inputStride = 10
    }

    private enum InputField: Int {
        case service = 0, configuredName, sourceType, isConfigured, visibility, identifier, name
    }

    struct Input {
        let code: UInt16
        let defaultName: String
        let type: Int
    }

    private unowned let server: HAPServer
    private(set) var inputs: [Input] = []
    private var monitorName = "Monitor"
    private var brand = "Remote Monitor Control"
    private var active = 0
    private var activeIdentifier = 0

    init(server: HAPServer) {
        self.server = server
    }

    var displayName: String { server.identity.tvName ?? monitorName }
    var model: String { monitorName }

    /// Changes whenever services are added or removed, so Home re-reads the layout.
    var layoutHash: String { "tv1:" + inputs.map { String($0.code) }.joined(separator: ",") }

    // MARK: - Layout

    /// Reads the monitor's name and the inputs it lists. Call on the server queue.
    func rebuild() {
        let controller = MonitorController.shared
        let display = controller.displays().first
        monitorName = display?.name ?? "Monitor"

        var codes: [UInt16] = []
        if let display {
            let profile = controller.profile(for: display)
            brand = profile.brand
            codes = profile.capabilities?.inputs.map { $0 & 0xFF } ?? []
        }
        let config = ConfigStore.load()
        codes.append(config.inputA & 0xFF)
        codes.append(config.inputB & 0xFF)
        if Set(codes).count < 2 { codes += InputSource.common.map(\.value) }
        var seen = Set<UInt16>()
        codes = codes.filter { $0 != 0 && seen.insert($0).inserted }

        inputs = codes.prefix(20).map { code in
            Input(code: code,
                  defaultName: InputSource.from(value: code)?.label ?? String(format: "Input 0x%02X", code),
                  type: Self.sourceType(for: code))
        }
        if activeIdentifier == 0 { activeIdentifier = Int(config.inputA & 0xFF) }
        _ = refreshFromMonitor()
    }

    /// HomeKit input source types: 0 other, 3 HDMI, 6 component video, 7 DVI, 9 USB.
    private static func sourceType(for code: UInt16) -> Int {
        switch InputSource.from(value: code) {
        case .hdmi1, .hdmi2: return 3
        case .dvi1, .dvi2: return 7
        case .usbC: return 9
        case .vga1: return 6
        default: return 0
        }
    }

    private func inputLocation(_ iid: Int) -> (index: Int, field: InputField)? {
        guard iid >= IID.inputBase else { return nil }
        let index = (iid - IID.inputBase) / IID.inputStride
        guard index < inputs.count, let field = InputField(rawValue: (iid - IID.inputBase) % IID.inputStride) else {
            return nil
        }
        return (index, field)
    }

    private func inputName(_ input: Input) -> String {
        server.identity.inputNames[String(input.code)] ?? input.defaultName
    }

    // MARK: - Monitor state

    /// Reads power and input from the monitor. Returns the iids whose values changed.
    func refreshFromMonitor() -> [Int] {
        let controller = MonitorController.shared
        var changed: [Int] = []
        if let isOn = controller.status().first?.isOn {
            let value = isOn ? 1 : 0
            if value != active {
                active = value
                changed.append(IID.active)
            }
        }
        var current = controller.currentInputs().first?.value
        if current == nil, let id = controller.displays().first?.id {
            current = ConfigStore.lastKnownInput()[id]
        }
        if let current, inputs.contains(where: { $0.code == current & 0xFF }) {
            let value = Int(current & 0xFF)
            if value != activeIdentifier {
                activeIdentifier = value
                changed.append(IID.activeIdentifier)
            }
        }
        return changed
    }

    func identify() {
        // Nothing to blink on a monitor; HomeKit only needs the request to succeed.
    }

    // MARK: - Characteristics

    func supportsEvents(_ iid: Int) -> Bool {
        switch iid {
        case IID.active, IID.activeIdentifier, IID.configuredName, IID.sleepDiscovery:
            return true
        default:
            guard let (_, field) = inputLocation(iid) else { return false }
            return [.configuredName, .sourceType, .isConfigured, .visibility].contains(field)
        }
    }

    func read(_ iid: Int) -> Result<Any, HAPStatus> {
        switch iid {
        case IID.identify, IID.remoteKey: return .failure(.writeOnly)
        case IID.manufacturer: return .success(brand)
        case IID.model: return .success(monitorName)
        case IID.name, IID.tvName, IID.configuredName: return .success(displayName)
        case IID.serial: return .success(server.identity.deviceID)
        case IID.firmware: return .success(Self.firmwareVersion)
        case IID.protocolVersion: return .success("1.1.0")
        case IID.active: return .success(active)
        case IID.activeIdentifier: return .success(activeIdentifier)
        case IID.sleepDiscovery: return .success(1)
        default:
            guard let (index, field) = inputLocation(iid) else { return .failure(.notFound) }
            let input = inputs[index]
            switch field {
            case .service: return .failure(.notFound)
            case .configuredName: return .success(inputName(input))
            case .sourceType: return .success(input.type)
            case .isConfigured: return .success(1)
            case .visibility: return .success(0)
            case .identifier: return .success(Int(input.code))
            case .name: return .success(input.defaultName)
            }
        }
    }

    /// Returns the iids whose values changed.
    func write(_ iid: Int, value: Any) -> Result<[Int], HAPStatus> {
        let number = (value as? NSNumber)?.intValue
        switch iid {
        case IID.identify:
            identify()
            return .success([])

        case IID.active:
            guard let number else { return .failure(.invalidValue) }
            let on = number == 1
            do {
                try MonitorController.shared.setPower(on)
            } catch {
                return .failure(.communicationFailure)
            }
            active = on ? 1 : 0
            return .success([IID.active])

        case IID.activeIdentifier:
            guard let number, let input = inputs.first(where: { Int($0.code) == number }) else {
                return .failure(.invalidValue)
            }
            return switchInput(to: input)

        case IID.configuredName:
            guard let name = value as? String, !name.isEmpty else { return .failure(.invalidValue) }
            server.saveIdentity { $0.tvName = name }
            return .success([IID.configuredName])

        case IID.remoteKey:
            guard let number else { return .failure(.invalidValue) }
            return remoteKey(number)

        case IID.sleepDiscovery, IID.manufacturer, IID.model, IID.name, IID.serial, IID.firmware,
             IID.protocolVersion, IID.tvName:
            return .failure(.readOnly)

        default:
            guard let (index, field) = inputLocation(iid) else { return .failure(.notFound) }
            switch field {
            case .configuredName:
                guard let name = value as? String, !name.isEmpty else { return .failure(.invalidValue) }
                let code = String(inputs[index].code)
                server.saveIdentity { $0.inputNames[code] = name }
                return .success([iid])
            case .isConfigured:
                return .success([])
            default:
                return .failure(.readOnly)
            }
        }
    }

    private func switchInput(to input: Input) -> Result<[Int], HAPStatus> {
        do {
            try MonitorController.shared.setInput(input.code)
        } catch {
            return .failure(.communicationFailure)
        }
        activeIdentifier = Int(input.code)
        return .success([IID.activeIdentifier])
    }

    /// Control Center remote: left/right step through the inputs, play/pause flips Input A ⇄ B.
    private func remoteKey(_ key: Int) -> Result<[Int], HAPStatus> {
        guard !inputs.isEmpty else { return .success([]) }
        let index = inputs.firstIndex { Int($0.code) == activeIdentifier } ?? 0
        switch key {
        case 6, 4: // arrow left / up
            return switchInput(to: inputs[(index - 1 + inputs.count) % inputs.count])
        case 7, 5: // arrow right / down
            return switchInput(to: inputs[(index + 1) % inputs.count])
        case 11, 8: // play/pause, select
            do {
                try MonitorController.shared.toggleInput()
            } catch {
                return .failure(.communicationFailure)
            }
            return .success(refreshFromMonitor())
        default:
            return .success([])
        }
    }

    private static var firmwareVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let parts = version.split(separator: ".")
        return parts.count >= 3 ? version : version + String(repeating: ".0", count: 3 - parts.count)
    }

    // MARK: - /accessories

    func accessoriesJSON() -> [String: Any] {
        func ch(_ iid: Int, _ type: String, _ format: String, _ perms: [String],
                _ extra: [String: Any] = [:]) -> [String: Any] {
            var c: [String: Any] = ["iid": iid, "type": type, "format": format, "perms": perms]
            if perms.contains("pr"), case .success(let value) = read(iid) { c["value"] = value }
            extra.forEach { c[$0.key] = $0.value }
            return c
        }
        let binary: [String: Any] = ["minValue": 0, "maxValue": 1, "minStep": 1, "valid-values": [0, 1]]

        var services: [[String: Any]] = [
            ["iid": IID.info, "type": "3E", "characteristics": [
                ch(IID.identify, "14", "bool", ["pw"]),
                ch(IID.manufacturer, "20", "string", ["pr"]),
                ch(IID.model, "21", "string", ["pr"]),
                ch(IID.name, "23", "string", ["pr"]),
                ch(IID.serial, "30", "string", ["pr"]),
                ch(IID.firmware, "52", "string", ["pr"]),
            ]],
            ["iid": IID.protocolService, "type": "A2", "characteristics": [
                ch(IID.protocolVersion, "37", "string", ["pr"]),
            ]],
            ["iid": IID.tvService, "type": "D8", "primary": true,
             "linked": inputs.indices.map { IID.inputBase + $0 * IID.inputStride },
             "characteristics": [
                ch(IID.active, "B0", "uint8", ["pr", "pw", "ev"], binary),
                ch(IID.activeIdentifier, "E7", "uint32", ["pr", "pw", "ev"]),
                ch(IID.configuredName, "E3", "string", ["pr", "pw", "ev"], ["maxLen": 64]),
                ch(IID.sleepDiscovery, "E8", "uint8", ["pr", "ev"], binary),
                ch(IID.remoteKey, "E1", "uint8", ["pw"],
                   ["minValue": 0, "maxValue": 16, "minStep": 1, "valid-values": Array(0...11) + [15]]),
                ch(IID.tvName, "23", "string", ["pr"]),
             ]],
        ]

        for index in inputs.indices {
            let base = IID.inputBase + index * IID.inputStride
            services.append([
                "iid": base, "type": "D9", "characteristics": [
                    ch(base + InputField.configuredName.rawValue, "E3", "string", ["pr", "pw", "ev"], ["maxLen": 64]),
                    ch(base + InputField.sourceType.rawValue, "DB", "uint8", ["pr", "ev"],
                       ["minValue": 0, "maxValue": 10, "minStep": 1]),
                    ch(base + InputField.isConfigured.rawValue, "D6", "uint8", ["pr", "pw", "ev"], binary),
                    ch(base + InputField.visibility.rawValue, "135", "uint8", ["pr", "ev"],
                       ["minValue": 0, "maxValue": 3, "minStep": 1, "valid-values": [0, 1]]),
                    ch(base + InputField.identifier.rawValue, "E6", "uint32", ["pr"]),
                    ch(base + InputField.name.rawValue, "23", "string", ["pr"]),
                ],
            ])
        }
        return ["accessories": [["aid": Self.aid, "services": services]]]
    }
}
