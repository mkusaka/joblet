import CoreFoundation
import Foundation

/// Dependency-free MCP/JSON-RPC stdio protocol adapter.
/// Supports modern 2026-07-28 (per-request metadata) and legacy initialize clients.
/// Each request is completed before reading the next one; mutations are never run concurrently.
public actor MCPProtocolServer {
    private let tools: MCPToolRouter
    private var initializedLegacy = false
    private let serverInfo: [String: String] = ["name": "joblet-mcp", "version": "0.2.0"]
    private let modernVersion = "2026-07-28"

    public init(router: MCPToolRouter) {
        tools = router
    }

    /// Returns one newline-free JSON-RPC response, or nil for notifications.
    public func handle(_ line: Data) async -> Data? {
        guard line.count <= 262_144 else {
            return encode(Self.failure(NSNull(), -32600, "Request exceeds 256 KiB"))
        }
        guard let raw = try? JSONSerialization.jsonObject(with: line) else {
            return encode(Self.failure(NSNull(), -32700, "Invalid JSON"))
        }
        // JSON-RPC batches are not part of MCP since 2025-06-18.
        guard let request = raw as? [String: Any] else {
            return encode(Self.failure(NSNull(), -32600, "Invalid JSON-RPC request"))
        }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return encode(Self.failure(Self.validID(request["id"]) ?? NSNull(), -32600, "Invalid JSON-RPC request"))
        }
        // Notifications never receive responses. Unknown notifications are ignored.
        guard let id = Self.validID(request["id"]) else { return nil }
        let params: [String: Any]
        if let rawParams = request["params"] {
            guard let object = rawParams as? [String: Any] else {
                return encode(Self.failure(id, -32602, "params must be an object"))
            }
            params = object
        } else { params = [:] }

        let meta = params["_meta"] as? [String: Any]
        let requested = meta?["io.modelcontextprotocol/protocolVersion"] as? String
        let modern = requested != nil
        if modern, requested != modernVersion {
            return encode(["jsonrpc": "2.0", "id": id,
                           "error": ["code": -32022, "message": "Unsupported protocol version",
                                     "data": ["requested": requested!,
                                              "supported": [modernVersion, "2025-11-25", "2025-06-18", "2024-11-05"]]]])
        }
        if modern, !(meta?["io.modelcontextprotocol/clientCapabilities"] is [String: Any]) {
            return encode(Self.failure(id, -32602, "Modern MCP requires _meta.io.modelcontextprotocol/clientCapabilities (object)"))
        }

        let result: [String: Any]
        switch method {
        case "server/discover":
            guard modern else { return encode(Self.failure(id, -32601, "Method not found")) }
            result = ["resultType": "complete", "supportedVersions": [modernVersion],
                      "capabilities": ["tools": [:]], "ttlMs": 300_000,
                      "cacheScope": "private", "_meta": Self.serverMeta(serverInfo),
                      "instructions": "Read-only by default. Tools for changes/run/delete only appear when explicitly enabled with --allow-* options. Use current revision tokens for mutations."]
        case "initialize":
            // Older hosts negotiate a protocol version once and send notifications/initialized.
            let requestedLegacy = params["protocolVersion"] as? String
            let supported = ["2025-11-25", "2025-06-18", "2024-11-05"]
            initializedLegacy = true
            result = ["protocolVersion": supported.contains(requestedLegacy ?? "") ? requestedLegacy! : "2025-11-25",
                      "serverInfo": serverInfo, "capabilities": ["tools": [:]],
                      "instructions": "Use current revision tokens before mutating jobs. Only opt-in capabilities are available."]
        case "ping":
            guard modern || initializedLegacy else { return encode(Self.failure(id, -32600, "Send initialize first (legacy protocol), or include the per-request _meta fields (2026-07-28)")) }
            result = modern ? ["resultType": "complete", "_meta": Self.serverMeta(serverInfo)] : [:]
        case "tools/list":
            guard modern || initializedLegacy else { return encode(Self.failure(id, -32600, "Send initialize first (legacy protocol), or include the per-request _meta fields (2026-07-28)")) }
            result = await listing(modern: modern)
        case "tools/call":
            guard modern || initializedLegacy else { return encode(Self.failure(id, -32600, "Send initialize first (legacy protocol), or include the per-request _meta fields (2026-07-28)")) }
            guard let name = params["name"] as? String else {
                return encode(Self.failure(id, -32602, "Missing tool name"))
            }
            guard await (tools.tools()).contains(where: { $0["name"] as? String == name }) else {
                return encode(Self.failure(id, -32602, "Unknown or disabled tool: \(name)"))
            }
            let arguments: [String: Any]
            if let value = params["arguments"] {
                guard let object = value as? [String: Any] else {
                    return encode(Self.failure(id, -32602, "Tool arguments must be an object"))
                }
                arguments = object
            } else { arguments = [:] }
            do {
                let output = try await tools.call(name, arguments: arguments)
                result = Self.toolResult(output, modern: modern, serverInfo: serverInfo)
                if ["create_job", "update_job", "set_job_enabled", "set_job_group", "run_job", "delete_job"].contains(name) {
                    Self.audit(name: name, succeeded: true)
                }
            } catch {
                Self.audit(name: name, succeeded: false)
                var errorResult: [String: Any] = ["content": [["type": "text", "text": error.localizedDescription]],
                                                  "isError": true]
                if modern {
                    errorResult["resultType"] = "complete"
                    errorResult["_meta"] = Self.serverMeta(serverInfo)
                }
                result = errorResult
            }
        default:
            return encode(Self.failure(id, -32601, "Method not found: \(method)"))
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func listing(modern: Bool) async -> [String: Any] {
        var value: [String: Any] = await ["tools": tools.tools()]
        if modern {
            value["resultType"] = "complete"
            value["ttlMs"] = 300_000
            value["cacheScope"] = "private"
            value["_meta"] = Self.serverMeta(serverInfo)
        }
        return value
    }

    private static func toolResult(_ output: [String: Any], modern: Bool, serverInfo: [String: String]) -> [String: Any] {
        let serialized = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data("{}".utf8)
        var result: [String: Any] = ["content": [["type": "text", "text": String(decoding: serialized, as: UTF8.self)]],
                                     "structuredContent": output, "isError": false]
        if modern {
            result["resultType"] = "complete"
            result["_meta"] = serverMeta(serverInfo)
        }
        return result
    }

    private static func serverMeta(_ info: [String: String]) -> [String: Any] {
        ["io.modelcontextprotocol/serverInfo": info]
    }

    private static func validID(_ value: Any?) -> Any? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return number
        }
        return nil
    }

    private static func failure(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ value: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func audit(name: String, succeeded: Bool) {
        // Never print commands, logs or tool arguments; stdout is exclusively JSON-RPC.
        let message = "[joblet-mcp] \(name): \(succeeded ? "ok" : "failed")\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
