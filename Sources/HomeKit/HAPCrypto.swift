//
//  HAPCrypto.swift
//  Remote Monitor Control
//
//  TLV8 encoding, HKDF and ChaCha20-Poly1305 helpers for the HomeKit Accessory
//  Protocol (HAP).
//

import CryptoKit
import Foundation
import Security

// MARK: - TLV8

enum TLVType: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case flags = 0x13
    case separator = 0xFF
}

enum TLVError: UInt8 {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
}

struct TLV8 {
    private(set) var items: [(UInt8, Data)] = []

    init() {}

    init(_ pairs: [(TLVType, Data)]) {
        items = pairs.map { ($0.0.rawValue, $0.1) }
    }

    mutating func append(_ type: TLVType, _ value: Data) {
        items.append((type.rawValue, value))
    }

    mutating func append(_ type: TLVType, byte: UInt8) {
        items.append((type.rawValue, Data([byte])))
    }

    /// Items with the same type that follow each other are one value split in 255-byte pieces.
    static func decode(_ data: Data) -> TLV8 {
        var result = TLV8()
        let bytes = [UInt8](data)
        var i = 0
        var lastType: UInt8?
        while i + 2 <= bytes.count {
            let type = bytes[i]
            let length = Int(bytes[i + 1])
            i += 2
            guard i + length <= bytes.count else { break }
            let value = Data(bytes[i..<(i + length)])
            i += length
            if let lastType, lastType == type, let last = result.items.last, last.1.count % 255 == 0, !last.1.isEmpty {
                result.items[result.items.count - 1].1.append(value)
            } else {
                result.items.append((type, value))
            }
            lastType = type
        }
        return result
    }

    func encode() -> Data {
        var out = Data()
        for (type, value) in items {
            if value.isEmpty {
                out.append(contentsOf: [type, 0])
                continue
            }
            var offset = 0
            while offset < value.count {
                let chunk = value[value.startIndex + offset ..< value.startIndex + min(offset + 255, value.count)]
                out.append(type)
                out.append(UInt8(chunk.count))
                out.append(contentsOf: chunk)
                offset += chunk.count
            }
        }
        return out
    }

    subscript(type: TLVType) -> Data? {
        items.first { $0.0 == type.rawValue }?.1
    }

    func byte(_ type: TLVType) -> UInt8? {
        self[type]?.first
    }

    static func errorResponse(state: UInt8, _ error: TLVError) -> Data {
        TLV8([(.state, Data([state])), (.error, Data([error.rawValue]))]).encode()
    }
}

// MARK: - Crypto helpers

enum HAPCrypto {
    static func hkdf(_ input: Data, salt: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: input),
                               salt: Data(salt.utf8),
                               info: Data(info.utf8),
                               outputByteCount: 32)
    }

    static func hkdf(_ secret: SharedSecret, salt: String, info: String) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA512.self,
                                       salt: Data(salt.utf8),
                                       sharedInfo: Data(info.utf8),
                                       outputByteCount: 32)
    }

    /// 12-byte nonce: 4 zero bytes followed by an 8-byte label such as "PS-Msg05".
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        bytes.append(Data(label.utf8))
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// 12-byte nonce: 4 zero bytes followed by a little-endian 64-bit counter.
    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Returns ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.ciphertext + box.tag
    }

    /// `data` is ciphertext followed by the 16-byte tag.
    static func open(_ data: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce, aad: Data = Data()) throws -> Data {
        guard data.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let ciphertext = data.prefix(data.count - 16)
        let tag = data.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }

    static func sha512(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for p in parts { hasher.update(data: p) }
        return Data(hasher.finalize())
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

// MARK: - Log

/// Appends to ~/Library/Application Support/Remote Monitor Control/homekit.log (kept under 1 MB).
enum HAPLog {
    private static let queue = DispatchQueue(label: "com.dekun.RemoteMonitorControl.homekit.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) \(message)\n"
            let url = HomeKitStore.logURL
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }

    /// "state=3 error=2" for a pairing TLV, for the log.
    static func describe(_ tlv: Data) -> String {
        let t = TLV8.decode(tlv)
        var parts: [String] = []
        if let v = t.byte(.state) { parts.append("state=\(v)") }
        if let v = t.byte(.method) { parts.append("method=\(v)") }
        if let v = t.byte(.error) { parts.append("error=\(v)") }
        if let v = t[.flags] { parts.append("flags=\(v.map { String(format: "%02x", $0) }.joined())") }
        return parts.joined(separator: " ")
    }
}
