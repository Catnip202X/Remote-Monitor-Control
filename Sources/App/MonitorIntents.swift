//
//  MonitorIntents.swift
//  Remote Monitor Control
//
//  App Intents → these show up automatically as actions in the Shortcuts app
//  (search "Monitor" or "Remote Monitor Control"), in Spotlight and via Siri.
//

import AppIntents
import Foundation

// MARK: - Monitor entity (lets a shortcut pick a specific monitor)

struct MonitorEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Monitor"
    static var defaultQuery = MonitorQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MonitorQuery: EntityQuery {
    func entities(for identifiers: [MonitorEntity.ID]) async throws -> [MonitorEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MonitorEntity] {
        all()
    }

    private func all() -> [MonitorEntity] {
        MonitorController.shared.displays().map { MonitorEntity(id: $0.id, name: $0.name) }
    }
}

private func refreshMenu() async {
    await MainActor.run { AppModel.shared.refresh() }
}

// MARK: - Intents

struct TurnMonitorOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Monitor Off"
    static var description = IntentDescription("Turns an external monitor off over DDC/CI (leave Monitor empty for all monitors).")
    static var openAppWhenRun = false

    @Parameter(title: "Monitor", description: "Leave empty to switch every external monitor.")
    var monitor: MonitorEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Turn off \(\.$monitor)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try MonitorController.shared.setPower(false, displayID: monitor?.id)
        await refreshMenu()
        return .result(dialog: "\(message)")
    }
}

struct TurnMonitorOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Monitor On"
    static var description = IntentDescription("Turns an external monitor back on over DDC/CI (leave Monitor empty for all monitors).")
    static var openAppWhenRun = false

    @Parameter(title: "Monitor", description: "Leave empty to switch every external monitor.")
    var monitor: MonitorEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Turn on \(\.$monitor)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try MonitorController.shared.setPower(true, displayID: monitor?.id)
        await refreshMenu()
        return .result(dialog: "\(message)")
    }
}

struct ToggleMonitorIntent: AppIntent {
    static var title: LocalizedStringResource = "Remote Monitor Control On/Off"
    static var description = IntentDescription("One button: turns the monitor off if it's on, or on if it's off.")
    static var openAppWhenRun = false

    @Parameter(title: "Monitor", description: "Leave empty to switch every external monitor.")
    var monitor: MonitorEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle \(\.$monitor)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try MonitorController.shared.toggle(displayID: monitor?.id)
        await refreshMenu()
        return .result(dialog: "\(message)")
    }
}

struct SetMonitorPowerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Monitor Power"
    static var description = IntentDescription("Turns a monitor on or off — handy when the on/off decision comes from another action or variable.")
    static var openAppWhenRun = false

    @Parameter(title: "Power", default: false, displayName: Bool.IntentDisplayName(true: "On", false: "Off"))
    var power: Bool

    @Parameter(title: "Monitor", description: "Leave empty to switch every external monitor.")
    var monitor: MonitorEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$monitor) \(\.$power)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try MonitorController.shared.setPower(power, displayID: monitor?.id)
        await refreshMenu()
        return .result(dialog: "\(message)")
    }
}

struct GetMonitorPowerIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Monitor On?"
    static var description = IntentDescription("Returns true if the monitor is on. Use it with If in your shortcuts.")
    static var openAppWhenRun = false

    @Parameter(title: "Monitor", description: "Leave empty to check the first external monitor.")
    var monitor: MonitorEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Is \(\.$monitor) on?")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let statuses = MonitorController.shared.status(displayID: monitor?.id)
        guard let first = statuses.first else { throw MonitorError.noExternalDisplays }
        let on = first.isOn ?? false
        return .result(value: on, dialog: "\(first.name) is \(first.stateText)")
    }
}

// MARK: - Input switching (VCP 0x60)

