import Foundation
import Network

/// Tiny HTTP/1.1 server on 127.0.0.1 that receives PreToolUse hook payloads
/// from the bridge script and waits (via continuation) for the user to
/// answer in the menubar UI.
///
/// We roll our own minimal HTTP parser because (a) the contract is one
/// endpoint, one method, JSON in/out, and (b) pulling in a full server
/// dep for ~80 LOC would be silly.
///
/// `@unchecked Sendable`: all mutable state lives on `queue` or is set
/// once during start; the closures we hand out coordinate via that queue.
final class PermissionServer: @unchecked Sendable {

    /// Called on the main actor when a new permission request arrives. The
    /// closure must call `resolve` exactly once with the user's decision.
    typealias RequestHandler = @MainActor (PendingPermission, _ resolve: @escaping (PermissionDecision) -> Void) -> Void

    /// Fired when the bridge connection drops before the user answered —
    /// e.g. curl hit its timeout. Lets the UI clear the now-dead request
    /// instead of leaving a stale "needs attention" row.
    typealias CancelHandler = @MainActor (_ pendingId: UUID) -> Void

    private let queue = DispatchQueue(label: "PermissionServer", qos: .userInitiated)
    private var listener: NWListener?
    private let handler: RequestHandler
    private let onCancel: CancelHandler
    private(set) var port: UInt16 = 0

    init(handler: @escaping RequestHandler, onCancel: @escaping CancelHandler) {
        self.handler = handler
        self.onCancel = onCancel
    }

    func start() throws {
        let params = NWParameters.tcp
        // Loopback only — never expose this to the network.
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let p = listener.port?.rawValue {
                self.port = p
                self.publishPort(p)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unpublishPort()
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(on: conn, accumulated: Data())
    }

    private func readRequest(on conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            if let error {
                NSLog("[ClaudeSessions] PermissionServer recv error: \(error)")
                conn.cancel()
                return
            }
            var buf = accumulated
            if let data { buf.append(data) }

            // Wait for end of headers.
            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { conn.cancel() } else {
                    self.readRequest(on: conn, accumulated: buf)
                }
                return
            }
            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            let bodyStart = headerEnd.upperBound
            let headerText = String(data: headerData, encoding: .utf8) ?? ""
            let contentLength = self.headerValue(headerText, "Content-Length").flatMap(Int.init) ?? 0

            let bodyHave = buf.count - bodyStart
            if bodyHave < contentLength {
                if isComplete { conn.cancel() } else {
                    self.readRequest(on: conn, accumulated: buf)
                }
                return
            }
            let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
            self.handleRequest(headerText: headerText, body: body, conn: conn)
        }
    }

    private func handleRequest(headerText: String, body: Data, conn: NWConnection) {
        // Request line: "POST /permission HTTP/1.1"
        let firstLine = headerText.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2, parts[0] == "POST", parts[1] == "/permission" else {
            self.respond(conn: conn, status: "404 Not Found", body: Data())
            return
        }
        guard
            let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            let toolName = payload["tool_name"] as? String,
            let sessionId = payload["session_id"] as? String,
            let toolInput = payload["tool_input"] as? [String: Any]
        else {
            self.respond(conn: conn, status: "400 Bad Request", body: Data())
            return
        }

        let pending = PendingPermission(
            id: UUID(),
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            receivedAt: Date()
        )

        // Single-shot guard so a user click and a connection drop can race
        // safely — whichever lands first wins, the other is a no-op.
        let lock = NSLock()
        var resolved = false
        let resolveOnce: (PermissionDecision, Bool) -> Void = { [weak self] decision, sendResponse in
            lock.lock()
            if resolved { lock.unlock(); return }
            resolved = true
            lock.unlock()
            guard let self else { return }
            if sendResponse {
                let data = (try? JSONSerialization.data(withJSONObject: decision.hookResponseJSON)) ?? Data("{}".utf8)
                self.queue.async { self.respond(conn: conn, status: "200 OK", body: data) }
            }
        }

        // Bridge died (curl timeout, hook killed, etc.): tell the UI to
        // drop the stale row. We don't try to send a response — the
        // bridge already gave Claude Code an "ask" fallback.
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                lock.lock()
                let alreadyResolved = resolved
                if !alreadyResolved { resolved = true }
                lock.unlock()
                if alreadyResolved { return }
                let id = pending.id
                Task { @MainActor in self?.onCancel(id) }
            default:
                break
            }
        }

        Task { @MainActor in
            self.handler(pending) { decision in
                resolveOnce(decision, true)
            }
        }
    }

    private func respond(conn: NWConnection, status: String, body: Data) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func headerValue(_ headers: String, _ name: String) -> String? {
        let needle = name.lowercased() + ":"
        for line in headers.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix(needle) {
                return line
                    .dropFirst(needle.count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Port file (so the bridge script can find us)

    private static let portDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/menubar", isDirectory: true)
    private static let portFile = portDir.appendingPathComponent("port")

    private func publishPort(_ port: UInt16) {
        try? FileManager.default.createDirectory(at: Self.portDir, withIntermediateDirectories: true)
        try? "\(port)\n".write(to: Self.portFile, atomically: true, encoding: .utf8)
    }

    private func unpublishPort() {
        try? FileManager.default.removeItem(at: Self.portFile)
    }
}
