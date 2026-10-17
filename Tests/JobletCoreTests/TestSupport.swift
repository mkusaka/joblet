import Foundation
@testable import JobletCore
import XCTest
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class TemporaryHome {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("JobletTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: url) }
    var agents: URL {
        url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    @discardableResult
    func writePlist(_ dictionary: [String: Any], name: String) throws -> URL {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = agents.appendingPathComponent(name)
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try JobFileIO.atomicWrite(data, to: path, expecting: nil)
        return path
    }
}

func assertAsyncThrows(_ body: () async throws -> some Any,
                       file: StaticString = #filePath, line: UInt = #line) async
{
    do {
        _ = try await body()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
