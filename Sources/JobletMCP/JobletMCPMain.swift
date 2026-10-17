import Foundation
import JobletMCPKit
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@main
struct JobletMCPMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") {
            FileHandle.standardError.write(Data("""
            Joblet MCP (stdio)
            By default: read-only, Joblet-owned LaunchAgents only.
            --allow-write             create, update, enable/disable
            --allow-run               manually execute a job
            --allow-delete            remove Joblet-owned jobs (backup retained)
            --include-external        show/read third-party LaunchAgents
            --allow-external-control  enable/disable/run third-party jobs (requires --include-external)
            Configure your MCP host to launch this executable directly. See docs/MCP.md.

            """.utf8))
            return
        }
        let permissions: MCPPermissions
        do { permissions = try MCPPermissions.parse(arguments) }
        catch {
            FileHandle.standardError.write(Data("[joblet-mcp] \(error.localizedDescription)\n".utf8))
            exit(2)
        }
        let server = MCPProtocolServer(router: MCPToolRouter(permissions: permissions))
        let output = FileHandle.standardOutput
        var readBuffer = [UInt8](repeating: 0, count: 4096)
        var currentLine = Data()
        var tooLarge = false

        // Bounded streaming input: clients must send one UTF-8 JSON-RPC message per line.
        // Do not read arbitrary-size stdin lines, even when the agent is compromised.
        while true {
            // Unlike FileHandle.readData(ofLength:), a single POSIX read returns
            // promptly with whatever bytes are available on an open pipe.
            // MCP clients keep stdin open between calls, so waiting for 4096 bytes
            // would deadlock the first request.
            let count = readBuffer.withUnsafeMutableBytes { memory -> Int in
                #if canImport(Darwin)
                    return Darwin.read(STDIN_FILENO, memory.baseAddress, memory.count)
                #else
                    return Glibc.read(STDIN_FILENO, memory.baseAddress, memory.count)
                #endif
            }
            if count < 0 {
                if errno == EINTR { continue }
                FileHandle.standardError.write(Data("[joblet-mcp] stdin read failed\n".utf8))
                exit(1)
            }
            if count == 0 { break }
            for byte in readBuffer.prefix(count) {
                if byte == 10 { // newline
                    if tooLarge {
                        output.write(Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Request exceeds 256 KiB\"}}\n".utf8))
                    } else if !currentLine.isEmpty, let response = await server.handle(currentLine) {
                        output.write(response + Data([10]))
                    }
                    currentLine.removeAll(keepingCapacity: true)
                    tooLarge = false
                } else if !tooLarge {
                    if currentLine.count < 262_144 { currentLine.append(byte) }
                    else { currentLine.removeAll(keepingCapacity: false); tooLarge = true }
                }
            }
        }
        // Closing stdin is the MCP shutdown signal. A trailing non-newline message is ignored.
    }
}
