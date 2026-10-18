import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct FileRevision: Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let permissions: UInt32
    let links: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let data: Data

    /// Optimistic-concurrency token for MCP clients; not an authentication secret.
    /// File metadata plus an FNV-1a hash of the complete bytes make stale snapshots distinguishable.
    var token: String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return [device, inode, UInt64(owner), UInt64(permissions), links,
                UInt64(bitPattern: size), UInt64(bitPattern: modifiedSeconds),
                UInt64(bitPattern: modifiedNanoseconds), hash]
            .map { String($0, radix: 16) }.joined(separator: "-")
    }

    func isSafeToMutate(uid: UInt32) -> Bool {
        owner == uid && permissions & 0o022 == 0 && links == 1
    }
}

enum JobFileIO {
    static let maximumPlistBytes = 1_048_576

    static func read(_ url: URL) throws -> FileRevision {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError("Cannot open file", url) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw posixError("Cannot read file information", url) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw JobletError("Not a regular file (symbolic links, FIFOs and devices are not supported): \(url.path)")
        }
        guard before.st_size >= 0, Int64(before.st_size) <= Int64(maximumPlistBytes) else {
            throw JobletError("Cannot read plist larger than 1 MB: \(url.path)")
        }
        let data = try handle.read(upToCount: maximumPlistBytes + 1) ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, data.count <= maximumPlistBytes,
              Int64(data.count) == Int64(after.st_size)
        else {
            throw JobletError("The file changed while reading. Refresh and try again: \(url.path)")
        }
        let original = revision(before, data: data)
        let final = revision(after, data: data)
        guard original == final else {
            throw JobletError("The file changed while reading. Refresh and try again: \(url.path)")
        }
        return final
    }

    static func verifyUnchanged(_ url: URL, expected: FileRevision) throws {
        guard try read(url) == expected else {
            throw JobletError("This plist changed after it was displayed. Aborted without overwriting. Refresh the list and try again.\n\(url.path)")
        }
    }

    static func directoryExists(_ url: URL) -> Bool {
        var value = stat()
        return lstat(url.path, &value) == 0 && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    static func validateDirectoryChain(_ directory: URL, home: URL, uid: UInt32,
                                       create: Bool, privateRoot: URL? = nil) throws
    {
        let root = home.standardizedFileURL
        let target = directory.standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw JobletError("Managed directories outside the home folder are not allowed.")
        }
        var current = root
        let suffix = target.pathComponents.dropFirst(root.pathComponents.count)
        let paths = [root] + suffix.map { part -> URL in
            current.appendPathComponent(part, isDirectory: true)
            return current
        }
        for path in paths {
            var info = stat()
            if lstat(path.path, &info) != 0 {
                guard errno == ENOENT, create, path.path != root.path else {
                    throw posixError("Cannot check folder", path)
                }
                guard mkdir(path.path, 0o700) == 0 || errno == EEXIST else {
                    throw posixError("Cannot create folder", path)
                }
                guard lstat(path.path, &info) == 0 else { throw posixError("Cannot check folder", path) }
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == uid,
                  UInt32(info.st_mode) & 0o022 == 0
            else {
                throw JobletError("Cannot safely verify folder owner, write permissions or symbolic links: \(path.path)")
            }
            if let privateRoot, path.path == privateRoot.path || path.path.hasPrefix(privateRoot.path + "/") {
                guard UInt32(info.st_mode) & 0o077 == 0 else {
                    throw JobletError("The Joblet data folder is accessible to other users. Not changing it automatically: \(path.path)")
                }
            }
        }
    }

    static func createPrivateLog(_ url: URL, uid: UInt32) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if descriptor >= 0 {
            _ = close(descriptor); return
        }
        guard errno == EEXIST else { throw posixError("Cannot create log file", url) }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == uid, UInt32(info.st_mode) & 0o077 == 0, info.st_nlink == 1
        else {
            throw JobletError("Cannot safely verify log file owner and permissions: \(url.path)")
        }
    }

    @discardableResult
    static func atomicWrite(_ data: Data, to url: URL, expecting expected: FileRevision?) throws -> FileRevision {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".joblet-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError("Cannot create temporary file", temporary) }
        var descriptorOpen = true
        defer {
            if descriptorOpen {
                _ = close(descriptor)
            }; _ = unlink(temporary.path)
        }
        try data.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = write(descriptor, address.advanced(by: written), data.count - written)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw posixError("Cannot write file", temporary) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError("Cannot save file", temporary) }
        _ = close(descriptor)
        descriptorOpen = false
        if let expected {
            // This immediate check plus an actor's mutation gate protects against stale
            // app snapshots. A backup is retained before replacing an existing plist.
            try verifyUnchanged(url, expected: expected)
            guard rename(temporary.path, url.path) == 0 else { throw posixError("Cannot replace file", url) }
        } else {
            // link is atomic and refuses an existing destination; create never overwrites.
            guard link(temporary.path, url.path) == 0 else { throw posixError("Aborted without overwriting an existing file", url) }
            _ = unlink(temporary.path)
        }
        syncDirectory(url.deletingLastPathComponent())
        return try read(url)
    }

    static func moveToBackup(_ url: URL, expected: FileRevision, backup: URL) throws {
        try verifyUnchanged(url, expected: expected)
        guard !FileManager.default.fileExists(atPath: backup.path) else {
            throw JobletError("The backup destination already exists. Delete aborted.")
        }
        guard rename(url.path, backup.path) == 0 else { throw posixError("Cannot move to backup", url) }
        do {
            guard try read(backup) == expected else { throw JobletError("The plist changed while being moved.") }
        } catch {
            // A concurrent replacement is never discarded. Restore without overwriting
            // another writer, or leave the preserved file at the reported backup path.
            if link(backup.path, url.path) == 0 {
                _ = unlink(backup.path)
                throw JobletError("The plist changed during deletion, so it was restored to its original location. Refresh the list.")
            }
            throw JobletError("The plist changed during deletion. The file is preserved at: \(backup.path)\n\(error.localizedDescription)")
        }
        syncDirectory(url.deletingLastPathComponent())
        syncDirectory(backup.deletingLastPathComponent())
    }

    static func tail(_ url: URL, maxBytes: Int) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), maxBytes > 0 else {
            throw JobletError("Specify a valid absolute log path and read size.")
        }
        let limit = min(maxBytes, 1_048_576)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return "The log has not been created yet."
            }
            throw posixError("Cannot open log", url)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw JobletError("Only regular log files can be read (links, FIFOs and devices are not supported).")
        }
        let offset = max(Int64(0), Int64(info.st_size) - Int64(limit))
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: limit) ?? Data()
        if data.isEmpty {
            return "The log is empty."
        }
        let prefix = offset > 0 ? "[Showing last \(limit) bytes]\n" : ""
        return prefix + String(decoding: data, as: UTF8.self)
    }

    private static func revision(_ info: stat, data: Data) -> FileRevision {
        #if canImport(Darwin)
            let seconds = Int64(info.st_mtimespec.tv_sec)
            let nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #else
            let seconds = Int64(info.st_mtim.tv_sec)
            let nanoseconds = Int64(info.st_mtim.tv_nsec)
        #endif
        return FileRevision(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino), owner: info.st_uid,
                            permissions: UInt32(info.st_mode) & 0o7777, links: UInt64(info.st_nlink),
                            size: Int64(info.st_size), modifiedSeconds: seconds,
                            modifiedNanoseconds: nanoseconds, data: data)
    }

    private static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        if descriptor >= 0 {
            _ = fsync(descriptor); _ = close(descriptor)
        }
    }

    private static func posixError(_ operation: String, _ url: URL) -> JobletError {
        let message = String(cString: strerror(errno))
        return JobletError("\(operation): \(url.path)\n\(message)")
    }
}
