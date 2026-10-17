import Foundation
import JobletCore
import JobletMCP

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let options: ServerOptions
do {
    options = try ServerOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    log("\(error)\n\(ServerOptions.usage)")
    exit(CommandLine.arguments.contains("--help") ? 0 : 2)
}

let server = MCPServer(repository: JobRepository(), options: options)
log("joblet-mcp ready; tools: \(server.enabledToolNames.joined(separator: ", "))")
// stdout carries protocol messages only; everything else goes to stderr.
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let response = await server.handle(line: line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
