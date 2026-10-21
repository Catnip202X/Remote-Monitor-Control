//
//  ShortcutExporter.swift
//  Remote Monitor Control
//
//  Generates ready-to-import Apple Shortcuts (.shortcut files) for iPhone / iPad /
//  Apple Watch / another Mac. Each one calls this Mac's built-in remote server
//  ("Get Contents of URL") and shows the reply. Files are signed with
//  /usr/bin/shortcuts so they can be imported anywhere.
//

import Foundation
import SystemConfiguration

public enum ShortcutExporter {
    public struct Result {
        public let files: [URL]
        public let signed: Bool
        public let message: String
    }

    struct Item {
        let name: String
        let path: String
        let showResult: Bool
        let color: Int
        let glyph: Int
    }

    static let items: [Item] = [
        Item(name: "Remote Monitor Control On/Off", path: "toggle", showResult: false, color: 4_282_601_983, glyph: 59_511),
        Item(name: "Remote Monitor Control Input Switching", path: "toggle-input", showResult: false, color: 4_271_458_815, glyph: 59_511),
        Item(name: "Monitor Status", path: "status", showResult: true, color: 2_071_128_575, glyph: 59_511),
        // Named the way you'd say them: Siri runs a shortcut when you say its exact name,
        // e.g. "Hey Siri, turn off my monitor".
        Item(name: "Turn Off My Monitor", path: "off", showResult: false, color: 4_282_601_983, glyph: 59_511),
        Item(name: "Turn On My Monitor", path: "on", showResult: false, color: 4_282_601_983, glyph: 59_511),
        Item(name: "Switch Inputs for My Monitor", path: "toggle-input", showResult: false, color: 4_271_458_815, glyph: 59_511),
    ]

    /// e.g. "my-mac.local"
    public static func localHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return name + ".local"
        }
        return ProcessInfo.processInfo.hostName
    }

    public static func baseURL(host: String? = nil, config: AppConfig = ConfigStore.load()) -> String {
        "http://\(host ?? localHostName()):\(config.port)"
    }

    public static func commandURL(_ path: String, host: String? = nil, config: AppConfig = ConfigStore.load()) -> String {
        "\(baseURL(host: host, config: config))/\(path)\(path.contains("?") ? "&" : "?")token=\(config.token)"
    }

    public static func export(to directory: URL, host: String? = nil, config: AppConfig = ConfigStore.load()) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = fm.temporaryDirectory.appendingPathComponent("rmc-shortcuts-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var files: [URL] = []
        var allSigned = true
        var signError = ""

        for item in items {
            let url = commandURL(item.path, host: host, config: config)
            let plist = workflow(url: url, item: item)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            // "/" can't appear in a file name. A ":" on disk is shown as "/" by Finder.
            let fileName = item.name.replacingOccurrences(of: "/", with: ":") + ".shortcut"
            let unsigned = tmp.appendingPathComponent(fileName)
            try data.write(to: unsigned)

            let output = directory.appendingPathComponent(fileName)
            try? fm.removeItem(at: output)
            let (ok, err) = sign(input: unsigned, output: output)
            if !ok {
                allSigned = false
                signError = err
                try fm.copyItem(at: unsigned, to: output)
            }
            files.append(output)
        }

        var message = "Exported \(files.count) shortcuts to \(directory.path)\nThey call \(baseURL(host: host, config: config))"
        if !allSigned {
            message += "\n⚠️ Signing failed (\(signError.trimmingCharacters(in: .whitespacesAndNewlines))). Unsigned shortcuts can't be imported on iPhone — sign in to iCloud on this Mac and export again, or build them by hand (see README)."
        }
        return Result(files: files, signed: allSigned, message: message)
    }

    // MARK: - Internals

    static func sign(input: URL, output: URL) -> (Bool, String) {
        for mode in ["anyone", "people-who-know-me"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["sign", "--mode", mode, "--input", input.path, "--output", output.path]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return (false, error.localizedDescription)
            }
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) {
                return (true, "")
            }
            if mode == "people-who-know-me" { return (false, err) }
        }
        return (false, "unknown error")
    }

    static func workflow(url: String, item: Item) -> [String: Any] {
        let uuid = UUID().uuidString
        let download: [String: Any] = [
            "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
            "WFWorkflowActionParameters": [
                "UUID": uuid,
                "WFURL": url,
                "WFHTTPMethod": "GET",
                "ShowHeaders": false,
            ] as [String: Any],
        ]

        let replyText: [String: Any] = [
            "Value": [
                "string": "\u{FFFC}",
                "attachmentsByRange": [
                    "{0, 1}": [
                        "Type": "ActionOutput",
                        "OutputName": "Contents of URL",
                        "OutputUUID": uuid,
                    ],
                ],
            ] as [String: Any],
            "WFSerializationType": "WFTextTokenString",
        ]

        let final: [String: Any]
        if item.showResult {
            final = [
                "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
                "WFWorkflowActionParameters": ["Text": replyText],
            ]
        } else {
            final = [
                "WFWorkflowActionIdentifier": "is.workflow.actions.notification",
                "WFWorkflowActionParameters": [
                    "WFNotificationActionTitle": item.name,
                    "WFNotificationActionBody": replyText,
                    "WFNotificationActionSound": false,
                ] as [String: Any],
            ]
        }

        return [
            "WFWorkflowActions": [download, final],
            "WFWorkflowClientVersion": "2605.0.5",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": item.color,
                "WFWorkflowIconGlyphNumber": item.glyph,
            ],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowTypes": ["Watch"],
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowHasShortcutInputVariables": false,
        ]
    }
}
