import Foundation
@testable import JobletCore
@testable import JobletMCPKit
import XCTest
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class MCPTests: XCTestCase {
    func testReadOnlyToolsAndLegacyInitialization() async throws {
        let service = StubService()
        let server = MCPProtocolServer(router: MCPToolRouter(service: service))
        let before = try await request(server, 1, "tools/list")
        XCTAssertEqual((before["error"] as? [String: Any])?["code"] as? Int, -32600)
        let initResponse = try await request(server, 2, "initialize", ["protocolVersion": "2025-11-25"])
        XCTAssertEqual((initResponse["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let listed = try await request(server, 3, "tools/list")
        XCTAssertEqual(toolNames(listed), ["list_jobs", "get_job", "read_log"])
        let blocked = try await request(server, 4, "tools/call", ["name": "create_job", "arguments": ["name": "X", "command": "date"]])
        XCTAssertEqual((blocked["error"] as? [String: Any])?["code"] as? Int, -32602)
        let notification = try await server.handle(json(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(notification)
        let creations = await service.created()
        XCTAssertEqual(creations, 0)
    }

    func testModernDiscoveryAndStructuredResult() async throws {
        let server = MCPProtocolServer(router: MCPToolRouter(service: StubService()))
        let meta: [String: Any] = ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                             "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
                                             "io.modelcontextprotocol/clientCapabilities": [:]]]
        let discover = try await request(server, "a", "server/discover", meta)
        let value = try XCTUnwrap(discover["result"] as? [String: Any])
        XCTAssertEqual(value["resultType"] as? String, "complete")
        XCTAssertEqual(value["supportedVersions"] as? [String], ["2026-07-28"])
        XCTAssertNotNil(value["_meta"])
        let listed = try await request(server, "b", "tools/list", meta)
        XCTAssertEqual((listed["result"] as? [String: Any])?["resultType"] as? String, "complete")
        var params = meta
        params["name"] = "list_jobs"
        params["arguments"] = [:]
        let called = try await request(server, "c", "tools/call", params)
        let result = try XCTUnwrap(called["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["total"] as? Int, 0)
        XCTAssertNotNil(result["content"])
    }

    func testInvalidProtocolInputAndPermissionsParser() async throws {
        let server = MCPProtocolServer(router: MCPToolRouter(service: StubService()))
        let malformed = await server.handle(Data("not-json".utf8))
        XCTAssertNotNil(try decode(XCTUnwrap(malformed))["error"])
        let tooLarge = await server.handle(Data(repeating: 65, count: 262_145))
        XCTAssertNotNil(try decode(XCTUnwrap(tooLarge))["error"])
        let unsupported = try await request(server, 1, "server/discover", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2027-01-01",
                                                                                     "io.modelcontextprotocol/clientCapabilities": [:]]])
        XCTAssertEqual((unsupported["error"] as? [String: Any])?["code"] as? Int, -32022)
        let unsupportedData = (unsupported["error"] as? [String: Any])?["data"] as? [String: Any]
        XCTAssertEqual(unsupportedData?["requested"] as? String, "2027-01-01")
        XCTAssertThrowsError(try MCPPermissions.parse(["--allow-external-control"]))
        XCTAssertThrowsError(try MCPPermissions.parse(["--unknown-option"]))
        XCTAssertEqual(try MCPPermissions.parse(["--allow-write", "--allow-run"]),
                       MCPPermissions(allowWrite: true, allowRun: true))
    }

    func testCreateEditEnableRunLogsAndDeleteWithRealRepositoryFakeLaunchctl() async throws {
        let home = try MCPTemporaryHome()
        let launchctl = InMemoryLaunchctl()
        let repository = JobRepository(homeDirectory: home.url, runner: launchctl)
        let router = MCPToolRouter(service: repository,
                                   permissions: .init(allowWrite: true, allowRun: true, allowDelete: true))
        let server = MCPProtocolServer(router: router)
        _ = try await request(server, 1, "initialize", ["protocolVersion": "2025-11-25"])
        let created = try await call(server, "create_job", ["name": "MCP test", "command": "date",
                                                            "schedule": ["kind": "manual"]])
        XCTAssertEqual(created["enabled"] as? Bool, false)
        let label = try XCTUnwrap(created["label"] as? String)
        let get = try await call(server, "get_job", ["label": label])
        let token = try XCTUnwrap(get["revision"] as? String)
        XCTAssertEqual((get["editable_configuration"] as? [String: Any])?["command"] as? String, "date")
        let invalid = try await callError(server, "update_job", ["label": label, "expected_revision": "stale",
                                                                 "changes": ["name": "Not applied"]])
        XCTAssertTrue(invalid.contains("Stale"))
        let invalidTime = try await callError(server, "update_job", ["label": label, "expected_revision": token,
                                                                     "changes": ["schedule": ["kind": "daily", "hour": true, "minute": 0]]])
        XCTAssertTrue(invalidTime.contains("integer"))
        let changed = try await call(server, "update_job", ["label": label, "expected_revision": token,
                                                            "changes": ["name": "Renamed"]])
        XCTAssertEqual(changed["updated"] as? Bool, true)
        let updated = try await call(server, "get_job", ["label": label])
        XCTAssertEqual(updated["name"] as? String, "Renamed")
        XCTAssertEqual(updated["command"] as? String, "date") // patch retained the command
        let next = try XCTUnwrap(updated["revision"] as? String)
        XCTAssertNotEqual(token, next)
        let unregistered = try await callError(server, "run_job", ["label": label, "expected_revision": next])
        XCTAssertTrue(unregistered.contains("not loaded"))
        let enabled = try await call(server, "set_job_enabled", ["label": label, "expected_revision": next, "enabled": true])
        XCTAssertEqual(enabled["enabled_requested"] as? Bool, true)
        let loaded = try await call(server, "get_job", ["label": label])
        let enabledToken = try XCTUnwrap(loaded["revision"] as? String)
        let run = try await call(server, "run_job", ["label": label, "expected_revision": enabledToken])
        XCTAssertTrue(run["run_requested"] as? Bool == true)
        let calls = await launchctl.calls()
        XCTAssertTrue(calls.contains { $0.first == "kickstart" })
        let log = try await call(server, "read_log", ["label": label, "stream": "stdout", "max_bytes": 1024])
        XCTAssertEqual(log["stream"] as? String, "stdout")
        let deletedError = try await callError(server, "delete_job", ["label": label, "expected_revision": enabledToken, "confirm_label": "wrong"])
        XCTAssertTrue(deletedError.contains("confirm_label"))
        // The fake marks the process as running after kickstart, which must block deletion.
        let runningError = try await callError(server, "delete_job", ["label": label, "expected_revision": enabledToken, "confirm_label": label])
        XCTAssertTrue(runningError.contains("running"))
    }

    func testNextRunEstimateIsNullUntilAnIntervalJobHasLoggedThenLocalISO8601() async throws {
        let home = try MCPTemporaryHome()
        let repository = JobRepository(homeDirectory: home.url, runner: InMemoryLaunchctl())
        let server = MCPProtocolServer(router: MCPToolRouter(service: repository, permissions: .init(allowWrite: true)))
        _ = try await request(server, 1, "initialize", ["protocolVersion": "2025-11-25"])
        let created = try await call(server, "create_job", ["name": "Every 10", "command": "date", "enabled": true,
                                                            "schedule": ["kind": "interval", "interval_minutes": 10]])
        let label = try XCTUnwrap(created["label"] as? String)
        let fresh = try await call(server, "get_job", ["label": label])
        XCTAssertTrue(fresh["next_run_estimate"] is NSNull)
        let lastRun = Date(timeIntervalSince1970: 1_800_000_000)
        let stdout = try XCTUnwrap(fresh["stdout_path"] as? String)
        try Data("ran\n".utf8).write(to: URL(fileURLWithPath: stdout))
        try FileManager.default.setAttributes([.modificationDate: lastRun], ofItemAtPath: stdout)
        let listed = try await call(server, "list_jobs", [:])
        let job = try XCTUnwrap((listed["jobs"] as? [[String: Any]])?.first)
        let estimate = try XCTUnwrap(job["next_run_estimate"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: estimate), lastRun.addingTimeInterval(600))
    }

    func testSuccessfulDeleteRetainsBackupAndLogs() async throws {
        let home = try MCPTemporaryHome()
        let repository = JobRepository(homeDirectory: home.url, runner: InMemoryLaunchctl())
        let server = MCPProtocolServer(router: MCPToolRouter(service: repository, permissions: .init(allowWrite: true, allowDelete: true)))
        _ = try await request(server, 1, "initialize", ["protocolVersion": "2025-11-25"])
        let created = try await call(server, "create_job", ["name": "Delete sample", "command": "date"])
        let label = try XCTUnwrap(created["label"] as? String)
        let original = try await call(server, "get_job", ["label": label])
        let revision = try XCTUnwrap(original["revision"] as? String)
        let removed = try await call(server, "delete_job", ["label": label, "expected_revision": revision, "confirm_label": label])
        XCTAssertEqual(removed["deleted"] as? Bool, true)
        let after = try await call(server, "list_jobs", [:])
        XCTAssertEqual(after["total"] as? Int, 0)
        let backupFolder = home.url.appendingPathComponent("Library/Application Support/Joblet/Backups")
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupFolder.path)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(backups[0].hasPrefix(label))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library/Application Support/Joblet/Logs/\(label)/stdout.log").path))
    }

    func testMutationRateLimitAndScheduleValidation() async throws {
        let fake = StubService()
        let router = MCPToolRouter(service: fake, permissions: .init(allowWrite: true))
        do {
            _ = try await router.call("create_job", arguments: ["name": "bad", "command": "date", "schedule": ["kind": "weekly", "hour": 9, "minute": 0, "weekday": 1, "interval_minutes": 10]])
            XCTFail("Weekly schedules must reject unrelated fields")
        } catch { XCTAssertTrue(error.localizedDescription.contains("weekly schedule")) }
        for index in 0 ..< 20 {
            let result = try await router.call("create_job", arguments: ["name": "job\(index)", "command": "date"])
            XCTAssertEqual(result["created"] as? Bool, true)
        }
        do {
            _ = try await router.call("create_job", arguments: ["name": "21", "command": "date"])
            XCTFail("Should rate-limit repeated mutations")
        } catch { XCTAssertTrue(error.localizedDescription.contains("20 operations")) }
        let creations = await fake.created()
        XCTAssertEqual(creations, 20)
    }

    func testThirdPartyJobsAreHiddenByDefaultAndNeverEditable() async throws {
        let fake = StubService()
        let external = LaunchJob(label: "org.third.party", name: "other", command: "sleep 5", scheduleDescription: "manual",
                                 schedule: nil, plistURL: URL(fileURLWithPath: "/tmp/thirdparty.plist"), workingDirectory: nil,
                                 standardOutPath: nil, standardErrorPath: nil, isManaged: false, canEdit: false, canControl: true,
                                 runtime: JobRuntime(phase: .waiting, isDisabled: false), draft: nil)
        await fake.add(external)
        let limited = MCPToolRouter(service: fake)
        let result = try await limited.call("list_jobs", arguments: [:])
        XCTAssertEqual(result["total"] as? Int, 0)
        let viewing = MCPToolRouter(service: fake, permissions: .init(allowWrite: true, allowRun: true, allowDelete: true, includeExternal: true))
        let visible = try await viewing.call("list_jobs", arguments: [:])
        XCTAssertEqual(visible["total"] as? Int, 1)
        do {
            _ = try await viewing.call("run_job", arguments: ["label": "org.third.party", "expected_revision": "anything"])
            XCTFail("External jobs should not be controllable without --allow-external-control")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Joblet-owned")) }
    }

    func testDuplicateLabelNeverSelectsAnArbitraryJob() async throws {
        let fake = StubService()
        for file in ["one", "two"] {
            await fake.add(LaunchJob(label: "local.joblet.duplicate", name: file, command: "date", scheduleDescription: "manual",
                                     schedule: nil, plistURL: URL(fileURLWithPath: "/tmp/\(file).plist"), workingDirectory: nil,
                                     standardOutPath: nil, standardErrorPath: nil, isManaged: true, canEdit: true, canControl: true,
                                     runtime: JobRuntime(phase: .waiting, isDisabled: false), draft: nil))
        }
        let router = MCPToolRouter(service: fake)
        do {
            _ = try await router.call("get_job", arguments: ["label": "local.joblet.duplicate"])
            XCTFail("Duplicate label should be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Multiple")) }
    }

    func testBatchAndNonObjectParamsAreInvalidRequests() async throws {
        let server = MCPProtocolServer(router: MCPToolRouter(service: StubService()))
        let batch = await server.handle(Data("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]".utf8))
        XCTAssertEqual(try (decode(XCTUnwrap(batch))["error"] as? [String: Any])?["code"] as? Int, -32600)
        let badParams = await server.handle(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":[1]}".utf8))
        XCTAssertEqual(try (decode(XCTUnwrap(badParams))["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknown = try await request(server, 2, "initialize", ["protocolVersion": "1999-01-01"])
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let missingMeta = try await request(server, 3, "tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]])
        XCTAssertEqual((missingMeta["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknownMethod = try await request(server, 4, "resources/list")
        XCTAssertEqual((unknownMethod["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testToolFlagsControlListing() async throws {
        func names(_ permissions: MCPPermissions) async throws -> [String] {
            let server = MCPProtocolServer(router: MCPToolRouter(service: StubService(), permissions: permissions))
            _ = try await request(server, 1, "initialize", ["protocolVersion": "2025-11-25"])
            return try await toolNames(request(server, 2, "tools/list"))
        }
        let readOnly = ["list_jobs", "get_job", "read_log"]
        let write = try await names(.init(allowWrite: true))
        XCTAssertEqual(write, readOnly + ["create_job", "update_job", "set_job_enabled", "set_job_group"])
        let run = try await names(.init(allowRun: true))
        XCTAssertEqual(run, readOnly + ["run_job"])
        let delete = try await names(.init(allowDelete: true))
        XCTAssertEqual(delete, readOnly + ["delete_job"])
        let external = try await names(.init(includeExternal: true))
        XCTAssertEqual(external, readOnly)
    }

    func testExternalControlLiftsOnlyEnableAndRun() async throws {
        let home = try MCPTemporaryHome()
        let launchctl = InMemoryLaunchctl()
        let label = "com.example.thing"
        let agents = home.url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = agents.appendingPathComponent(label + ".plist")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": ["/bin/echo", "hi"]], format: .xml, options: 0)
        try plist.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        await launchctl.register(label, path: file.path)
        await launchctl.setDisabled(false, label: label)
        let repository = JobRepository(homeDirectory: home.url, runner: launchctl)
        let all = MCPPermissions(allowWrite: true, allowRun: true, allowDelete: true, includeExternal: true, allowExternalControl: true)
        let server = MCPProtocolServer(router: MCPToolRouter(service: repository, permissions: all))
        _ = try await request(server, 1, "initialize", ["protocolVersion": "2025-11-25"])
        let get = try await call(server, "get_job", ["label": label])
        let token = try XCTUnwrap(get["revision"] as? String)
        let updateError = try await callError(server, "update_job", ["label": label, "expected_revision": token, "changes": ["name": "x"]])
        XCTAssertTrue(updateError.contains("Joblet-owned"), updateError)
        let deleteError = try await callError(server, "delete_job", ["label": label, "expected_revision": token, "confirm_label": label])
        XCTAssertTrue(deleteError.contains("Joblet-owned"), deleteError)
        let run = try await call(server, "run_job", ["label": label, "expected_revision": token])
        XCTAssertEqual(run["run_requested"] as? Bool, true)
        let hidden = MCPProtocolServer(router: MCPToolRouter(service: repository, permissions: .init(allowRun: true)))
        _ = try await request(hidden, 1, "initialize", ["protocolVersion": "2025-11-25"])
        let denied = try await callError(hidden, "run_job", ["label": label, "expected_revision": token])
        XCTAssertTrue(denied.contains("not found"), denied)
    }

    func testSetJobGroupFiltersListAndFollowsExternalRules() async throws {
        let home = try MCPTemporaryHome()
        let launchctl = InMemoryLaunchctl()
        let external = "com.example.grouped"
        let agents = home.url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = agents.appendingPathComponent(external + ".plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": external, "ProgramArguments": ["/bin/date"]], format: .xml, options: 0)
            .write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        await launchctl.register(external, path: file.path)
        let repository = JobRepository(homeDirectory: home.url, runner: launchctl)
        let server = MCPProtocolServer(router: MCPToolRouter(service: repository, permissions: .init(allowWrite: true, includeExternal: true)))
        _ = try await request(server, 1, "initialize", ["protocolVersion": "2025-11-25"])
        let created = try await call(server, "create_job", ["name": "First", "command": "date"])
        let first = try XCTUnwrap(created["label"] as? String)
        _ = try await call(server, "create_job", ["name": "Second", "command": "date"])
        let before = try await call(server, "get_job", ["label": first])

        let set = try await call(server, "set_job_group", ["label": first, "group": " Backups "])
        XCTAssertEqual(set["group"] as? String, "Backups")
        let after = try await call(server, "get_job", ["label": first])
        XCTAssertEqual(after["group"] as? String, "Backups")
        XCTAssertEqual(after["revision"] as? String, before["revision"] as? String)
        let filtered = try await call(server, "list_jobs", ["group": "Backups"])
        XCTAssertEqual(filtered["total"] as? Int, 1)
        XCTAssertEqual((filtered["jobs"] as? [[String: Any]])?.first?["label"] as? String, first)
        let all = try await call(server, "list_jobs", [:])
        XCTAssertEqual(all["total"] as? Int, 3)

        let invalid = try await callError(server, "set_job_group", ["label": first, "group": "  "])
        XCTAssertTrue(invalid.contains("group name"), invalid)
        let missing = try await callError(server, "set_job_group", ["label": first])
        XCTAssertTrue(missing.contains("group"), missing)
        let cleared = try await call(server, "set_job_group", ["label": first, "group": NSNull()])
        XCTAssertTrue(cleared["group"] is NSNull)
        let none = try await call(server, "list_jobs", ["group": "Backups"])
        XCTAssertEqual(none["total"] as? Int, 0)

        let externalDenied = try await callError(server, "set_job_group", ["label": external, "group": "Other"])
        XCTAssertTrue(externalDenied.contains("Joblet-owned"), externalDenied)
        let control = MCPProtocolServer(router: MCPToolRouter(service: repository, permissions: .init(allowWrite: true, includeExternal: true,
                                                                                                      allowExternalControl: true)))
        _ = try await request(control, 1, "initialize", ["protocolVersion": "2025-11-25"])
        _ = try await call(control, "set_job_group", ["label": external, "group": "Other"])
        let externalJob = try await call(control, "get_job", ["label": external])
        XCTAssertEqual(externalJob["group"] as? String, "Other")
        let hidden = MCPProtocolServer(router: MCPToolRouter(service: repository, permissions: .init(allowWrite: true)))
        _ = try await request(hidden, 1, "initialize", ["protocolVersion": "2025-11-25"])
        let notFound = try await callError(hidden, "set_job_group", ["label": external, "group": "Other"])
        XCTAssertTrue(notFound.contains("not found"), notFound)
    }

    // Helpers: all protocol cases use serialized JSON-RPC, not calls to internal dispatch.
    private func request(_ server: MCPProtocolServer, _ id: Any, _ method: String,
                         _ params: [String: Any] = [:]) async throws -> [String: Any]
    {
        let sent = try json(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let received = await server.handle(sent)
        return try decode(XCTUnwrap(received))
    }

    private func call(_ server: MCPProtocolServer, _ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        let response = try await request(server, UUID().uuidString, "tools/call", ["name": name, "arguments": args])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        if result["isError"] as? Bool == true {
            throw MCPToolError((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "Unknown MCP tool error")
        }
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    private func callError(_ server: MCPProtocolServer, _ name: String, _ args: [String: Any]) async throws -> String {
        let response = try await request(server, UUID().uuidString, "tools/call", ["name": name, "arguments": args])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        return (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }

    private func toolNames(_ response: [String: Any]) -> [String] {
        ((response["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor StubService: JobletService {
    private var data: [LaunchJob] = []
    private var creations = 0
    func add(_ job: LaunchJob) {
        data.append(job)
    }

    func created() -> Int {
        creations
    }

    func listJobs() async throws -> JobSnapshot {
        JobSnapshot(jobs: data, warnings: [])
    }

    func create(_: JobDraft) async throws -> String {
        creations += 1; return "mock.created"
    }

    func update(_: LaunchJob, draft _: JobDraft) async throws {}
    func setEnabled(_: LaunchJob, enabled _: Bool) async throws {}
    func runNow(_: LaunchJob) async throws {}
    func delete(_: LaunchJob) async throws {}
    func setGroup(_: LaunchJob, group _: String?) async throws {}
    func readLog(for _: LaunchJob, stream _: LogStream, maxBytes _: Int) async throws -> String {
        "test"
    }
}

private final class MCPTemporaryHome {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("JobletMCPTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
