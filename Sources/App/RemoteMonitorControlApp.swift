//
//  RemoteMonitorControlApp.swift
//  Remote Monitor Control
//
//  Menu-bar app. Lives next to the clock, no Dock icon.
//

import AppKit
import SwiftUI

@main
struct RemoteMonitorControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppModel.shared.start()
            urls.forEach { AppModel.shared.handle(url: $0) }
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "display")
                    .font(.title2)
                Text("Remote Monitor Control")
                    .font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 8) {
                Button { model.toggle() } label: {
                    Label("Toggle Power", systemImage: "power").frame(maxWidth: .infinity)
                }
                Button { model.toggleInput() } label: {
                    Label("Toggle Input", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .disabled(model.busy)

            VStack(alignment: .leading, spacing: 4) {
                inputPicker("Input A (this Mac)", value: model.config.inputA) { v in model.update { $0.inputA = v; $0.inputsAutoDetected = true } }
                inputPicker("Input B (other device)", value: model.config.inputB) { v in model.update { $0.inputB = v; $0.inputsAutoDetected = true } }
            }
            .font(.callout)

            monitorsSection

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Picker("Method", selection: Binding(
                    get: { model.config.method },
                    set: { value in model.update { $0.method = value } })) {
                    ForEach(PowerMethod.allCases) { Text($0.label).tag($0) }
                }
                if model.config.method != .displaySleep {
                    Picker("Off mode", selection: Binding(
                        get: { model.config.ddcOffValue },
                        set: { value in model.update { $0.ddcOffValue = value } })) {
                        Text("Standby (0x04) · can wake remotely").tag(UInt8(0x04))
                        Text("Power off (0x05)").tag(UInt8(0x05))
                    }
                }
            }

            Divider()

            remoteSection

            Divider()

            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))

            if let message = model.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            model.start()
            model.refresh()
        }
    }

    private func inputPicker(_ title: String, value: UInt16, set: @escaping (UInt16) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: set)) {
            ForEach(InputSource.common) { Text($0.label).tag($0.value) }
            if !InputSource.common.contains(where: { $0.value == value }) {
                Text(InputSource.describe(value)).tag(value)
            }
        }
    }

    @ViewBuilder private var monitorsSection: some View {
        if model.statuses.isEmpty {
            Text("No external DDC/CI monitor detected yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 6) {
                ForEach(model.statuses) { status in
                    HStack {
                        Circle()
                            .fill(status.isOn == true ? Color.green : status.isOn == false ? Color.gray : Color.orange)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(status.name).lineLimit(1)
                            Text("\(status.stateText) · \(status.source)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Input") {
                            ForEach(InputSource.common) { source in
                                Button(source.label) { model.switchInput(source.value, displayID: status.id) }
                            }
                        }
                        .fixedSize()
                        Button("On") { model.setPower(true, displayID: status.id) }
                        Button("Off") { model.setPower(false, displayID: status.id) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Remote control from iPhone / network", isOn: Binding(
                get: { model.config.serverEnabled },
                set: { value in model.update { $0.serverEnabled = value } }))

            if model.config.serverEnabled {
                Text("\(model.serverState) · http://\(model.hostName):\(String(model.config.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Toggle("Keep Mac awake so remote commands work", isOn: Binding(
                    get: { model.config.keepMacAwake },
                    set: { value in model.update { $0.keepMacAwake = value } }))
                    .font(.callout)

                HStack {
                    Button("Export iPhone Shortcuts…") { model.exportShortcuts() }
                    Menu("Copy URL") {
                        Button("Toggle Power URL") { model.copyURL("toggle") }
                        Button("Toggle Input URL") { model.copyURL("toggle-input") }
                        Button("Off URL") { model.copyURL("off") }
                        Button("On URL") { model.copyURL("on") }
                        Button("Status URL") { model.copyURL("status") }
                        Divider()
                        Button("New Security Token") { model.regenerateToken() }
                    }
                    .fixedSize()
                }
                .controlSize(.small)
            }
        }
    }
}