enum MonitorInputOption: String, AppEnum {
    case hdmi1, hdmi2, displayPort1, displayPort2, usbC, custom

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Monitor Input"
    static var caseDisplayRepresentations: [MonitorInputOption: DisplayRepresentation] = [
        .hdmi1: "HDMI 1",
        .hdmi2: "HDMI 2",
        .displayPort1: "DisplayPort 1",
        .displayPort2: "DisplayPort 2",
        .usbC: "USB-C",
        .custom: "Custom code",
    ]

    var source: InputSource? {
        switch self {
        case .hdmi1: return .hdmi1
        case .hdmi2: return .hdmi2
        case .displayPort1: return .displayPort1
        case .displayPort2: return .displayPort2
        case .usbC: return .usbC
        case .custom: return nil
        }
    }
}

struct SwitchMonitorInputIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Monitor Input"
    static var description = IntentDescription("Switches the monitor's input (HDMI, DisplayPort, USB-C…) over DDC/CI. If your monitor uses non-standard codes, pick Custom code and enter the number shown by `monitorctl input`.")
    static var openAppWhenRun = false

    @Parameter(title: "Input", default: .hdmi1)
    var input: MonitorInputOption

    @Parameter(title: "Custom Code", description: "Raw VCP 0x60 value (decimal). Only used when Input is Custom code.")
    var customCode: Int?

    @Parameter(title: "Monitor", description: "Leave empty to switch every external monitor.")
    var monitor: MonitorEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Switch \(\.$monitor) to \(\.$input)") {
            \.$customCode
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value: UInt16
        if let source = input.source {
            value = source.value
        } else if let code = customCode, code >= 0, code <= 0xFFFF {
            value = UInt16(code)
        } else {
            throw MonitorError.commandFailed("Enter a Custom Code (the number from `monitorctl input`).")
        }
        let message = try MonitorController.shared.setInput(value, displayID: monitor?.id)
        await refreshMenu()
        return .result(dialog: "\(message)")
    }
}

struct ToggleMonitorInputIntent: AppIntent {
    static var title: LocalizedStringResource = "Remote Monitor Control Input Switching"
    static var description = IntentDescription("Switches the monitor to the other input: Input A ⇄ Input B (set both in the menu-bar app).")
    static var openAppWhenRun = false

    @Parameter(title: "Monitor", description: "Leave empty to switch every external monitor.")
    var monitor: MonitorEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle input of \(\.$monitor)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try MonitorController.shared.toggleInput(displayID: monitor?.id)
        await refreshMenu()
        return .result(dialog: "\(message)")
    }
}

struct GetMonitorInputIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Monitor Input"
    static var description = IntentDescription("Returns the monitor's current input, e.g. “HDMI 1 (0x11)”.")
    static var openAppWhenRun = false

    @Parameter(title: "Monitor", description: "Leave empty to check the first external monitor.")
    var monitor: MonitorEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get input of \(\.$monitor)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let first = MonitorController.shared.currentInputs(displayID: monitor?.id).first else {
            throw MonitorError.noExternalDisplays
        }
        guard let value = first.value else { throw MonitorError.ddcFailed([first.name]) }
        let text = InputSource.describe(value)
        return .result(value: text, dialog: "\(first.name) is on \(text)")
    }
}

// MARK: - Ready-made App Shortcuts (appear in Shortcuts & Siri with zero setup)

struct MonitorAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMonitorIntent(),
            phrases: [
                "Toggle my monitor with \(.applicationName)",
                "Turn my monitor on or off with \(.applicationName)",
                "\(.applicationName) power",
                "\(.applicationName) On/Off",
            ],
            shortTitle: "Remote Monitor Control On/Off",
            systemImageName: "power")
        AppShortcut(
            intent: ToggleMonitorInputIntent(),
            phrases: [
                "Switch monitor input with \(.applicationName)",
                "Toggle my monitor input with \(.applicationName)",
                "\(.applicationName) input",
                "\(.applicationName) Input Switching",
            ],
            shortTitle: "Remote Monitor Control Input Switching",
            systemImageName: "arrow.left.arrow.right")
    }
}
