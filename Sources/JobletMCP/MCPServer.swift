import Foundation
import JobletCore

// Implements MCP over stdio (newline-delimited JSON-RPC 2.0) following specification revision 2025-11-25
// (initialize handshake era) plus the older revisions listed below. The newer stateless revision 2026-07-28
// (per-request _meta, server/discover) is not implemented: unknown methods return -32601, which modern
// clients treat as "legacy server" and fall back to `initialize`.
// Spec: https://modelcontextprotocol.io/specification/2025-11-25

public final class MCPServer {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private let runner: ToolRunner

    public init(repository: JobRepository, options: ServerOptions) {
        runner = ToolRunner(repository: repository, permissions: options.permissions)
    }

    public var enabledToolNames: [String] {
        runner.enabledTools.map(\.name)
    }

    /// Handles one input line. Returns the single-line response, or nil for notifications.
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            return encode(error(id: NSNull(), code: -32700, "Parse error"))
        }
        guard let message = object as? JSON, message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return encode(error(id: (object as? JSON)?["id"] ?? NSNull(), code: -32600, "Invalid Request"))
        }
        guard let id = message["id"] else { return nil } // notification (e.g. notifications/initialized)
        guard id is String || id is NSNumber else { return encode(error(id: NSNull(), code: -32600, "Invalid Request")) }
        let params = message["params"] as? JSON ?? [:]
        if message["params"] != nil, message["params"] as? JSON == nil {
            return encode(error(id: id, code: -32602, "params must be an object"))
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return encode(result(id: id, [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "joblet-mcp", "title": "Joblet", "version": "0.1.0"],
                "instructions": "Manage the user's launchd LaunchAgents. Read-only unless the server was started with --allow-* flags.",
            ]))
        case "ping":
            return encode(result(id: id, [:]))
        case "tools/list":
            return encode(result(id: id, ["tools": runner.enabledTools.map(\.json)]))
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return encode(error(id: id, code: -32601, "Method not found: \(method)"))
        }
    }

    private func callTool(id: Any, params: JSON) async -> String? {
        guard let name = params["name"] as? String else { return encode(error(id: id, code: -32602, "name is required")) }
        let arguments: JSON
        if let raw = params["arguments"] {
            guard let object = raw as? JSON else { return encode(error(id: id, code: -32602, "arguments must be an object")) }
            arguments = object
        } else { arguments = [:] }
        do {
            guard let structured = try await runner.call(name, arguments) else {
                return encode(error(id: id, code: -32602, "Unknown tool: \(name)"))
            }
            return encode(result(id: id, ["content": [["type": "text", "text": text(structured)]],
                                          "structuredContent": structured, "isError": false]))
        } catch let failure as ToolError {
            return encode(toolFailure(id: id, failure.message))
        } catch {
            return encode(toolFailure(id: id, error.localizedDescription))
        }
    }

    private func toolFailure(id: Any, _ message: String) -> JSON {
        result(id: id, ["content": [["type": "text", "text": message]], "isError": true])
    }

    private func result(id: Any, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(id: Any, code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func text(_ object: JSON) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Compact output: JSONSerialization escapes newlines inside strings, so the result is always one line.
    private func encode(_ message: JSON) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
