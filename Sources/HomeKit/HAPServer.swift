//
//  HAPServer.swift
//  Remote Monitor Control
//
//  A small HomeKit Accessory Protocol (HAP) server over IP, so the monitor can be
//  added to the Home app as a TV. It advertises itself with Bonjour (_hap._tcp),
//  pairs with the setup code (SRP pair setup), sets up encrypted sessions
//  (pair verify), and serves /accessories, /characteristics and /pairings.
//
//  Everything runs on one serial queue.
//

import CryptoKit
import Foundation
import Network

struct HomeKitStatus: Equatable, Sendable {
    var enabled = false
    var running = false
    var paired = false
    var setupCode = ""
    var setupURI = ""
    var controllers = 0
    var message = "Off"
}

struct CharacteristicID: Hashable {
    let aid: Int
    let iid: Int
}

final class HAPServer {
    static let shared = HAPServer()

    let queue = DispatchQueue(label: "com.dekun.RemoteMonitorControl.homekit")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HAPConnection] = [:]
    private(set) var identity: HomeKitIdentity = HomeKitStore.load()
    private lazy var accessory = TelevisionAccessory(server: self)
    private var pollTimer: DispatchSourceTimer?

    /// The SRP session of the pairing in progress and the connection it belongs to.
    private var setupSession: (srp: SRPServer, owner: ObjectIdentifier)?
    private var failedSetupAttempts = 0

    /// Called on the server queue whenever something the menu shows changes.
    var onStatusChange: (@Sendable (HomeKitStatus) -> Void)?
    private var status = HomeKitStatus()

    // MARK: - Lifecycle

    func start() {
        queue.async { self._start() }
    }

    func stop() {
        queue.async { self._stop(message: "Off") }
    }

    /// Forget every Home pairing and get a new accessory identity and setup code.
    func reset() {
        queue.async {
            self._stop(message: "Resetting…")
            self.identity = HomeKitIdentity.generate()
            HomeKitStore.save(self.identity)
            self._start()
        }
    }

    /// Re-reads the monitor's inputs (e.g. after Input A/B changed) and tells Home if the layout changed.
    func reloadLayout() {
        queue.async {
            guard self.listener != nil else { return }
            self.accessory.rebuild()
            let before = self.identity.configNumber
            self.updateConfigNumberIfNeeded()
            if self.identity.configNumber != before { self.republish() }
        }
    }

    /// Call when the monitor's power or input may have changed outside HomeKit.
    func monitorStateMayHaveChanged() {
        queue.asyncAfter(deadline: .now() + 0.3) {
            guard self.listener != nil else { return }
            self.pushChanges(self.accessory.refreshFromMonitor(), except: nil)
        }
    }

    private func _start() {
        guard listener == nil else { return }
        identity = HomeKitStore.load()
        accessory.rebuild()
        updateConfigNumberIfNeeded()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.service = bonjourService()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.status.running = true
                    self.updateStatus(message: self.identity.isPaired ? "Paired with Home" : "Ready to add in the Home app")
                case .failed(let error):
                    self.status.running = false
                    self.updateStatus(message: "HomeKit failed: \(error.localizedDescription)")
                    self.listener?.cancel()
                    self.listener = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let c = HAPConnection(connection: connection, server: self)
                self.connections[ObjectIdentifier(c)] = c
                c.start()
            }
            listener.start(queue: queue)
            self.listener = listener
            status.enabled = true
            startPolling()
            updateStatus(message: "Starting…")
        } catch {
            updateStatus(message: "HomeKit failed: \(error.localizedDescription)")
        }
    }

    private func _stop(message: String) {
        pollTimer?.cancel()
        pollTimer = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        setupSession = nil
        status.enabled = false
        status.running = false
        updateStatus(message: message)
    }

    func connectionClosed(_ c: HAPConnection) {
        connections.removeValue(forKey: ObjectIdentifier(c))
        if setupSession?.owner == ObjectIdentifier(c) { setupSession = nil }
        updateStatus(message: status.message)
    }

    // MARK: - Bonjour

    private func bonjourService() -> NWListener.Service {
        let txt: [String: String] = [
            "c#": String(identity.configNumber),
            "ff": "0",
            "id": identity.deviceID,
            "md": accessory.model,
            "pv": "1.1",
            "s#": "1",
            "sf": identity.isPaired ? "0" : "1",
            "ci": String(TelevisionAccessory.category),
            "sh": identity.setupHash,
        ]
        return NWListener.Service(name: accessory.displayName, type: "_hap._tcp", domain: nil,
                                  txtRecord: NWTXTRecord(txt))
    }

    private func republish() {
        listener?.service = bonjourService()
    }

    private func updateConfigNumberIfNeeded() {
        let hash = accessory.layoutHash
        if identity.layoutHash != hash {
            if !identity.layoutHash.isEmpty { identity.configNumber = identity.configNumber % 65535 + 1 }
            identity.layoutHash = hash
            HomeKitStore.save(identity)
        }
    }

    // MARK: - Status

    private func updateStatus(message: String) {
        status.paired = identity.isPaired
        status.setupCode = identity.setupCode
        status.setupURI = identity.setupURI(category: TelevisionAccessory.category)
        status.controllers = connections.values.filter { $0.controllerID != nil }.count
        status.message = message
        let snapshot = status
        onStatusChange?(snapshot)
    }

    // MARK: - Accessory state

    func saveIdentity(_ mutate: (inout HomeKitIdentity) -> Void) {
        mutate(&identity)
        HomeKitStore.save(identity)
    }

    private func startPolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Only talk to the monitor when a Home controller is listening.
            guard self.connections.values.contains(where: { !$0.subscriptions.isEmpty }) else { return }
            self.pushChanges(self.accessory.refreshFromMonitor(), except: nil)
        }
        timer.resume()
        pollTimer = timer
    }

    /// Sends EVENT messages for changed characteristics to subscribed controllers.
    func pushChanges(_ iids: [Int], except writer: HAPConnection?) {
        guard !iids.isEmpty else { return }
        for c in connections.values where c !== writer && c.isEncrypted {
            let wanted = iids.filter { c.subscriptions.contains(CharacteristicID(aid: TelevisionAccessory.aid, iid: $0)) }
            guard !wanted.isEmpty else { continue }
            let items: [[String: Any]] = wanted.compactMap { iid in
                guard case .success(let value) = accessory.read(iid) else { return nil }
                return ["aid": TelevisionAccessory.aid, "iid": iid, "value": value]
            }
            guard let body = try? JSONSerialization.data(withJSONObject: ["characteristics": items]) else { continue }
            c.sendEvent(body)
        }
    }

    // MARK: - Request routing

    func handle(_ request: HTTPRequest, on c: HAPConnection) -> HTTPResponse {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        switch (request.method, path) {
        case ("POST", "/pair-setup"):
            return .tlv(pairSetup(request.body, c))
        case ("POST", "/pair-verify"):
            return .tlv(pairVerify(request.body, c))
        case ("POST", "/identify"):
            if identity.isPaired { return .json(400, ["status": -70401]) }
            accessory.identify()
            return .noContent
        default:
            break
        }

        guard c.isEncrypted else {
            return .json(470, ["status": -70401])
        }

        switch (request.method, path) {
        case ("GET", "/accessories"):
            return .json(200, accessory.accessoriesJSON())
        case ("GET", "/characteristics"):
            return readCharacteristics(query: request.query)
        case ("PUT", "/characteristics"):
            return writeCharacteristics(request.body, c)
        case ("PUT", "/prepare"):
            return .json(200, ["status": 0])
        case ("POST", "/pairings"):
            return .tlv(pairings(request.body, c))
        default:
            return HTTPResponse(status: 404, contentType: nil, body: Data())
        }
    }

    // MARK: - Pair setup (SRP)

    private func pairSetup(_ body: Data, _ c: HAPConnection) -> Data {
        let tlv = TLV8.decode(body)
        switch tlv.byte(.state) ?? 0 {
        case 1:
            if identity.isPaired { return TLV8.errorResponse(state: 2, .unavailable) }
            if failedSetupAttempts >= 100 { return TLV8.errorResponse(state: 2, .maxTries) }
            if let session = setupSession, session.owner != ObjectIdentifier(c),
               connections[session.owner] != nil {
                return TLV8.errorResponse(state: 2, .busy)
            }
            let srp = SRPServer(password: identity.setupCode)
            setupSession = (srp, ObjectIdentifier(c))
            return TLV8([(.state, Data([2])), (.publicKey, srp.publicKey), (.salt, srp.salt)]).encode()

        case 3:
            guard let session = setupSession, session.owner == ObjectIdentifier(c),
                  let clientKey = tlv[.publicKey], let proof = tlv[.proof] else {
                return TLV8.errorResponse(state: 4, .authentication)
            }
            guard let serverProof = session.srp.verify(clientPublicKey: clientKey, clientProof: proof) else {
                failedSetupAttempts += 1
                setupSession = nil
                updateStatus(message: "Wrong setup code entered in the Home app")
                return TLV8.errorResponse(state: 4, .authentication)
            }
            return TLV8([(.state, Data([4])), (.proof, serverProof)]).encode()

        case 5:
            guard let session = setupSession, session.owner == ObjectIdentifier(c),
                  let K = session.srp.sessionKey, let encrypted = tlv[.encryptedData] else {
                return TLV8.errorResponse(state: 6, .authentication)
            }
            let key = HAPCrypto.hkdf(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            guard let plain = try? HAPCrypto.open(encrypted, key: key, nonce: HAPCrypto.nonce("PS-Msg05")) else {
                return TLV8.errorResponse(state: 6, .authentication)
            }
            let sub = TLV8.decode(plain)
            guard let controllerID = sub[.identifier], let controllerLTPK = sub[.publicKey],
                  let signature = sub[.signature],
                  let controllerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: controllerLTPK) else {
                return TLV8.errorResponse(state: 6, .authentication)
            }
            let controllerX = HAPCrypto.hkdf(K, salt: "Pair-Setup-Controller-Sign-Salt",
                                             info: "Pair-Setup-Controller-Sign-Info")
            let controllerInfo = controllerX.withUnsafeBytes { Data($0) } + controllerID + controllerLTPK
            guard controllerKey.isValidSignature(signature, for: controllerInfo) else {
                return TLV8.errorResponse(state: 6, .authentication)
            }

            guard let ltsk = try? Curve25519.Signing.PrivateKey(rawRepresentation: identity.longTermSecretKey) else {
                return TLV8.errorResponse(state: 6, .unknown)
            }
            let accessoryX = HAPCrypto.hkdf(K, salt: "Pair-Setup-Accessory-Sign-Salt",
                                            info: "Pair-Setup-Accessory-Sign-Info")
            let accessoryID = Data(identity.deviceID.utf8)
            let accessoryLTPK = ltsk.publicKey.rawRepresentation
            let accessoryInfo = accessoryX.withUnsafeBytes { Data($0) } + accessoryID + accessoryLTPK
            guard let accessorySignature = try? ltsk.signature(for: accessoryInfo) else {
                return TLV8.errorResponse(state: 6, .unknown)
            }
            let response = TLV8([(.identifier, accessoryID), (.publicKey, accessoryLTPK),
                                 (.signature, accessorySignature)]).encode()
            guard let encryptedResponse = try? HAPCrypto.seal(response, key: key, nonce: HAPCrypto.nonce("PS-Msg06")) else {
                return TLV8.errorResponse(state: 6, .unknown)
            }

            let id = String(decoding: controllerID, as: UTF8.self)
            saveIdentity { identity in
                identity.pairings.removeAll { $0.id == id }
                identity.pairings.append(HomeKitPairing(id: id, publicKey: controllerLTPK, isAdmin: true))
            }
            setupSession = nil
            failedSetupAttempts = 0
            republish()
            updateStatus(message: "Paired with Home")
            return TLV8([(.state, Data([6])), (.encryptedData, encryptedResponse)]).encode()

        default:
            return TLV8.errorResponse(state: 2, .unknown)
        }
    }

    // MARK: - Pair verify

    private func pairVerify(_ body: Data, _ c: HAPConnection) -> Data {
        let tlv = TLV8.decode(body)
        switch tlv.byte(.state) ?? 0 {
        case 1:
            guard let controllerPK = tlv[.publicKey],
                  let controllerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: controllerPK),
                  let ltsk = try? Curve25519.Signing.PrivateKey(rawRepresentation: identity.longTermSecretKey) else {
                return TLV8.errorResponse(state: 2, .authentication)
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: controllerKey) else {
                return TLV8.errorResponse(state: 2, .authentication)
            }
            let accessoryPK = ephemeral.publicKey.rawRepresentation
            let accessoryID = Data(identity.deviceID.utf8)
            guard let signature = try? ltsk.signature(for: accessoryPK + accessoryID + controllerPK) else {
                return TLV8.errorResponse(state: 2, .unknown)
            }
            let key = HAPCrypto.hkdf(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            let sub = TLV8([(.identifier, accessoryID), (.signature, signature)]).encode()
            guard let encrypted = try? HAPCrypto.seal(sub, key: key, nonce: HAPCrypto.nonce("PV-Msg02")) else {
                return TLV8.errorResponse(state: 2, .unknown)
            }
            c.verifySession = PairVerifySession(accessoryPK: accessoryPK, controllerPK: controllerPK,
                                                shared: shared, key: key)
            return TLV8([(.state, Data([2])), (.publicKey, accessoryPK), (.encryptedData, encrypted)]).encode()

        case 3:
            guard let session = c.verifySession, let encrypted = tlv[.encryptedData],
                  let plain = try? HAPCrypto.open(encrypted, key: session.key, nonce: HAPCrypto.nonce("PV-Msg03")) else {
                return TLV8.errorResponse(state: 4, .authentication)
            }
            let sub = TLV8.decode(plain)
            guard let controllerIDData = sub[.identifier], let signature = sub[.signature] else {
                return TLV8.errorResponse(state: 4, .authentication)
            }
            let controllerID = String(decoding: controllerIDData, as: UTF8.self)
            guard let pairing = identity.pairings.first(where: { $0.id == controllerID }),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pairing.publicKey),
                  key.isValidSignature(signature, for: session.controllerPK + controllerIDData + session.accessoryPK) else {
                c.verifySession = nil
                return TLV8.errorResponse(state: 4, .authentication)
            }
            c.controllerID = controllerID
            // Encryption starts with the next message, after this response goes out in the clear.
            c.pendingKeys = (
                read: HAPCrypto.hkdf(session.shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
                write: HAPCrypto.hkdf(session.shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key"))
            c.verifySession = nil
            queue.async { self.updateStatus(message: "Paired with Home") }
            return TLV8([(.state, Data([4]))]).encode()

        default:
            return TLV8.errorResponse(state: 2, .unknown)
        }
    }

    // MARK: - Pairings (add / remove / list)

    private func pairings(_ body: Data, _ c: HAPConnection) -> Data {
        let tlv = TLV8.decode(body)
        guard let me = identity.pairings.first(where: { $0.id == c.controllerID }), me.isAdmin else {
            return TLV8.errorResponse(state: 2, .authentication)
        }
        switch tlv.byte(.method) ?? 0 {
        case 3: // add
            guard let idData = tlv[.identifier], let publicKey = tlv[.publicKey] else {
                return TLV8.errorResponse(state: 2, .unknown)
            }
            let id = String(decoding: idData, as: UTF8.self)
            let admin = (tlv.byte(.permissions) ?? 0) & 1 == 1
            if let index = identity.pairings.firstIndex(where: { $0.id == id }) {
                guard identity.pairings[index].publicKey == publicKey else {
                    return TLV8.errorResponse(state: 2, .unknown)
                }
                saveIdentity { $0.pairings[index].isAdmin = admin }
            } else {
                guard identity.pairings.count < 16 else { return TLV8.errorResponse(state: 2, .maxPeers) }
                saveIdentity { $0.pairings.append(HomeKitPairing(id: id, publicKey: publicKey, isAdmin: admin)) }
            }
            return TLV8([(.state, Data([2]))]).encode()

        case 4: // remove
            guard let idData = tlv[.identifier] else { return TLV8.errorResponse(state: 2, .unknown) }
            let id = String(decoding: idData, as: UTF8.self)
            saveIdentity { $0.pairings.removeAll { $0.id == id } }
            var toClose = connections.values.filter { $0.controllerID == id }
            if !identity.isPaired {
                // The last admin is gone: the accessory is unpaired again.
                saveIdentity { $0.pairings.removeAll() }
                toClose = Array(connections.values)
                republish()
                updateStatus(message: "Removed from Home")
            }
            let closing = toClose
            queue.asyncAfter(deadline: .now() + 0.5) { closing.forEach { $0.close() } }
            return TLV8([(.state, Data([2]))]).encode()

        case 5: // list
            var out = TLV8()
            out.append(.state, byte: 2)
            for (i, p) in identity.pairings.enumerated() {
                if i > 0 { out.append(.separator, Data()) }
                out.append(.identifier, Data(p.id.utf8))
                out.append(.publicKey, p.publicKey)
                out.append(.permissions, byte: p.isAdmin ? 1 : 0)
            }
            return out.encode()

        default:
            return TLV8.errorResponse(state: 2, .unknown)
        }
    }

    // MARK: - Characteristics

    private func readCharacteristics(query: [String: String]) -> HTTPResponse {
        let ids = (query["id"] ?? "").split(separator: ",").compactMap { part -> CharacteristicID? in
            let pieces = part.split(separator: ".")
            guard pieces.count == 2, let aid = Int(pieces[0]), let iid = Int(pieces[1]) else { return nil }
            return CharacteristicID(aid: aid, iid: iid)
        }
        if ids.contains(where: { $0.iid >= TelevisionAccessory.IID.tvService && $0.aid == TelevisionAccessory.aid }) {
            // Events must not arrive between a request and its response: send them afterwards.
            let changed = accessory.refreshFromMonitor()
            if !changed.isEmpty { queue.async { self.pushChanges(changed, except: nil) } }
        }
        var items: [[String: Any]] = []
        var anyError = false
        for id in ids {
            guard id.aid == TelevisionAccessory.aid else {
                anyError = true
                items.append(["aid": id.aid, "iid": id.iid, "status": -70409])
                continue
            }
            switch accessory.read(id.iid) {
            case .success(let value):
                items.append(["aid": id.aid, "iid": id.iid, "value": value])
            case .failure(let error):
                anyError = true
                items.append(["aid": id.aid, "iid": id.iid, "status": error.rawValue])
            }
        }
        if anyError {
            items = items.map { item in
                var item = item
                if item["status"] == nil { item["status"] = 0 }
                return item
            }
            return .json(207, ["characteristics": items])
        }
        return .json(200, ["characteristics": items])
    }

    private func writeCharacteristics(_ body: Data, _ c: HAPConnection) -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let list = json["characteristics"] as? [[String: Any]] else {
            return .json(400, ["status": -70410])
        }
        var results: [[String: Any]] = []
        var anyError = false
        var changed: [Int] = []
        var written = Set<Int>()
        for item in list {
            guard let aid = (item["aid"] as? NSNumber)?.intValue, let iid = (item["iid"] as? NSNumber)?.intValue else {
                continue
            }
            var status = 0
            if aid != TelevisionAccessory.aid {
                status = HAPStatus.notFound.rawValue
            } else {
                if let ev = item["ev"] {
                    let on = (ev as? NSNumber)?.boolValue ?? false
                    if accessory.supportsEvents(iid) {
                        let id = CharacteristicID(aid: aid, iid: iid)
                        if on { c.subscriptions.insert(id) } else { c.subscriptions.remove(id) }
                    } else {
                        status = HAPStatus.notificationNotSupported.rawValue
                    }
                }
                if let value = item["value"] {
                    written.insert(iid)
                    switch accessory.write(iid, value: value) {
                    case .success(let iids): changed += iids
                    case .failure(let error): status = error.rawValue
                    }
                }
            }
            if status != 0 { anyError = true }
            results.append(["aid": aid, "iid": iid, "status": status])
        }
        // The writer already knows what it wrote, but not about side effects (e.g. a remote key
        // changing the input).
        let all = Array(Set(changed))
        pushChanges(all.filter { written.contains($0) }, except: c)
        pushChanges(all.filter { !written.contains($0) }, except: nil)
        if !changed.isEmpty {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .homeKitChangedMonitor, object: nil) }
        }
        return anyError ? .json(207, ["characteristics": results]) : .noContent
    }
}

