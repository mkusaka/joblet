import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public actor JobRepository {
    private let home: URL
    private let uid: UInt32
    private let client: LaunchctlClient
    private var mutationInProgress = false

    private var agentsDirectory: URL {
        home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var dataDirectory: URL {
        home.appendingPathComponent("Library/Application Support/Joblet", isDirectory: true)
    }

    private var groupsURL: URL {
        dataDirectory.appendingPathComponent("groups.json")
    }

    private var backupsDirectory: URL {
        dataDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        uid = getuid()
        client = LaunchctlClient(runner: ProcessLaunchctl(), uid: getuid())
    }

    public init(homeDirectory: URL, runner: any LaunchctlExecuting, uid: UInt32 = getuid()) {
        home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.uid = uid
        client = LaunchctlClient(runner: runner, uid: uid)
    }

    public func listJobs() async throws -> JobSnapshot {
        guard !mutationInProgress else { throw JobletError("A job is being modified. Refresh after it finishes.") }
        if !FileManager.default.fileExists(atPath: agentsDirectory.path) {
            // A dangling directory symlink is also rejected, without creating anything.
            var info = stat()
            if lstat(agentsDirectory.path, &info) != 0, errno == ENOENT {
                return JobSnapshot(jobs: [], warnings: [])
            }
        }
        do { try validateAgentsDirectory(create: false) }
        catch { return JobSnapshot(jobs: [], warnings: [error.localizedDescription]) }
        let discovery = try discover()
        var warnings = discovery.warnings
        guard !discovery.files.isEmpty else { return JobSnapshot(jobs: [], warnings: warnings) }
        let table: DisabledTable?
        do { table = try await client.disabledTable() }
        catch { table = nil; warnings.append(error.localizedDescription) }
        if table == nil { warnings.append("Cannot read launchctl's persistent enabled/disabled settings. Actions on jobs that cannot be verified are disabled.") }
        var groups: [String: String] = [:]
        do { groups = try readGroups().groups }
        catch { warnings.append(error.localizedDescription) }
        let counts = Dictionary(grouping: discovery.files, by: { $0.document.label }).mapValues(\.count)
        var jobs: [LaunchJob] = []
        for file in discovery.files {
            let document = file.document
            var probe: RuntimeProbe
            if JobPlist.isSafeLabel(document.label), document.hasValidDisabledValue {
                do { probe = try await client.probe(label: document.label, plistDisabled: document.disabled, table: table) }
                catch { probe = RuntimeProbe(runtime: JobRuntime(detail: error.localizedDescription), loadedPath: nil) }
            } else {
                probe = RuntimeProbe(runtime: JobRuntime(detail: "Unsupported Label or Disabled format; actions are unavailable."), loadedPath: nil)
            }
            var reasons: [String] = []
            if counts[document.label] != 1 { reasons.append("Multiple plists share this Label. Changes are disabled so another job is not affected.") }
            if !file.revision.isSafeToMutate(uid: uid) { reasons.append("Cannot safely verify the plist owner, permissions or hard links.") }
            if !loadedPathMatches(probe, file: file.url) { reasons.append("The plist path registered with launchd does not match this file.") }
            let safe = reasons.isEmpty && JobPlist.isSafeLabel(document.label) && document.hasValidDisabledValue
                && probe.runtime.phase != .unknown && probe.runtime.isDisabled != nil
            if !reasons.isEmpty {
                warnings.append("\(file.url.lastPathComponent): \(reasons.joined(separator: " "))")
                probe.runtime.detail = ([probe.runtime.detail].compactMap { $0 } + reasons).joined(separator: "\n")
            }
            var draft = document.draft
            // Editing preserves the persistent setting. Registration is a separate state:
            // an enabled-but-booted-out job must not silently become persistently disabled.
            if let disabled = probe.runtime.isDisabled { draft?.enabled = !disabled }
            var job = LaunchJob(label: document.label, name: document.name, command: document.command,
                                scheduleDescription: document.scheduleDescription, schedule: document.schedule,
                                plistURL: file.url, workingDirectory: document.workingDirectory,
                                standardOutPath: document.stdout, standardErrorPath: document.stderr,
                                isManaged: document.isCanonical, canEdit: document.isCanonical && safe,
                                canControl: safe, runtime: probe.runtime, draft: draft)
            job.revision = file.revision
            job.group = groups[document.label]
            jobs.append(job)
        }
        jobs.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return JobSnapshot(jobs: jobs, warnings: warnings)
    }

    public func create(_ draft: JobDraft) async throws -> String {
        try beginMutation()
        defer { mutationInProgress = false }
        try validateDraft(draft)
        try validateAgentsDirectory(create: true)
        let label = JobPlist.labelPrefix + UUID().uuidString.lowercased()
        let url = agentsDirectory.appendingPathComponent(label + ".plist")
        let data = try JobPlist.encode(draft, label: label, home: home)
        if draft.enabled {
            let table = try await client.disabledTable()
            guard table != nil else { throw JobletError("Creation aborted because the enabled/disabled setting cannot be verified. You can still save the job as disabled.") }
            let existing = try await client.probe(label: label, plistDisabled: false, table: table)
            guard existing.runtime.phase == .unloaded else {
                throw JobletError("Cannot confirm that the new label is unloaded. Creation aborted.\n\(existing.runtime.detail ?? "")")
            }
        }
        try prepareLogs(label: label)
        let revision = try JobFileIO.atomicWrite(data, to: url, expecting: nil)
        guard draft.enabled else { return label }
        do {
            try await client.checked(["enable", target(label)])
            try JobFileIO.verifyUnchanged(url, expected: revision)
            try await client.checked(["bootstrap", client.domain, url.path])
            return label
        } catch {
            let originalError = error.localizedDescription
            let recovery = await recoverCreation(draft: draft, label: label, url: url, revision: revision)
            throw JobletError("The plist was created, but enabling it failed.\n\(originalError)\n\(recovery)\n\(url.path)")
        }
    }

    public func update(_ job: LaunchJob, draft: JobDraft) async throws {
        try beginMutation()
        defer { mutationInProgress = false }
        try validateDraft(draft)
        let context = try fileContext(job, requireEditable: true)
        let original = try await currentProbe(context)
        try requireStopped(original.runtime)
        let replacement = try JobPlist.encode(draft, label: context.document.label, home: home)
        try prepareLogs(label: context.document.label)
        let backup = try saveBackup(context)
        var written: FileRevision?
        do {
            try await unloadForChange(context)
            written = try JobFileIO.atomicWrite(replacement, to: context.url, expecting: context.revision)
            if draft.enabled {
                try await client.checked(["enable", target(context.document.label)])
                try JobFileIO.verifyUnchanged(context.url, expected: written!)
                try await client.checked(["bootstrap", client.domain, context.url.path])
            }
        } catch {
            let originalError = error.localizedDescription
            let recovery = await restore(context, runtime: original.runtime, expected: written ?? context.revision)
            throw JobletError("The update could not be completed.\n\(originalError)\n\(recovery)\nBackup before the change: \(backup.path)")
        }
    }

    public func setEnabled(_ job: LaunchJob, enabled: Bool) async throws {
        try beginMutation()
        defer { mutationInProgress = false }
        let context = try fileContext(job, requireEditable: false)
        let original = try await currentProbe(context)
        if !enabled { try requireStopped(original.runtime) }
        if enabled, original.runtime.isEnabled == true { return }
        if !enabled, original.runtime.phase == .unloaded, original.runtime.isDisabled == true { return }
        do {
            if enabled {
                try await client.checked(["enable", target(context.document.label)])
                try JobFileIO.verifyUnchanged(context.url, expected: context.revision)
                if original.runtime.phase == .unloaded {
                    try await client.checked(["bootstrap", client.domain, context.url.path])
                }
            } else { try await unloadForChange(context) }
        } catch {
            let originalError = error.localizedDescription
            let recovery = await restore(context, runtime: original.runtime, expected: context.revision)
            throw JobletError("Could not \(enabled ? "enable" : "disable") the job.\n\(originalError)\n\(recovery)")
        }
    }

    public func runNow(_ job: LaunchJob) async throws {
        try beginMutation()
        defer { mutationInProgress = false }
        let context = try fileContext(job, requireEditable: false)
        let probe = try await currentProbe(context)
        guard probe.runtime.phase != .unloaded else {
            throw JobletError("This job is not loaded in launchd. Enable it before running it.")
        }
        guard probe.runtime.isDisabled == false else { throw JobletError("This job is disabled. Enable it first.") }
        guard probe.runtime.phase != .running else { throw JobletError("The job is already running. Wait for it to finish.") }
        try JobFileIO.verifyUnchanged(context.url, expected: context.revision)
        try await client.checked(["kickstart", "-p", target(context.document.label)])
    }

    public func delete(_ job: LaunchJob) async throws {
        try beginMutation()
        defer { mutationInProgress = false }
        let context = try fileContext(job, requireEditable: true)
        let original = try await currentProbe(context)
        try requireStopped(original.runtime)
        let backup = try newBackupURL(label: context.document.label)
        do {
            try await unloadForChange(context)
            try JobFileIO.moveToBackup(context.url, expected: context.revision, backup: backup)
        } catch {
            let originalError = error.localizedDescription
            let recovery: String = if FileManager.default.fileExists(atPath: context.url.path) {
                await restore(context, runtime: original.runtime, expected: context.revision)
            } else {
                "The original file may already have been moved. Check the backup: \(backup.path)"
            }
            throw JobletError("The job could not be deleted.\n\(originalError)\n\(recovery)")
        }
        // The job is gone either way; a stale entry is pruned on the next group write.
        try? mutateGroups { $0[context.document.label] = nil }
    }

    /// Sets or clears (`nil`) the job's group. Only groups.json changes; the plist and launchd are untouched.
    public func setGroup(_ job: LaunchJob, group: String?) throws {
        try beginMutation()
        defer { mutationInProgress = false }
        let name = try group.map(JobGroup.validatedName)
        let label = try readContext(job).document.label
        try mutateGroups { $0[label] = name }
    }

    public func readLog(for job: LaunchJob, stream: LogStream, maxBytes: Int = 65536) throws -> String {
        let context = try readContext(job)
        let path = stream == .stdout ? context.document.stdout : context.document.stderr
        guard let path, !path.isEmpty else { return "This output destination is not configured." }
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw JobletError("Unsupported log destination (for example a relative path): \(path)")
        }
        return try JobFileIO.tail(URL(fileURLWithPath: path), maxBytes: maxBytes)
    }

    public func plistText(for job: LaunchJob) throws -> String {
        try JobPlist.xmlText(readContext(job).revision.data)
    }

    private func readGroups() throws -> (groups: [String: String], revision: FileRevision?) {
        var info = stat()
        if lstat(groupsURL.path, &info) != 0, errno == ENOENT { return ([:], nil) }
        try JobFileIO.validateDirectoryChain(dataDirectory, home: home, uid: uid, create: false, privateRoot: dataDirectory)
        let revision = try JobFileIO.read(groupsURL)
        guard let groups = try? JSONDecoder().decode([String: String].self, from: revision.data),
              groups.values.allSatisfy({ (try? JobGroup.validatedName($0)) == $0 })
        else {
            throw JobletError("Job groups could not be read and are not shown. Fix or remove \(groupsURL.path).")
        }
        return (groups, revision)
    }

    /// Read-modify-write that refuses to overwrite a concurrently changed or unreadable file,
    /// and drops entries whose label no longer exists.
    private func mutateGroups(_ change: (inout [String: String]) -> Void) throws {
        let current = try readGroups()
        let labels = try Set(discover().files.map(\.document.label))
        var groups = current.groups.filter { labels.contains($0.key) }
        change(&groups)
        guard groups != current.groups else { return }
        try JobFileIO.validateDirectoryChain(dataDirectory, home: home, uid: uid, create: true, privateRoot: dataDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try JobFileIO.atomicWrite(encoder.encode(groups), to: groupsURL, expecting: current.revision)
    }

    private func beginMutation() throws {
        guard !mutationInProgress else { throw JobletError("Another operation is in progress. Try again after it finishes.") }
        mutationInProgress = true
    }

    private func validateDraft(_ draft: JobDraft) throws {
        try draft.validate()
        let directory = JobPlist.normalizedWorkingDirectory(draft.workingDirectory, home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JobletError("The working directory does not exist: \(directory)")
        }
    }

    private func validateAgentsDirectory(create: Bool) throws {
        try JobFileIO.validateDirectoryChain(agentsDirectory, home: home, uid: uid, create: create)
    }

    private func prepareLogs(label: String) throws {
        let directory = JobPlist.logsDirectory(home: home, label: label)
        try JobFileIO.validateDirectoryChain(directory, home: home, uid: uid, create: true, privateRoot: dataDirectory)
        try JobFileIO.createPrivateLog(directory.appendingPathComponent("stdout.log"), uid: uid)
        try JobFileIO.createPrivateLog(directory.appendingPathComponent("stderr.log"), uid: uid)
    }

    private func target(_ label: String) -> String {
        "\(client.domain)/\(label)"
    }

    private func discover() throws -> (files: [FileContext], warnings: [String]) {
        let urls = try FileManager.default.contentsOfDirectory(at: agentsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
        var files: [FileContext] = []
        var warnings: [String] = []
        for url in urls {
            do {
                let revision = try JobFileIO.read(url)
                let document = try JobPlist.decode(revision.data, home: home)
                files.append(FileContext(url: url, revision: revision, document: document))
            } catch { warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return (files, warnings)
    }

    private func readContext(_ job: LaunchJob) throws -> FileContext {
        let url = job.plistURL.standardizedFileURL
        guard url.isFileURL, url.deletingLastPathComponent().path == agentsDirectory.path,
              url.pathExtension == "plist", let expected = job.revision
        else {
            throw JobletError("Cannot verify this job's plist. Refresh the list.")
        }
        try validateAgentsDirectory(create: false)
        let revision = try JobFileIO.read(url)
        guard revision == expected else { throw JobletError("The plist changed after it was displayed. Refresh the list.") }
        let document = try JobPlist.decode(revision.data, home: home)
        guard document.label == job.label else { throw JobletError("The plist Label has changed. Refresh the list.") }
        return FileContext(url: url, revision: revision, document: document)
    }

    private func fileContext(_ job: LaunchJob, requireEditable: Bool) throws -> FileContext {
        let context = try readContext(job)
        guard JobPlist.isSafeLabel(context.document.label), context.document.hasValidDisabledValue,
              context.revision.isSafeToMutate(uid: uid)
        else {
            throw JobletError("Cannot safely verify the Label, owner or file permissions, so the action is unavailable.")
        }
        let matches = try discover().files.filter { $0.document.label == context.document.label }
        guard matches.count == 1 else { throw JobletError("Multiple plists share this Label. Resolve the duplicates first.") }
        if requireEditable, !context.document.isCanonical {
            throw JobletError("This plist has settings that Joblet's editor cannot preserve. Only viewing and safe run control are available.")
        }
        return context
    }

    private func currentProbe(_ context: FileContext) async throws -> RuntimeProbe {
        let table = try await client.disabledTable()
        guard let table else { throw JobletError("Action aborted because the persistent enabled/disabled setting is unknown.") }
        let probe = try await client.probe(label: context.document.label, plistDisabled: context.document.disabled, table: table)
        guard probe.runtime.phase != .unknown else {
            throw JobletError("Action aborted because the job state cannot be determined.\n\(probe.runtime.detail ?? "")")
        }
        guard loadedPathMatches(probe, file: context.url) else {
            throw JobletError("The same Label is loaded from a different plist. Not acting on this file.")
        }
        try JobFileIO.verifyUnchanged(context.url, expected: context.revision)
        return probe
    }

    private func loadedPathMatches(_ probe: RuntimeProbe, file: URL) -> Bool {
        if probe.runtime.phase == .unloaded { return true }
        guard let path = probe.loadedPath, path.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == file.standardizedFileURL.path
    }

    private func requireStopped(_ runtime: JobRuntime) throws {
        guard runtime.phase != .running else {
            throw JobletError("A running job cannot be modified, disabled or deleted. Wait for it to finish. Joblet never force-kills jobs.")
        }
    }

    private func unloadForChange(_ context: FileContext) async throws {
        try JobFileIO.verifyUnchanged(context.url, expected: context.revision)
        try await client.checked(["disable", target(context.document.label)])
        // Recheck after disabling future launches, before bootout could stop a process.
        let current = try await currentProbe(context)
        try requireStopped(current.runtime)
        if current.runtime.phase == .waiting {
            try await client.checked(["bootout", target(context.document.label)])
        }
        try JobFileIO.verifyUnchanged(context.url, expected: context.revision)
    }

    private func newBackupURL(label: String) throws -> URL {
        try JobFileIO.validateDirectoryChain(backupsDirectory, home: home, uid: uid, create: true, privateRoot: dataDirectory)
        return backupsDirectory.appendingPathComponent("\(label)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).plist")
    }

    private func saveBackup(_ context: FileContext) throws -> URL {
        try JobFileIO.verifyUnchanged(context.url, expected: context.revision)
        let url = try newBackupURL(label: context.document.label)
        try JobFileIO.atomicWrite(context.revision.data, to: url, expecting: nil)
        return url
    }

    private func restore(_ context: FileContext, runtime original: JobRuntime, expected: FileRevision) async -> String {
        do {
            try validateAgentsDirectory(create: false)
            try JobFileIO.verifyUnchanged(context.url, expected: expected)
            var current = try FileContext(url: context.url, revision: expected, document: JobPlist.decode(expected.data, home: home))
            let probe = try await currentProbe(current)
            if probe.runtime.phase == .running {
                try await restoreOverride(label: context.document.label, original: original)
                return expected.data == context.revision.data
                    ? "The job started during the operation. It was not stopped; only the enabled/disabled setting was restored."
                    : "The enabled/disabled setting was restored. Because the job is now running, the plist and registration were not rolled back and the saved content was kept."
            }
            if original.phase == .waiting, probe.runtime.phase == .waiting,
               expected.data == context.revision.data
            {
                try await restoreOverride(label: context.document.label, original: original)
                return "The enabled/disabled setting was restored. The original registration was kept and the job was not re-registered."
            }
            if probe.runtime.phase == .waiting {
                try await client.checked(["disable", target(context.document.label)])
                let afterDisable = try await currentProbe(current)
                if afterDisable.runtime.phase == .running {
                    try await restoreOverride(label: context.document.label, original: original)
                    return "The job started during recovery. It was not stopped; only the enabled/disabled setting was restored. Plist recovery was aborted."
                }
                if afterDisable.runtime.phase == .waiting {
                    try await client.checked(["bootout", target(context.document.label)])
                }
            }
            if expected.data != context.revision.data {
                let restored = try JobFileIO.atomicWrite(context.revision.data, to: context.url, expecting: expected)
                current = FileContext(url: context.url, revision: restored, document: context.document)
            }
            try JobFileIO.verifyUnchanged(current.url, expected: current.revision)
            if original.phase == .waiting {
                try await client.checked(["enable", target(context.document.label)])
                try JobFileIO.verifyUnchanged(current.url, expected: current.revision)
                try await client.checked(["bootstrap", client.domain, context.url.path])
                if original.isDisabled == true { try await client.checked(["disable", target(context.document.label)]) }
            } else {
                try await restoreOverride(label: context.document.label, original: original)
            }
            return "Restored the previous settings and registration state. A job set to run when loaded may also run during recovery."
        } catch {
            return "Automatic recovery also failed. Check the current settings and registration state.\n\(error.localizedDescription)"
        }
    }

    private func restoreOverride(label: String, original: JobRuntime) async throws {
        guard let disabled = original.isDisabled else { throw JobletError("Cannot recover because the previous persistent setting is unknown.") }
        try await client.checked([disabled ? "disable" : "enable", target(label)])
    }

    private func recoverCreation(draft: JobDraft, label: String, url: URL, revision: FileRevision) async -> String {
        do {
            try JobFileIO.verifyUnchanged(url, expected: revision)
            let context = try FileContext(url: url, revision: revision, document: JobPlist.decode(revision.data, home: home))
            let probe = try await currentProbe(context)
            guard probe.runtime.phase != .running else {
                return "The job is already running, so it was not stopped and its settings were kept. Refresh the list to check the state."
            }
            try await unloadForChange(context)
            var disabled = draft
            disabled.enabled = false
            let data = try JobPlist.encode(disabled, label: label, home: home)
            try JobFileIO.atomicWrite(data, to: url, expecting: revision)
            return "The job was left disabled and not loaded. You can enable it again from the list."
        } catch {
            return "Could not confirm recovery to a safe disabled state. The settings were kept. Refresh the list.\n\(error.localizedDescription)"
        }
    }
}

private struct FileContext {
    let url: URL
    let revision: FileRevision
    let document: DecodedJobPlist
}
