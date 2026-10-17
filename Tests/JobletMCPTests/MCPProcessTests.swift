import Foundation
import XCTest

/// Spawns the real joblet-mcp binary. Only protocol methods that never touch launchd are used.
final class MCPProcessTests: XCTestCase {
    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("joblet-mcp")
    }

    private func readLine(_ handle: FileHandle) throws -> [String: Any] {
        var line = Data()
        while true {
            let byte = try XCTUnwrap(try handle.read(upToCount: 1), "stdout closed before a full line")
            if byte.isEmpty { XCTFail("stdout closed"); return [:] }
            if byte[0] == 10 { break }
            line.append(byte)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    func testStdioHandshakeAnswersWhileStdinStaysOpen() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "joblet-mcp is not built next to the test bundle")
        let process = Process()
        process.executableURL = binary
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // Send one request in two chunks: the server must reassemble it and reply before EOF.
        let first = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: first.prefix(10))
        try input.fileHandleForWriting.write(contentsOf: first.dropFirst(10))
        XCTAssertEqual(try (readLine(output.fileHandleForReading)["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")

        try input.fileHandleForWriting.write(contentsOf: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8) + Data([10]))
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8) + Data([10]))
        let tools = try (readLine(output.fileHandleForReading)["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["list_jobs", "get_job", "read_log"])

        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":3,"method":"server/discover","params":{\#(meta)}}"#.utf8) + Data([10]))
        let discover = try readLine(output.fileHandleForReading)["result"] as? [String: Any]
        XCTAssertEqual(discover?["supportedVersions"] as? [String], ["2026-07-28"])

        try input.fileHandleForWriting.close() // EOF is the shutdown signal
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testUnknownFlagExitsWithUsageError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "joblet-mcp is not built next to the test bundle")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--bogus"]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2)
    }
}
