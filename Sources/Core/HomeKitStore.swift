//
//  HomeKitStore.swift
//  Remote Monitor Control
//
//  Persistent identity and pairings of the built-in HomeKit accessory.
//  Stored at ~/Library/Application Support/Remote Monitor Control/homekit.json
//  (shared so `monitorctl homekit` can show the setup code).
//

import CryptoKit
import Foundation

public struct HomeKitPairing: Codable, Equatable, Sendable {
    /// The controller's pairing identifier (a UUID string from the Home app).
    public var id: String
    /// The controller's Ed25519 long-term public key (32 bytes).
    public var publicKey: Data
    public var isAdmin: Bool
}

public struct HomeKitIdentity: Codable, Equatable, Sendable {
    /// "AA:BB:CC:DD:EE:FF" — the accessory's pairing identifier.
    public var deviceID: String
    /// "123-45-678"
    public var setupCode: String
    /// 4 characters, used in the QR code.
    public var setupID: String
    /// Ed25519 private key seed (32 bytes).
    public var longTermSecretKey: Data
    public var pairings: [HomeKitPairing] = []
    /// Bonjour "c#": bumped whenever the accessory layout changes.
    public var configNumber: Int = 1
    /// Hash of the last published accessory layout.
    public var layoutHash: String = ""
    /// Input names the user changed in the Home app, keyed by input code.
    public var inputNames: [String: String] = [:]
    /// TV name the user changed in the Home app.
    public var tvName: String?

    public var isPaired: Bool { pairings.contains { $0.isAdmin } }

    public static func generate() -> HomeKitIdentity {
        let mac = (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined(separator: ":")
        let idChars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let setupID = String((0..<4).map { _ in idChars.randomElement()! })
        return HomeKitIdentity(deviceID: mac,
                               setupCode: makeSetupCode(),
                               setupID: setupID,
                               longTermSecretKey: Curve25519.Signing.PrivateKey().rawRepresentation)
    }

    /// HomeKit rejects trivial codes such as 111-11-111 and 123-45-678.
    static func makeSetupCode() -> String {
        let invalid: Set<String> = ["00000000", "11111111", "22222222", "33333333", "44444444", "55555555",
                                    "66666666", "77777777", "88888888", "99999999", "12345678", "87654321"]
        var digits = ""
        repeat {
            digits = (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined()
        } while invalid.contains(digits)
        let d = Array(digits)
        return "\(String(d[0..<3]))-\(String(d[3..<5]))-\(String(d[5..<8]))"
    }

    /// The "X-HM://" setup URI that Home scans from the QR code.
    public func setupURI(category: Int) -> String {
        let code = UInt64(setupCode.replacingOccurrences(of: "-", with: "")) ?? 0
        var low = code | (1 << 28)                    // flag: supports IP
        if category & 1 == 1 { low |= 1 << 31 }
        let high = UInt64(category >> 1)
        let value = (high << 32) | low
        var payload = String(value, radix: 36, uppercase: true)
        while payload.count < 9 { payload = "0" + payload }
        return "X-HM://" + payload + setupID
    }

    /// Bonjour "sh": base64 of the first 4 bytes of SHA-512(setupID + deviceID).
    public var setupHash: String {
        let digest = SHA512.hash(data: Data((setupID + deviceID).utf8))
        return Data(digest.prefix(4)).base64EncodedString()
    }
}

public enum HomeKitStore {
    public static var url: URL { ConfigStore.directory.appendingPathComponent("homekit.json") }

    /// Loads the identity, creating one on first use.
    public static func load() -> HomeKitIdentity {
        if let data = try? Data(contentsOf: url),
           let identity = try? JSONDecoder().decode(HomeKitIdentity.self, from: data) {
            return identity
        }
        let identity = HomeKitIdentity.generate()
        save(identity)
        return identity
    }

    /// Reads the identity without creating one.
    public static func existing() -> HomeKitIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HomeKitIdentity.self, from: data)
    }

    public static func save(_ identity: HomeKitIdentity) {
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(identity) else { return }
        try? data.write(to: url, options: [.atomic])
        // The file holds the accessory's private key.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
