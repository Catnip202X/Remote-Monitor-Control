//
//  RemoteServer.swift
//  Remote Monitor Control
//
//  A tiny HTTP server on the local network so an iPhone/iPad/Watch Shortcut
//  ("Get Contents of URL") can switch the monitor:
//
//     GET http://<mac>.local:8765/off?token=XXXX
//     GET http://<mac>.local:8765/on?token=XXXX
//     GET http://<mac>.local:8765/toggle?token=XXXX
//     GET http://<mac>.local:8765/status?token=XXXX
//
//  Optional `&display=<number|name>` targets one monitor. The token can also be
//  sent as an `X-Token` header.
//

import Foundation
import Network

final class RemoteServer {
    typealias Handler = @Sendable (_ path: String, _ query: [String: String], _ token: String?) -> (status: Int, body: String)

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.dekun.RemoteMonitorControl.server")
    var onStateChange: (@Sendable (String) -> Void)?

    func start(port: UInt16, handler: @escaping Handler) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStateChange?("Invalid port \(port)")
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onStateChange?("Listening on port \(port)")
                case .failed(let error): self?.onStateChange?("Server failed: \(error.localizedDescription)")
                case .cancelled: self?.onStateChange?("Stopped")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection, handler: handler)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStateChange?("Server failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection, handler: @escaping Handler) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let lines = request.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ").map(String.init) ?? []
            guard parts.count >= 2 else {
                self.respond(connection, status: 400, body: "Bad request")
                return
            }

            let components = URLComponents(string: "http://localhost" + parts[1])
            var query: [String: String] = [:]
            components?.queryItems?.forEach { query[$0.name.lowercased()] = $0.value ?? "" }

            var token = query["token"]
            for line in lines.dropFirst() where line.lowercased().hasPrefix("x-token:") {
                token = String(line.dropFirst("x-token:".count)).trimmingCharacters(in: .whitespaces)
            }

            let path = (components?.path ?? "/").lowercased()
            let (status, body) = handler(path, query, token)
            self.respond(connection, status: status, body: body)
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        let bodyData = Data((body + "\n").utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
