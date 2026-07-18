import Foundation

// MARK: - Public value types

/// How to reach an MCP server. Two transports are supported: a local child
/// process speaking newline-delimited JSON over stdio, and a remote
/// "Streamable HTTP" endpoint.
enum MCPTransport: Equatable {
    /// Launch `command` (resolved on PATH via `/usr/bin/env`) with `args`,
    /// merging `env` over the inherited process environment.
    case stdio(command: String, args: [String], env: [String: String])
    /// POST JSON-RPC to `url`, sending `headers` on every request.
    case http(url: String, headers: [String: String])
}

/// A tool advertised by an MCP server. `inputSchema` is the raw JSON-Schema
/// object the server published for the tool's arguments; the integrator bridges
/// this into the app's own `AIToolSpec`.
struct MCPToolDef {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

/// Failures surfaced while talking to an MCP server.
enum MCPError: Error, LocalizedError {
    /// The transport itself failed (spawn error, socket error, early exit).
    case transport(String)
    /// A well-formed transport carried a malformed / unexpected MCP message.
    case protocolError(String)
    /// A request outlived its per-request deadline.
    case timeout
    /// A call was made before `connect()` succeeded (or after `shutdown()`).
    case notConnected
    /// The server returned a JSON-RPC error object.
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .transport(let detail):
            return "MCP transport error: \(detail)"
        case .protocolError(let detail):
            return "MCP protocol error: \(detail)"
        case .timeout:
            return "The MCP server did not respond in time."
        case .notConnected:
            return "The MCP session isn't connected."
        case .server(let code, let message):
            return "MCP server error \(code): \(message)"
        }
    }
}

// MARK: - Session

