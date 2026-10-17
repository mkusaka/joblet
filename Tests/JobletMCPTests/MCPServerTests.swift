import Foundation
import JobletCore
@testable import JobletMCP
import XCTest

private final class TemporaryHome {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("JobletMCPTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes a plist that Joblet did not create and registers it with the fake launchd.
    func addForeignJob(label: String, launchctl: InMemoryLaunchctl) async throws {
        let agents = url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = agents.appendingPathComponent(label + ".plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": ["/bin/echo", "hi"]], format: .xml, options: 0)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        await launchctl.register(label, path: file.path)
        await launchctl.setDisabled(false, label: label)
    }
}

private struct Reply {
    let json: JSON
    var result: JSON {
        json["result"] as? JSON ?? [:]
    }

    var errorCode: Int? {
        (json["error"] as? JSON)?["code"] as? Int
    }

    var isToolError: Bool {
        result["isError"] as? Bool == true
    }

    var structured: JSON {
        result["structuredContent"] as? JSON ?? [:]
    }

    var errorText: String {
        ((result["content"] as? [JSON])?.first?["text"] as? String) ?? ""
    }
}

final class MCPServerTests: XCTestCase {
    private var home: TemporaryHome!
    private var launchctl: InMemoryLaunchctl!
    private var nextID = 0

    override func setUpWithError() throws {
        home = try TemporaryHome()
        launchctl = InMemoryLaunchctl()
    }

    private func makeServer(_ permissions: Set<Permission> = []) -> MCPServer {
        MCPServer(repository: JobRepository(homeDirectory: home.url, runner: launchctl),
                  options: ServerOptions(permissions: permissions))
    }

    private func request(_ server: MCPServer, _ method: String, _ params: JSON? = nil) async throws -> Reply {
        nextID += 1
        var message: JSON = ["jsonrpc": "2.0", "id": nextID, "method": method]
        if let params { message["params"] = params }
        let line = try String(decoding: JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        return try await raw(server, line)
    }

    private func raw(_ server: MCPServer, _ line: String) async throws -> Reply {
        let handled = await server.handle(line: line)
        let response = try XCTUnwrap(handled)
        XCTAssertFalse(response.contains("\n"), "responses must be single-line")
        return try Reply(json: XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? JSON))
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: JSON = [:]) async throws -> Reply {
        try await request(server, "tools/call", ["name": tool, "arguments": arguments])
    }

    private func toolNames(_ server: MCPServer) async throws -> [String] {
        try await (request(server, "tools/list").result["tools"] as? [JSON] ?? []).compactMap { $0["name"] as? String }
    }

    private func createJob(_ server: MCPServer, name: String = "Backup", enabled: Bool = true) async throws -> String {
        let reply = try await call(server, "create_job", ["name": name, "command": "echo hi", "enabled": enabled,
                                                          "schedule": ["kind": "interval", "interval_minutes": 30]])
        XCTAssertFalse(reply.isToolError, reply.errorText)
        return try XCTUnwrap(reply.structured["label"] as? String)
    }

    // MARK: Protocol

    func testInitializeNegotiatesVersion() async throws {
        let server = makeServer()
        let known = try await request(server, "initialize", ["protocolVersion": "2025-06-18", "capabilities": JSON(), "clientInfo": ["name": "t", "version": "1"]])
        XCTAssertEqual(known.result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((known.result["capabilities"] as? JSON)?["tools"])
        XCTAssertEqual((known.result["serverInfo"] as? JSON)?["name"] as? String, "joblet-mcp")
        let unknown = try await request(server, "initialize", ["protocolVersion": "1999-01-01"])
        XCTAssertEqual(unknown.result["protocolVersion"] as? String, MCPServer.supportedVersions[0])
    }

    func testNotificationsGetNoResponseAndPingWorks() async throws {
        let server = makeServer()
        let notification = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification)
        let ping = try await request(server, "ping")
        XCTAssertNil(ping.json["error"])
        XCTAssertEqual(ping.json["id"] as? Int, nextID)
    }

