//
//  AppModel.swift
//  Remote Monitor Control
//

import AppKit
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var statuses: [MonitorStatus] = []
    @Published var config: AppConfig = ConfigStore.load()
    @Published var serverState: String = "Stopped"
    @Published var lastMessage: String?
    @Published var busy = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var usbDevices: [USBDevice] = []

    private let server = RemoteServer()
    private let usbWatcher = USBWatcher()
    private var awakeAssertion: IOPMAssertionID = 0
    private var started = false

    var menuIcon: String {
        if !statuses.isEmpty, statuses.allSatisfy({ $0.isOn == false }) { return "moon.zzz" }
        return "display"
    }

    var hostName: String { ShortcutExporter.localHostName() }

    func start() {
        guard !started else { return }
        started = true
        server.onStateChange = { state in
            Task { @MainActor in AppModel.shared.serverState = state }
        }
        applyServer()
        applyKeepAwake()
        applyUSBFollow()
        refresh()
        refreshUSBDevices()
        // `monitorctl` posts this after changing settings.
        DistributedNotificationCenter.default().addObserver(
            forName: ConfigStore.changedNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.reloadConfig() }
        }
        DispatchQueue.global(qos: .utility).async {
            MonitorController.shared.autoDetectInputPair()
            let cfg = ConfigStore.load()
            Task { @MainActor in
                AppModel.shared.config.inputA = cfg.inputA
                AppModel.shared.config.inputB = cfg.inputB
                AppModel.shared.config.inputsAutoDetected = cfg.inputsAutoDetected
            }
        }
    }

    // MARK: Monitor actions

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = MonitorController.shared.status()
            Task { @MainActor in AppModel.shared.statuses = s }
        }
    }

    func setPower(_ on: Bool, displayID: String? = nil) {
        perform { try MonitorController.shared.setPower(on, displayID: displayID) }
    }

    func toggle(displayID: String? = nil) {
        perform { try MonitorController.shared.toggle(displayID: displayID) }
    }

    func toggleInput(displayID: String? = nil) {
        perform { try MonitorController.shared.toggleInput(displayID: displayID) }
    }

    func switchInput(_ value: UInt16, displayID: String? = nil) {
        perform { try MonitorController.shared.setInput(value, displayID: displayID) }
    }

    private func perform(_ action: @escaping @Sendable () throws -> String) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do { message = try action() } catch { message = "⚠️ " + error.localizedDescription }
            Task { @MainActor in
                AppModel.shared.lastMessage = message
                AppModel.shared.busy = false
                AppModel.shared.refresh()
            }
        }
    }

    /// remotemonitor://on | off | toggle   (optional ?display=…)
    func handle(url: URL) {
        let command = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let display = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "display" })?.value
        switch command {
        case "on": setPower(true, displayID: display)
        case "off": setPower(false, displayID: display)
        case "toggle", "toggle-power": toggle(displayID: display)
        case "toggle-input": toggleInput(displayID: display)
        case "input":
            let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "source" })?.value ?? ""
            if let value = InputSource.parseValue(source) {
                switchInput(value, displayID: display)
            } else {
                lastMessage = "Unknown input “\(source)”"
            }
        default: lastMessage = "Unknown URL command “\(command)”"
        }
    }

    // MARK: Settings

    func update(_ mutate: (inout AppConfig) -> Void) {
        let old = config
        mutate(&config)
        ConfigStore.save(config)
        if old.serverEnabled != config.serverEnabled || old.port != config.port || old.token != config.token {
            applyServer()
        }
        applyKeepAwake()
        if old.followUSB != config.followUSB { applyUSBFollow() }
    }

    func reloadConfig() {
        let old = config
        config = ConfigStore.load()
        if old.serverEnabled != config.serverEnabled || old.port != config.port || old.token != config.token {
            applyServer()
        }
        applyKeepAwake()
        if old.followUSB != config.followUSB { applyUSBFollow() }
        refresh()
    }

    // MARK: Follow USB switch

    func refreshUSBDevices() {
        usbDevices = USBDevice.connected().filter { !$0.isHub }
    }

    func setFollowUSB(_ key: String?) {
        let name = key.flatMap { k in usbDevices.first { $0.key == k }?.name }
        update {
            $0.followUSB = key
            $0.followUSBName = name
        }
        if let name {
            lastMessage = "Following \(name): unplugged → \(InputSource.describe(config.inputB)), back → \(InputSource.describe(config.inputA))"
        } else {
            lastMessage = "Not following a USB device"
        }
    }

    private func applyUSBFollow() {
        guard let key = config.followUSB, let ids = USBDevice.parseKey(key) else {
            usbWatcher.stop()
            return
        }
        usbWatcher.start(vendorID: ids.vendor, productID: ids.product) { present in
            DispatchQueue.global(qos: .userInitiated).async {
                let message = MonitorController.shared.followUSB(present: present)
                Task { @MainActor in
                    AppModel.shared.lastMessage = "USB switch \(present ? "back on this Mac" : "moved away"): " + message
                    AppModel.shared.refresh()
                    AppModel.shared.refreshUSBDevices()
                }
            }
        }
    }

    func regenerateToken() {
        update { $0.token = AppConfig.makeToken() }
        lastMessage = "New token created — export the iPhone shortcuts again."
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastMessage = "⚠️ Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func copyURL(_ path: String) {
        let url = ShortcutExporter.commandURL(path, config: config)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        lastMessage = "Copied \(path) URL"
    }

    func exportShortcuts() {
        busy = true
        let cfg = config
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Remote Monitor Shortcuts", isDirectory: true)
            let message: String
            let files: [URL]
            do {
                let result = try ShortcutExporter.export(to: dir, config: cfg)
                message = result.message
                files = result.files
            } catch {
                message = "⚠️ Export failed: \(error.localizedDescription)"
                files = []
            }
            Task { @MainActor in
                AppModel.shared.busy = false
                AppModel.shared.lastMessage = message
                if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
            }
        }
    }

    // MARK: Remote server / keep awake

    private func applyServer() {
        guard config.serverEnabled else {
            server.stop()
            serverState = "Off"
            return
        }
        server.start(port: config.port, handler: Self.makeHandler(token: config.token))
    }

    nonisolated static func makeHandler(token: String) -> RemoteServer.Handler {
        return { path, query, givenToken in
            if path == "/" || path == "/health" {
                return (200, "Remote Monitor Control is running. Commands: /toggle /toggle-input /on /off /status /input?source=hdmi1")
            }
            guard givenToken == token else { return (401, "Unauthorized: missing or wrong token") }
            let display = query["display"]
            do {
                let body: String
                switch path {
                case "/on": body = try MonitorController.shared.setPower(true, displayID: display)
                case "/off": body = try MonitorController.shared.setPower(false, displayID: display)
                case "/toggle", "/toggle-power": body = try MonitorController.shared.toggle(displayID: display)
                case "/toggle-input": body = try MonitorController.shared.toggleInput(displayID: display)
                case "/status":
                    let s = MonitorController.shared.status(displayID: display)
                    if s.isEmpty {
                        body = "No external monitor found"
                    } else if s.count == 1 {
                        body = "\(s[0].name) is \(s[0].stateText)"
                    } else {
                        body = s.map { "\($0.name): \($0.stateText)" }.joined(separator: "\n")
                    }
                case "/input":
                    if let source = query["source"] {
                        guard let value = InputSource.parseValue(source) else {
                            return (400, "Unknown input “\(source)”. Try hdmi1, hdmi2, dp1, dp2, usbc or a number.")
                        }
                        body = try MonitorController.shared.setInput(value, displayID: display)
                    } else {
                        body = MonitorController.shared.currentInputs(displayID: display)
                            .map { "\($0.name): \($0.value.map(InputSource.describe) ?? "unknown")" }
                            .joined(separator: "\n")
                    }
                default:
                    return (404, "Unknown command. Use /toggle, /toggle-input, /on, /off, /status or /input?source=hdmi1")
                }
                Task { @MainActor in
                    AppModel.shared.lastMessage = "Remote: " + body
                    AppModel.shared.refresh()
                }
                return (200, body)
            } catch {
                return (500, error.localizedDescription)
            }
        }
    }

    private func applyKeepAwake() {
        let want = config.serverEnabled && config.keepMacAwake
        if want, awakeAssertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Remote Monitor Control is listening for remote commands" as CFString,
                &id)
            if result == kIOReturnSuccess { awakeAssertion = id }
        } else if !want, awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
    }
}