/// A JSON-RPC 2.0 client that speaks MCP over either stdio or Streamable HTTP.
///
/// An `actor` so that the request-id counter, the pending-continuation map, and
/// the stdio read buffer are all mutated under a single serialized executor —
/// no locks, no data races. The only `nonisolated` surface is `describe`, which
/// reads immutable stored state captured at init.
actor MCPSession {

    // MARK: Stored state

    private let transport: MCPTransport
    private let clientName: String
    private let clientVersion: String

    /// Monotonic JSON-RPC request id. Ids are per-session unique; the server
    /// echoes them back so we can resume the right waiter.
    private var nextID: Int = 1

    /// Waiters keyed by the request id they expect a response for. Touched only
    /// on the actor's executor, so no external synchronization is needed.
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Per-request timeout tasks, so a completed waiter can cancel its timer.
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]

    private var isConnected = false
    private var didShutdown = false

    /// Per-request deadline, in seconds.
    private let requestTimeout: TimeInterval = 30

    // stdio-only
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    /// Accumulates partial stdout between newline-delimited frames.
    private var stdoutBuffer = Data()
    /// Rolling capture of the child's stderr, for error messages.
    private var stderrBuffer = Data()
    /// Serializes stdout chunks into a single ordered consumer, so newline-frame
    /// reassembly can't be corrupted by out-of-order delivery. The readability
    /// handler yields into this; one reader `Task` drains it in FIFO order.
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stdoutReaderTask: Task<Void, Never>?

    // http-only
    private var httpSession: URLSession?
    /// Server-assigned session id, echoed back on every subsequent request.
    private var mcpSessionID: String?

    // MARK: Init

    init(transport: MCPTransport, clientName: String = "Glancekit", clientVersion: String = "0.1") {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    // MARK: Public API

    /// A short human label for logs / UI: the command for stdio, the host for
    /// http. Reads only immutable init state, so it is safe off-actor.
    nonisolated var describe: String {
        switch transport {
        case .stdio(let command, _, _):
            return command
        case .http(let url, _):
            if let host = URL(string: url)?.host {
                return host
            }
            return url
        }
    }

    var connected: Bool { isConnected }

    /// Start the transport and perform the MCP handshake (`initialize` request +
    /// `notifications/initialized`). No-op if already connected.
    func connect() async throws {
        if isConnected { return }
        if didShutdown {
            throw MCPError.notConnected
        }

        switch transport {
        case .stdio:
            try startStdio()
        case .http:
            startHTTP()
        }

        // Handshake. If it fails, tear down so we don't leak a half-open child.
        do {
            let params: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": clientName, "version": clientVersion],
            ]
            _ = try await send(method: "initialize", params: params)
            try await notify(method: "notifications/initialized", params: [:])
        } catch {
            await shutdown()
            didShutdown = false // allow a later retry
            throw error
        }

        isConnected = true
    }

    /// List every tool the server offers, following `nextCursor` pagination
    /// until the server stops returning one.
    func listTools() async throws -> [MCPToolDef] {
        guard isConnected else { throw MCPError.notConnected }

        var tools: [MCPToolDef] = []
        var cursor: String?
        // Bound the loop so a misbehaving server can't spin forever.
        var pages = 0

        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }

            let result = try await send(method: "tools/list", params: params)

            if let rawTools = result["tools"] as? [[String: Any]] {
                for entry in rawTools {
                    guard let name = entry["name"] as? String, !name.isEmpty else { continue }
                    let description = entry["description"] as? String ?? ""
                    let schema = entry["inputSchema"] as? [String: Any] ?? [:]
                    tools.append(MCPToolDef(name: name, description: description, inputSchema: schema))
                }
            }

            cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            pages += 1
        } while cursor != nil && pages < 100

        return tools
    }

    /// Invoke a tool and return its textual result. Text content parts are
    /// concatenated; non-text parts are labeled (e.g. `[image]`). When the
    /// server marks the result as an error, the text is still returned so the
    /// model can read and reason about the failure.
    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        guard isConnected else { throw MCPError.notConnected }

        let params: [String: Any] = [
            "name": name,
            "arguments": arguments,
        ]
        let result = try await send(method: "tools/call", params: params)
        return Self.flattenContent(result)
    }

    /// Terminate the child / cancel transport state. Idempotent and safe to call
    /// concurrently with itself.
    func shutdown() async {
        if didShutdown { return }
        didShutdown = true
        isConnected = false

        // Stop reading before terminating so the readability handler doesn't
        // fire against a torn-down pipe.
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        // End the ordered stdout channel and its reader.
        stdoutContinuation?.finish()
        stdoutContinuation = nil
        stdoutReaderTask?.cancel()
        stdoutReaderTask = nil

        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        try? stdinPipe?.fileHandleForWriting.close()

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        httpSession?.invalidateAndCancel()
        httpSession = nil

        // Fail any in-flight waiters so callers never hang past shutdown.
        failAllPending(with: MCPError.notConnected)
    }

    // MARK: - JSON-RPC core

    /// Send a request and await its matching response `result`. Applies the
    /// per-request timeout and cleans up the waiter on every exit path.
    private func send(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1

        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if !params.isEmpty { message["params"] = params }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message, options: [])
        } catch {
            throw MCPError.protocolError("Couldn't encode \(method) request: \(error.localizedDescription)")
        }

        switch transport {
        case .stdio:
            // The continuation body runs in the actor's isolation, so touching
            // `pending` / `timeoutTasks` here is race-free. A sibling timeout
            // Task calls `expire(id:)`; whichever fires first removes the id, so
            // the continuation is resumed exactly once.
            let timeoutNanos = UInt64(requestTimeout * 1_000_000_000)
            return try await withCheckedThrowingContinuation { continuation in
                self.pending[id] = continuation
                self.timeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanos)
                    await self?.expire(id: id)
                }
                do {
                    try self.writeStdioFrame(data)
                } catch {
                    self.finishPending(id: id, throwing: error)
                }
            }
        case .http(let urlString, let headers):
            return try await sendHTTP(id: id, body: data, urlString: urlString, headers: headers)
        }
    }

    /// Fire-and-forget notification (no id, no response expected).
    private func notify(method: String, params: [String: Any]) async throws {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if !params.isEmpty { message["params"] = params }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message, options: [])
        } catch {
            throw MCPError.protocolError("Couldn't encode \(method) notification: \(error.localizedDescription)")
        }

        switch transport {
        case .stdio:
            try writeStdioFrame(data)
        case .http(let urlString, let headers):
            // POST the notification; ignore any body. Servers reply 202/200.
            _ = try? await postHTTPRaw(body: data, urlString: urlString, headers: headers)
        }
    }

    /// Resume the waiter for `id` exactly once, canceling its timeout timer and
    /// removing it from both maps. A no-op if the id is already resolved.
    private func finishPending(id: Int, returning result: [String: Any]) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(returning: result)
    }

    private func finishPending(id: Int, throwing error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Time a waiter out: resume it with `.timeout` if it is still pending.
    private func expire(id: Int) {
        finishPending(id: id, throwing: MCPError.timeout)
    }

    /// Resume the waiter for a decoded JSON-RPC response object.
    private func resolve(_ object: [String: Any]) {
        // Only responses carry an id we track. Notifications / requests from the
        // server are ignored (we advertise no capabilities).
        guard let id = Self.intID(object["id"]) else { return }
        guard pending[id] != nil else { return }

        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? Self.intID(error["code"]) ?? -1
            let message = (error["message"] as? String) ?? "Unknown error"
            finishPending(id: id, throwing: MCPError.server(code: code, message: message))
            return
        }

        // Some responses (e.g. empty acks) may carry a non-object result.
        let result = (object["result"] as? [String: Any]) ?? [:]
        finishPending(id: id, returning: result)
    }

    private func failAllPending(with error: Error) {
        let ids = Array(pending.keys)
        for id in ids {
            finishPending(id: id, throwing: error)
        }
    }

    // MARK: - stdio transport

    private func startStdio() throws {
        guard case let .stdio(command, args, env) = transport else { return }

        let proc = Process()
        // Launch through `env` so PATH-based commands (npx, uvx, …) resolve.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + args

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in env { merged[key] = value }
        proc.environment = merged

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Stream stdout through one ordered channel: the readability handler
        // (invoked serially on its own queue) yields chunks into an AsyncStream,
        // and a single reader Task drains them in FIFO order into `ingestStdout`.
        // A per-chunk `Task` would let chunks hop onto the actor out of order and
        // corrupt a JSON frame that spans a read boundary.
        var stdoutContinuation: AsyncStream<Data>.Continuation!
        let stdoutStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { stdoutContinuation = $0 }
        let continuation = stdoutContinuation!
        self.stdoutContinuation = continuation
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { continuation.yield(chunk) }
        }
        self.stdoutReaderTask = Task { [weak self] in
            for await chunk in stdoutStream {
                await self?.ingestStdout(chunk)
            }
        }
        // Capture stderr for diagnostics; never let it crash us.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            Task { await self.appendStderr(chunk) }
        }
        // Surface early exit as a transport failure for every pending waiter.
        proc.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            let status = terminated.terminationStatus
            Task { await self.handleProcessExit(status: status) }
        }

        do {
            try proc.run()
        } catch {
            throw MCPError.transport("Couldn't launch '\(command)': \(error.localizedDescription)")
        }

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
    }

    /// Write one newline-delimited JSON frame to the child's stdin.
    private func writeStdioFrame(_ data: Data) throws {
        guard let handle = stdinPipe?.fileHandleForWriting else {
            throw MCPError.notConnected
        }
        var frame = data
        frame.append(0x0A) // '\n'
        do {
            try handle.write(contentsOf: frame)
        } catch {
            throw MCPError.transport("Couldn't write to server stdin: \(error.localizedDescription)")
        }
    }

    /// Append a stdout chunk and dispatch every complete line it produced.
    private func ingestStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)

        let newline: UInt8 = 0x0A
        while let index = stdoutBuffer.firstIndex(of: newline) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<index)
            // Drop the line plus its terminating newline.
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...index)

            // Skip blank lines / stray carriage returns.
            let trimmed = lineData.filter { $0 != 0x0D }
            guard !trimmed.isEmpty else { continue }

            guard let object = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
                // Not a JSON object (could be a log line the server misrouted);
                // ignore rather than fail the whole session.
                continue
            }
            resolve(object)
        }
    }

    private func appendStderr(_ chunk: Data) {
        stderrBuffer.append(chunk)
        // Keep the buffer bounded — only the tail is useful for messages.
        if stderrBuffer.count > 16_384 {
            stderrBuffer.removeSubrange(stderrBuffer.startIndex..<(stderrBuffer.endIndex - 8_192))
        }
    }

    private func handleProcessExit(status: Int32) {
        guard !didShutdown else { return }
        isConnected = false
        let err = stderrString()
        let detail = err.isEmpty
            ? "The MCP server process exited (status \(status))."
            : "The MCP server process exited (status \(status)): \(err)"
        failAllPending(with: MCPError.transport(detail))
    }

    private func stderrString() -> String {
        let text = String(data: stderrBuffer, encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP transport

    private func startHTTP() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout
        httpSession = URLSession(configuration: config)
        mcpSessionID = nil
    }

    /// POST one JSON-RPC request and return the response matching `id`, parsing
    /// either a plain JSON body or an SSE (`text/event-stream`) body.
    private func sendHTTP(id: Int,
                          body: Data,
                          urlString: String,
                          headers: [String: String]) async throws -> [String: Any] {
        let (data, response) = try await postHTTPRaw(body: body, urlString: urlString, headers: headers)

        if let http = response as? HTTPURLResponse {
            // Persist a server-assigned session id (case-insensitive header).
            if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
                mcpSessionID = sid
            }
            guard (200...299).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw MCPError.transport("HTTP \(http.statusCode): \(bodyText.prefix(300))")
            }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("text/event-stream") {
                guard let object = Self.extractSSEResponse(data, matchingID: id) else {
                    throw MCPError.protocolError("No JSON-RPC response for id \(id) in the event stream.")
                }
                return try Self.resultOrThrow(object)
            }
        }

        // Default: a single JSON-RPC response object.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.protocolError("Response was not a JSON-RPC object.")
        }
        return try Self.resultOrThrow(object)
    }

    /// The raw POST shared by requests and notifications. Applies caller headers,
    /// the MCP content negotiation headers, and the persisted session id.
    private func postHTTPRaw(body: Data,
                             urlString: String,
                             headers: [String: String]) async throws -> (Data, URLResponse) {
        guard let session = httpSession else { throw MCPError.notConnected }
        guard let url = URL(string: urlString) else {
            throw MCPError.transport("Invalid MCP URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sid = mcpSessionID {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }

        do {
            return try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw MCPError.timeout
        } catch {
            throw MCPError.transport(error.localizedDescription)
        }
    }

    // MARK: - Static helpers

    /// Turn a JSON-RPC response object into its `result`, throwing on an error
    /// object. Used by the HTTP path (stdio resolves via continuations).
    private static func resultOrThrow(_ object: [String: Any]) throws -> [String: Any] {
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? intID(error["code"]) ?? -1
            let message = (error["message"] as? String) ?? "Unknown error"
            throw MCPError.server(code: code, message: message)
        }
        return (object["result"] as? [String: Any]) ?? [:]
    }

    /// Scan an SSE body for the first `data:` payload that is a JSON-RPC
    /// response carrying our `id` (or, defensively, an error/result object).
    private static func extractSSEResponse(_ data: Data, matchingID id: Int) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var fallback: [String: Any]?
        // SSE lines are separated by \n; a data field may span multiple `data:`
        // lines, but MCP payloads are single-line JSON, so per-line parsing is
        // sufficient and robust.
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            guard line.hasPrefix("data:") else { continue }

            var payload = line.dropFirst("data:".count)
            if payload.hasPrefix(" ") { payload = payload.dropFirst() }
            guard let payloadData = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }

            if let objID = intID(object["id"]), objID == id {
                return object
            }
            // Keep the last response-shaped object as a fallback in case the id
            // is absent (spec-compliant servers always echo it, but be lenient).
            if object["result"] != nil || object["error"] != nil {
                fallback = object
            }
        }
        return fallback
    }

    /// Concatenate the text parts of a `tools/call` result. Non-text parts are
    /// labeled by type. The `isError` flag is intentionally ignored for the
    /// return value — the caller wants the text either way.
    private static func flattenContent(_ result: [String: Any]) -> String {
        guard let parts = result["content"] as? [[String: Any]] else {
            // Some servers may return structured content only; stringify it.
            if let structured = result["structuredContent"],
               let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return ""
        }

        var pieces: [String] = []
        for part in parts {
            let type = part["type"] as? String ?? "unknown"
            switch type {
            case "text":
                if let text = part["text"] as? String { pieces.append(text) }
            case "image":
                pieces.append("[image]")
            case "audio":
                pieces.append("[audio]")
            case "resource", "resource_link":
                // Prefer an embedded resource's text if present.
                if let resource = part["resource"] as? [String: Any],
                   let text = resource["text"] as? String {
                    pieces.append(text)
                } else if let uri = (part["uri"] as? String) ?? (part["resource"] as? [String: Any])?["uri"] as? String {
                    pieces.append("[resource: \(uri)]")
                } else {
                    pieces.append("[resource]")
                }
            default:
                pieces.append("[\(type)]")
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// Coerce a JSON id (Int, or a numeric NSNumber/String) into an Int.
    private static func intID(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}