    func testProtocolErrors() async throws {
        let server = makeServer()
        let malformed = try await raw(server, "{not json")
        XCTAssertEqual(malformed.errorCode, -32700)
        XCTAssertTrue(malformed.json["id"] is NSNull)
        let notRequest = try await raw(server, "[1,2]")
        XCTAssertEqual(notRequest.errorCode, -32600)
        let missingMethod = try await raw(server, #"{"jsonrpc":"2.0","id":1}"#)
        XCTAssertEqual(missingMethod.errorCode, -32600)
        let unknownMethod = try await request(server, "resources/list")
        XCTAssertEqual(unknownMethod.errorCode, -32601)
        let noName = try await request(server, "tools/call", [:])
        XCTAssertEqual(noName.errorCode, -32602)
        let badArguments = try await request(server, "tools/call", ["name": "list_jobs", "arguments": "x"])
        XCTAssertEqual(badArguments.errorCode, -32602)
        let unknownTool = try await call(server, "nope")
        XCTAssertEqual(unknownTool.errorCode, -32602)
    }

    // MARK: Permissions

    func testToolListRespectsFlags() async throws {
        let readOnly = try await toolNames(makeServer())
        XCTAssertEqual(readOnly, ["list_jobs", "get_job", "read_log"])
        let run = try await toolNames(makeServer([.run]))
        XCTAssertEqual(run, ["list_jobs", "get_job", "read_log", "run_job"])
        let update = try await toolNames(makeServer([.update]))
        XCTAssertEqual(update, ["list_jobs", "get_job", "read_log", "update_job", "set_job_enabled"])
        let all = try await toolNames(makeServer(Set(Permission.allCases)))
        XCTAssertEqual(all.count, 8)
    }

    func testDisabledToolsAreRejected() async throws {
        let server = makeServer()
        for (tool, flag) in [("create_job", "--allow-create"), ("update_job", "--allow-update"), ("set_job_enabled", "--allow-update"),
                             ("run_job", "--allow-run"), ("delete_job", "--allow-delete")]
        {
            let reply = try await call(server, tool, ["label": "x", "name": "n", "command": "c", "enabled": true])
            XCTAssertTrue(reply.isToolError, tool)
            XCTAssertTrue(reply.errorText.contains(flag), reply.errorText)
        }
        let agents = home.url.appendingPathComponent("Library/LaunchAgents").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents))
    }

    func testParseOptions() throws {
        XCTAssertEqual(try ServerOptions.parse([]).permissions, [])
        XCTAssertEqual(try ServerOptions.parse(["--allow-all"]).permissions, [.create, .update, .run, .delete])
        XCTAssertEqual(try ServerOptions.parse(["--allow-run", "--allow-foreign-jobs"]).permissions, [.run, .foreignJobs])
        XCTAssertThrowsError(try ServerOptions.parse(["--allow-everything"]))
    }

    // MARK: Tools

    func testCreateListGetAndLog() async throws {
        let server = makeServer([.create])
        let label = try await createJob(server)
        XCTAssertTrue(label.hasPrefix("local.joblet."))
        let list = try await call(server, "list_jobs")
        let jobs = try XCTUnwrap(list.structured["jobs"] as? [JSON])
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0]["label"] as? String, label)
        XCTAssertEqual(jobs[0]["phase"] as? String, "waiting")
        XCTAssertEqual((jobs[0]["schedule"] as? JSON)?["interval_minutes"] as? Int, 30)
        let get = try await call(server, "get_job", ["label": label])
        XCTAssertTrue((get.structured["plist"] as? String)?.contains(label) == true)
        let log = try await call(server, "read_log", ["label": label, "stream": "stderr"])
        XCTAssertFalse(log.isToolError, log.errorText)
        XCTAssertEqual(log.structured["stream"] as? String, "stderr")
        let badStream = try await call(server, "read_log", ["label": label, "stream": "x"])
        XCTAssertTrue(badStream.isToolError)
    }

    func testCreateValidation() async throws {
        let server = makeServer([.create])
        let missing = try await call(server, "create_job", ["name": "x"])
        XCTAssertTrue(missing.isToolError)
        let badType = try await call(server, "create_job", ["name": "x", "command": "date", "enabled": "yes"])
        XCTAssertTrue(badType.isToolError)
        let badInterval = try await call(server, "create_job", ["name": "x", "command": "date", "schedule": ["kind": "interval", "interval_minutes": 0]])
        XCTAssertTrue(badInterval.isToolError)
        let badDirectory = try await call(server, "create_job", ["name": "x", "command": "date", "working_directory": "/does/not/exist"])
        XCTAssertTrue(badDirectory.isToolError)
        let listed = try await call(makeServer(), "list_jobs")
        XCTAssertEqual((listed.structured["jobs"] as? [JSON])?.count, 0)
    }

    func testUpdateKeepsOmittedFields() async throws {
        let server = makeServer([.create, .update])
        let label = try await createJob(server)
        let reply = try await call(server, "update_job", ["label": label, "name": "Renamed", "schedule": ["kind": "daily", "hour": 7, "minute": 5]])
        XCTAssertFalse(reply.isToolError, reply.errorText)
        XCTAssertEqual(reply.structured["name"] as? String, "Renamed")
        XCTAssertEqual(reply.structured["command"] as? String, "echo hi")
        XCTAssertEqual((reply.structured["schedule"] as? JSON)?["hour"] as? Int, 7)
        XCTAssertEqual(reply.structured["enabled"] as? Bool, true)
    }

    func testSetEnabledRoundTrip() async throws {
        let server = makeServer([.create, .update])
        let label = try await createJob(server)
        let off = try await call(server, "set_job_enabled", ["label": label, "enabled": false])
        XCTAssertFalse(off.isToolError, off.errorText)
        XCTAssertEqual(off.structured["enabled"] as? Bool, false)
        let on = try await call(server, "set_job_enabled", ["label": label, "enabled": true])
        XCTAssertEqual(on.structured["enabled"] as? Bool, true)
        XCTAssertEqual(on.structured["phase"] as? String, "waiting")
    }

    func testRunJob() async throws {
        let server = makeServer([.create, .run])
        let label = try await createJob(server)
        let reply = try await call(server, "run_job", ["label": label])
        XCTAssertFalse(reply.isToolError, reply.errorText)
        XCTAssertEqual(reply.structured["phase"] as? String, "running")
        let calls = await launchctl.calls()
        XCTAssertTrue(calls.contains { $0.first == "kickstart" })
        let again = try await call(server, "run_job", ["label": label])
        XCTAssertTrue(again.isToolError, "running job must not be started twice")
    }

    func testDeleteJob() async throws {
        let server = makeServer([.create, .delete])
        let label = try await createJob(server)
        let reply = try await call(server, "delete_job", ["label": label])
        XCTAssertFalse(reply.isToolError, reply.errorText)
        let listed = try await call(server, "list_jobs")
        XCTAssertEqual((listed.structured["jobs"] as? [JSON])?.count, 0)
        let missing = try await call(server, "delete_job", ["label": label])
        XCTAssertTrue(missing.isToolError)
    }

    // MARK: Foreign jobs

    func testForeignJobsAreProtected() async throws {
        let foreign = "com.example.thing"
        try await home.addForeignJob(label: foreign, launchctl: launchctl)

        let strict = makeServer([.update, .run, .delete])
        let listed = try await call(strict, "list_jobs")
        let jobs = try XCTUnwrap(listed.structured["jobs"] as? [JSON])
        XCTAssertEqual(jobs.first?["created_by_joblet"] as? Bool, false)
        let get = try await call(strict, "get_job", ["label": foreign])
        XCTAssertFalse(get.isToolError, get.errorText)
        for (tool, arguments) in [("run_job", JSON()), ("set_job_enabled", ["enabled": false]), ("update_job", ["name": "x"]),
                                  ("delete_job", JSON()), ("read_log", JSON())]
        {
            let reply = try await call(strict, tool, arguments.merging(["label": foreign]) { $1 })
            XCTAssertTrue(reply.isToolError, tool)
        }
        let calls = await launchctl.calls().filter { !["print", "print-disabled"].contains($0.first ?? "") }
        XCTAssertTrue(calls.isEmpty, "no mutating launchctl call may happen: \(calls)")
    }

    func testAllowForeignLiftsOnlyRunAndEnable() async throws {
        let foreign = "com.example.thing"
        try await home.addForeignJob(label: foreign, launchctl: launchctl)
        let server = makeServer(Set(Permission.allCases))
        let run = try await call(server, "run_job", ["label": foreign])
        XCTAssertFalse(run.isToolError, run.errorText)
        XCTAssertEqual(run.structured["phase"] as? String, "running")
        for tool in ["delete_job", "update_job", "read_log"] {
            let reply = try await call(server, tool, ["label": foreign, "name": "x"])
            XCTAssertTrue(reply.isToolError, tool)
        }
    }
}
