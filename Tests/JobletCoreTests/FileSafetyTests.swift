import Foundation
@testable import JobletCore
import XCTest
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class FileSafetyTests: XCTestCase {
    func testAtomicCreateDoesNotOverwriteAndUsesPrivatePermissions() throws {
        let home = try TemporaryHome()
        let file = home.url.appendingPathComponent("sample.plist")
        let revision = try JobFileIO.atomicWrite(Data("original".utf8), to: file, expecting: nil)
        XCTAssertEqual(revision.permissions, 0o600)
        XCTAssertThrowsError(try JobFileIO.atomicWrite(Data("replacement".utf8), to: file, expecting: nil))
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testStaleRevisionCannotReplaceOrDeleteNewerData() throws {
        let home = try TemporaryHome()
        let file = home.url.appendingPathComponent("sample.plist")
        let first = try JobFileIO.atomicWrite(Data("first".utf8), to: file, expecting: nil)
        try JobFileIO.atomicWrite(Data("second".utf8), to: file, expecting: first)
        XCTAssertThrowsError(try JobFileIO.atomicWrite(Data("stale".utf8), to: file, expecting: first))
        XCTAssertThrowsError(try JobFileIO.moveToBackup(file, expected: first, backup: home.url.appendingPathComponent("backup.plist")))
        XCTAssertEqual(try Data(contentsOf: file), Data("second".utf8))
    }

    func testLogTailIsBoundedAndReadsTheEnd() throws {
        let home = try TemporaryHome()
        let file = home.url.appendingPathComponent("output.log")
        try Data((String(repeating: "a", count: 100_000) + "THE-END").utf8).write(to: file)
        let text = try JobFileIO.tail(file, maxBytes: 32)
        XCTAssertTrue(text.hasSuffix("THE-END"))
        XCTAssertLessThan(text.utf8.count, 128)
        XCTAssertThrowsError(try JobFileIO.tail(file, maxBytes: 0))
    }

    func testLinksFIFOsAndDevicesCannotBeReadAsLogs() throws {
        let home = try TemporaryHome()
        let file = home.url.appendingPathComponent("real.log")
        try Data("safe".utf8).write(to: file)
        let symlink = home.url.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        XCTAssertThrowsError(try JobFileIO.tail(symlink, maxBytes: 100))
        XCTAssertThrowsError(try JobFileIO.read(symlink))
        let fifo = home.url.appendingPathComponent("fifo.log")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try JobFileIO.tail(fifo, maxBytes: 100))
        XCTAssertThrowsError(try JobFileIO.tail(URL(fileURLWithPath: "/dev/null"), maxBytes: 100))
    }

    func testDirectorySymlinkIsRejectedWithoutChangingItsTarget() throws {
        let home = try TemporaryHome()
        let destination = home.url.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let symlink = home.url.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
        XCTAssertThrowsError(try JobFileIO.validateDirectoryChain(home.agents, home: home.url, uid: getuid(), create: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("LaunchAgents").path))
    }
}