extension Notification.Name {
    /// Posted on the main queue after the Home app changed the monitor.
    static let homeKitChangedMonitor = Notification.Name("RemoteMonitorControl.homeKitChangedMonitor")
}

// MARK: - Status codes

enum HAPStatus: Int, Error {
    case insufficientPrivileges = -70401
    case communicationFailure = -70402
    case busy = -70403
    case readOnly = -70404
    case writeOnly = -70405
    case notificationNotSupported = -70406
    case outOfResources = -70407
    case timedOut = -70408
    case notFound = -70409
    case invalidValue = -70410
}

// MARK: - HTTP

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var query: [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var result: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let first = kv.first else { continue }
            let key = String(first)
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            result[key] = value
        }
        return result
    }
}

struct HTTPResponse {
    let status: Int
    let contentType: String?
    let body: Data

    static let noContent = HTTPResponse(status: 204, contentType: nil, body: Data())

    static func tlv(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/pairing+tlv8", body: data)
    }

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/hap+json", body: data)
    }

    func serialize() -> Data {
        let reasons = [200: "OK", 204: "No Content", 207: "Multi-Status", 400: "Bad Request",
                       404: "Not Found", 422: "Unprocessable Entity", 470: "Connection Authorization Required",
                       500: "Internal Server Error", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: - Connection

struct PairVerifySession {
    let accessoryPK: Data
    let controllerPK: Data
    let shared: SharedSecret
    let key: SymmetricKey
}

final class HAPConnection {
    private let connection: NWConnection
    private unowned let server: HAPServer

    private var encryptedInbound = Data()
    private var plainInbound = Data()
    private var readKey: SymmetricKey?
    private var writeKey: SymmetricKey?
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0
    private var closed = false

    var verifySession: PairVerifySession?
    var pendingKeys: (read: SymmetricKey, write: SymmetricKey)?
    var controllerID: String?
    var subscriptions = Set<CharacteristicID>()

    var isEncrypted: Bool { readKey != nil }

    init(connection: NWConnection, server: HAPServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: server.queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        server.connectionClosed(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.process(data) }
            if isComplete || error != nil {
                self.close()
            } else if !self.closed {
                self.receive()
            }
        }
    }

    private func process(_ data: Data) {
        if let readKey {
            encryptedInbound.append(data)
            while encryptedInbound.count >= 2 {
                let length = Int(encryptedInbound[encryptedInbound.startIndex]) |
                    Int(encryptedInbound[encryptedInbound.startIndex + 1]) << 8
                guard encryptedInbound.count >= 2 + length + 16 else { break }
                let aad = encryptedInbound.prefix(2)
                let sealed = encryptedInbound.dropFirst(2).prefix(length + 16)
                guard let plain = try? HAPCrypto.open(Data(sealed), key: readKey,
                                                      nonce: HAPCrypto.nonce(readCounter), aad: Data(aad)) else {
                    close()
                    return
                }
                readCounter += 1
                plainInbound.append(plain)
                encryptedInbound = Data(encryptedInbound.dropFirst(2 + length + 16))
            }
        } else {
            plainInbound.append(data)
        }
        while let request = nextRequest() {
            let response = server.handle(request, on: self)
            send(response.serialize())
            if let keys = pendingKeys {
                pendingKeys = nil
                readKey = keys.read
                writeKey = keys.write
                readCounter = 0
                writeCounter = 0
            }
            if closed { return }
        }
    }

    /// Takes one complete HTTP request off the inbound buffer.
    private func nextRequest() -> HTTPRequest? {
        guard let headerEnd = plainInbound.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: plainInbound[plainInbound.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            plainInbound.removeAll()
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        guard length <= 64 * 1024 else {
            close()
            return nil
        }
        let bodyStart = headerEnd.upperBound
        guard plainInbound.distance(from: bodyStart, to: plainInbound.endIndex) >= length else { return nil }
        let bodyEnd = plainInbound.index(bodyStart, offsetBy: length)
        let body = Data(plainInbound[bodyStart..<bodyEnd])
        plainInbound = Data(plainInbound[bodyEnd...])
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
    }

    func sendEvent(_ json: Data) {
        var head = "EVENT/1.0 200 OK\r\n"
        head += "Content-Type: application/hap+json\r\n"
        head += "Content-Length: \(json.count)\r\n\r\n"
        send(Data(head.utf8) + json)
    }

    private func send(_ data: Data) {
        guard !closed else { return }
        guard let writeKey else {
            connection.send(content: data, completion: .contentProcessed { _ in })
            return
        }
        var out = Data()
        var offset = 0
        while offset < data.count {
            let chunk = data[data.startIndex + offset ..< data.startIndex + min(offset + 1024, data.count)]
            var aad = Data()
            let length = UInt16(chunk.count)
            aad.append(UInt8(length & 0xFF))
            aad.append(UInt8(length >> 8))
            guard let sealed = try? HAPCrypto.seal(Data(chunk), key: writeKey,
                                                   nonce: HAPCrypto.nonce(writeCounter), aad: aad) else { return }
            writeCounter += 1
            out.append(aad)
            out.append(sealed)
            offset += chunk.count
        }
        connection.send(content: out, completion: .contentProcessed { _ in })
    }
}
