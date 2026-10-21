//
//  DDC.swift
//  Remote Monitor Control
//
//  Low-level DDC/CI (VESA Display Data Channel Command Interface) access for
//  external displays on Apple Silicon Macs, via IOAVService I2C.
//
//  The monitor's power is VCP feature 0xD6 ("Power Mode"):
//     0x01 = On, 0x02 = Standby, 0x03 = Suspend, 0x04 = Off (DPM), 0x05 = Off (power button)
//  This is exactly what Windows tools such as ControlMyMonitor / Twinkle Tray /
//  Monitorian send.
//

import Foundation
import IOKit

/// One external display that exposes a DDC/CI channel.
public final class ExternalDisplay: Identifiable, Hashable, CustomStringConvertible {
    public let id: String
    public let name: String
    public let index: Int
    /// Three-letter EDID manufacturer ID, e.g. "SAM" (Samsung), "GSM" (LG), "DEL" (Dell).
    public let manufacturerID: String?
    public let productID: Int?
    let service: IOAVService

    init(id: String, name: String, index: Int, manufacturerID: String?, productID: Int?, service: IOAVService) {
        self.id = id
        self.name = name
        self.index = index
        self.manufacturerID = manufacturerID
        self.productID = productID
        self.service = service
    }

    public static func == (lhs: ExternalDisplay, rhs: ExternalDisplay) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public var description: String { "\(name) [\(id)]" }
}

public enum DisplayDiscovery {
    /// Walks the IORegistry and pairs every external `DCPAVServiceProxy` (the I2C/DDC
    /// endpoint) with the framebuffer entry that precedes it (which carries the
    /// monitor's product name and EDID UUID).
    public static func externalDisplays() -> [ExternalDisplay] {
        var result: [ExternalDisplay] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var pendingName: String?
        var pendingKey: String?
        var pendingManufacturer: String?
        var pendingProductID: Int?
        var usedIDs = Set<String>()

        func process(_ entry: io_registry_entry_t) {
            let name = registryName(entry)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                let attrs = property(entry, "DisplayAttributes") as? [String: Any]
                let product = attrs?["ProductAttributes"] as? [String: Any]
                pendingName = product?["ProductName"] as? String
                pendingManufacturer = product?["ManufacturerID"] as? String
                pendingProductID = product?["ProductID"] as? Int
                var key = property(entry, "EDID UUID") as? String ?? ""
                if let serial = product?["AlphanumericSerialNumber"] as? String, !serial.isEmpty {
                    key += "-" + serial
                } else if let serial = product?["SerialNumber"] as? Int, serial != 0 {
                    key += "-\(serial)"
                }
                pendingKey = key.isEmpty ? nil : key
            } else if name == "DCPAVServiceProxy" {
                defer { pendingName = nil; pendingKey = nil; pendingManufacturer = nil; pendingProductID = nil }
                guard (property(entry, "Location") as? String) == "External" else { return }
                guard let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { return }
                let index = result.count + 1
                var id = pendingKey ?? "display-\(index)"
                if usedIDs.contains(id) { id += "#\(index)" }
                usedIDs.insert(id)
                let displayName = (pendingName?.isEmpty == false ? pendingName! : "External Display \(index)")
                result.append(ExternalDisplay(id: id, name: displayName, index: index,
                                              manufacturerID: pendingManufacturer, productID: pendingProductID,
                                              service: service))
            }
        }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            process(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

public enum DDC {
    static let chipAddress: UInt32 = 0x37   // DDC/CI 7-bit I2C address
    static let dataAddress: UInt32 = 0x51   // host "source" address / sub-address

    public static let vcpPowerMode: UInt8 = 0xD6

    private static func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// Set VCP feature. Returns true if the I2C write was acknowledged.
    /// `source` is the host's I2C source address: 0x51 per the standard, 0x50 for LG's
    /// alternate input command.
    public static func write(_ service: IOAVService, vcp: UInt8, value: UInt16, source: UInt8 = 0x51) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(0x6E ^ source, packet[0..<5])

        for attempt in 0..<4 {
            var success = false
            // Each command is sent twice: many monitors drop the first one after idle.
            for _ in 0..<2 {
                usleep(10_000)
                if IOAVServiceWriteI2C(service, chipAddress, UInt32(source), &packet, UInt32(packet.count)) == kIOReturnSuccess {
                    success = true
                }
            }
            if success { return true }
            usleep(UInt32(20_000 * (attempt + 1)))
        }
        return false
    }

    /// Get VCP feature. Returns (current, max) or nil if the monitor didn't answer.
    public static func read(_ service: IOAVService, vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        // Checksum covers the destination (0x6E) and source (0x51) addresses too,
        // exactly like the write packet; without 0x51 the monitor ignores the request.
        var packet: [UInt8] = [0x82, 0x01, vcp, 0]
        packet[3] = checksum(0x6E ^ 0x51, packet[0..<3])
        let debug = ProcessInfo.processInfo.environment["RMC_DEBUG"] != nil

        for attempt in 0..<4 {
            var wrote = false
            for _ in 0..<2 {
                usleep(10_000)
                if IOAVServiceWriteI2C(service, chipAddress, dataAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess {
                    wrote = true
                }
            }
            if wrote {
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: 11)
                let status = IOAVServiceReadI2C(service, chipAddress, dataAddress, &reply, UInt32(reply.count))
                if debug {
                    let hex = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
                    FileHandle.standardError.write(Data("DDC read vcp=0x\(String(format: "%02X", vcp)) attempt=\(attempt) status=0x\(String(status, radix: 16)) reply=[\(hex)]\n".utf8))
                }
                if status == kIOReturnSuccess,
                   reply[2] == 0x02,          // "VCP feature reply" opcode
                   reply[3] == 0x00,          // result code: no error
                   reply[4] == vcp {
                    let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
                    let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
                    return (current, maxValue)
                }
            }
            usleep(UInt32(30_000 * (attempt + 1)))
        }
        return nil
    }

    /// Read the monitor's DDC/CI capabilities string (VCP request 0xF3), e.g.
    /// "(prot(monitor)type(lcd)model(...)vcp(02 04 10 60(11 0F) ...))".
    /// Returns nil if the monitor doesn't answer.
    public static func capabilities(_ service: IOAVService) -> String? {
        var bytes: [UInt8] = []
        var offset: UInt16 = 0
        while offset < 4096 {
            var packet: [UInt8] = [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF), 0]
            packet[4] = checksum(0x6E ^ 0x51, packet[0..<4])
            var chunk: [UInt8]?
            for attempt in 0..<5 {
                usleep(10_000)
                guard IOAVServiceWriteI2C(service, chipAddress, dataAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess else {
                    usleep(UInt32(20_000 * (attempt + 1)))
                    continue
                }
                usleep(60_000)
                var reply = [UInt8](repeating: 0, count: 38)
                if IOAVServiceReadI2C(service, chipAddress, dataAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                   reply[2] == 0xE3,
                   (UInt16(reply[3]) << 8 | UInt16(reply[4])) == offset {
                    let length = max(0, Int(reply[1] & 0x7F) - 3)
                    chunk = Array(reply[5..<(5 + min(length, 32))])
                    break
                }
            }
            guard let chunk else { break }
            if chunk.isEmpty { break }   // an empty fragment ends the string
            bytes += chunk
            offset += UInt16(chunk.count)
        }
        let text = String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("vcp(") || text.contains("VCP(") ? text : nil
    }
}
