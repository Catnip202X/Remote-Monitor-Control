//
//  USBWatcher.swift
//  Remote Monitor Control
//
//  "Follow a USB switch": watch one USB device (usually the keyboard plugged into a
//  USB switch shared by two computers). When it disappears, the switch has moved to
//  the other computer, so the monitor goes to Input B. When it comes back, the
//  monitor goes back to Input A (this Mac).
//

import Foundation
import IOKit
import IOKit.usb

public struct USBDevice: Codable, Hashable, Sendable, Identifiable {
    public let vendorID: Int
    public let productID: Int
    public let name: String

    public init(vendorID: Int, productID: Int, name: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
    }

    /// "1532:0257" — how the CLI and config refer to a device.
    public var key: String { String(format: "%04x:%04x", vendorID, productID) }
    public var id: String { key }
    public var isHub: Bool { name.localizedCaseInsensitiveContains("hub") }

    /// Parses "1532:0257" (hex).
    public static func parseKey(_ text: String) -> (vendor: Int, product: Int)? {
        let parts = text.lowercased().replacingOccurrences(of: "0x", with: "").split(separator: ":")
        guard parts.count == 2, let v = Int(parts[0], radix: 16), let p = Int(parts[1], radix: 16) else { return nil }
        return (v, p)
    }

    /// USB devices connected right now (hubs included, root controllers excluded).
    public static func connected() -> [USBDevice] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [USBDevice] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let device = USBDevice(entry: entry) { result.append(device) }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return Array(Set(result)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init?(entry: io_registry_entry_t) {
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let vendor = prop("idVendor") as? Int, let product = prop("idProduct") as? Int else { return nil }
        let name = (prop("USB Product Name") as? String) ?? (prop("kUSBProductString") as? String) ?? "USB device"
        self.init(vendorID: vendor, productID: product, name: name)
    }
}

/// Calls `onChange(true)` when the device is plugged in (or the switch comes back to
/// this Mac) and `onChange(false)` when it goes away. Events are delivered on the main
/// run loop after a short settle delay, so a switch that flickers doesn't flip the
/// monitor back and forth.
public final class USBWatcher {
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var vendorID = 0
    private var productID = 0
    private var onChange: ((Bool) -> Void)?
    private var pending: DispatchWorkItem?
    private var lastReported: Bool?

    public static let settleDelay: TimeInterval = 0.6

    public init() {}

    deinit { stop() }

    public var isRunning: Bool { port != nil }

    public func start(vendorID: Int, productID: Int, onChange: @escaping (Bool) -> Void) {
        stop()
        self.vendorID = vendorID
        self.productID = productID
        self.onChange = onChange

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            USBWatcher.drain(iterator)
            watcher.scheduleCheck()
        }

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching(), callback, context, &addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching(), callback, context, &removedIterator)
        // The iterators must be emptied once to arm them. The devices already present
        // are not a change, so just remember the current state.
        Self.drain(addedIterator)
        Self.drain(removedIterator)
        lastReported = isPresent()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
            IONotificationPortDestroy(port)
        }
        port = nil
        lastReported = nil
    }

    /// Whether at least one matching device is connected right now.
    public func isPresent() -> Bool {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching(), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        if entry != 0 { IOObjectRelease(entry); return true }
        return false
    }

    private func matching() -> CFMutableDictionary {
        let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dict["idVendor"] = vendorID
        dict["idProduct"] = productID
        return dict as CFMutableDictionary
    }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let present = self.isPresent()
            guard present != self.lastReported else { return }
            self.lastReported = present
            self.onChange?(present)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private static func drain(_ iterator: io_iterator_t) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }
}

extension MonitorController {
    /// What "follow USB" does when the watched device appears or disappears.
    @discardableResult
    public func followUSB(present: Bool, config: AppConfig = ConfigStore.load()) -> String {
        let target = present ? config.inputA : config.inputB
        do {
            return try setInput(target)
        } catch {
            return "Couldn't switch input: \(error.localizedDescription)"
        }
    }
}
