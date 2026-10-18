import JobletCore
import SwiftUI

private enum DetailTab: String, CaseIterable, Identifiable {
    case settings, schedule, logs, details
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .settings: "Settings"
        case .schedule: "Schedule"
        case .logs: "Logs"
        case .details: "Details"
        }
    }
}

@MainActor
struct JobDetailView: View {
    @EnvironmentObject private var store: JobStore
    let job: LaunchJob
    let onEdit: () -> Void
    let onAction: (JobActionKind) -> Void
    @State private var tab: DetailTab = .settings
    @State private var isNamingGroup = false
    @State private var newGroupName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Picker("Section", selection: $tab) {
                    ForEach(DetailTab.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                .accessibilityIdentifier("detail-tabs")

                notices

                switch tab {
                case .settings: commandCard
                case .schedule: scheduleCard
                case .logs: JobOutputView(job: job, showsPlist: false)
                case .details:
                    runtimeCard
                    JobOutputView(job: job, showsPlist: true)
                    fileInformation
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .alert("New Group", isPresented: $isNamingGroup) {
            TextField("Group name", text: $newGroupName)
                .accessibilityIdentifier("new-group-name")
            Button("Add") { setGroup(newGroupName) }
                .accessibilityIdentifier("new-group-add")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jobs in the same group are listed together in the sidebar.")
        }
    }

    private func setGroup(_ name: String?) {
        Task { await store.setGroup(job, group: name) }
    }

    @ViewBuilder
    private var notices: some View {
        if !job.isManaged {
            InlineNotice(message: "This is an existing LaunchAgent. You will be asked to confirm actions. Editing and deleting apply only to jobs created by Joblet.")
        } else if !job.canEdit {
            InlineNotice(
                message: "This plist format cannot be edited. You can still view its contents.",
                symbol: "exclamationmark.triangle",
                color: .orange
            )
        }

        if !job.canControl {
            InlineNotice(
                message: "The job's state or settings cannot be verified safely, so run and enable actions are unavailable. Use Refresh to check again.",
                symbol: "exclamationmark.triangle",
                color: .orange
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: job.isManaged ? "terminal" : "gearshape")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(job.isManaged ? Color.accentColor : Color.secondary, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.name)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("detail-name")
                    HStack(spacing: 8) {
                        Text(job.label)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .accessibilityIdentifier("detail-label")
                        Text(job.isManaged ? "Created by Joblet" : "Existing")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(job.isManaged ? 0.15 : 0.0), in: Capsule())
                            .foregroundStyle(job.isManaged ? Color.accentColor : Color.secondary)
                    }
                    JobStatusBadge(runtime: job.runtime)
                        .accessibilityIdentifier("detail-status")
                }
                Spacer(minLength: 8)
                if let isEnabled = job.runtime.isEnabled {
                    Toggle("Enabled", isOn: Binding(
                        get: { isEnabled },
                        set: { onAction($0 ? .enable : .disable) }
                    ))
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(store.isBusy || !job.canToggle)
                    .help(job.isRunning ? "A running job is not stopped. You can change this after it finishes." : "Change whether the job is registered and enabled")
                    .accessibilityIdentifier("detail-toggle")
                } else {
                    Text("Enabled state unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("Run Now", systemImage: "play.fill") { onAction(.run) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || !job.canRunNow)
                    .help(runHelp)
                    .accessibilityIdentifier("run-now-button")

                if job.isManaged {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                        .disabled(store.isBusy || !job.canEditNow)
                        .help(job.isRunning ? "You can edit after the run finishes" : "Edit this job")
                        .accessibilityIdentifier("edit-button")
                }

                Button("Show Plist", systemImage: "doc.plaintext") { tab = .details }
                    .accessibilityIdentifier("show-plist-button")

                groupMenu

                Menu {
                    Button("Copy Label", systemImage: "doc.on.doc") {
                        copyJobletText(job.label)
                    }
                    Button("Reveal Plist in Finder", systemImage: "folder") {
                        store.reveal(job.plistURL)
                    }
                    Button("Open Logs Folder", systemImage: "doc.text.magnifyingglass") {
                        store.openLogsFolder(for: job)
                    }
                    .disabled(job.standardOutPath == nil && job.standardErrorPath == nil)

                    if job.isManaged {
                        Divider()
                        Button("Delete Job…", role: .destructive) { onAction(.delete) }
                            .disabled(store.isBusy || !job.canEditNow)
                            .accessibilityIdentifier("delete-job-menu-item")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20)
                }
                .menuIndicator(.hidden)
                .help("More actions")
                .accessibilityLabel("More actions")
                .accessibilityIdentifier("more-actions-menu")

                Spacer(minLength: 0)
            }
        }
    }

    private var groupMenu: some View {
        Menu {
            ForEach(store.groupNames, id: \.self) { name in
                Button {
                    setGroup(name)
                } label: {
                    if job.group == name {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if !store.groupNames.isEmpty {
                Divider()
            }
            Button("New Group…") {
                newGroupName = ""
                isNamingGroup = true
            }
            .accessibilityIdentifier("new-group-menu-item")
            if job.group != nil {
                Button("Remove from Group") { setGroup(nil) }
                    .accessibilityIdentifier("remove-group-menu-item")
            }
        } label: {
            Label(job.group ?? "Add to Group", systemImage: "folder")
        }
        .fixedSize()
        .disabled(store.isBusy)
        .help("Group this job in the sidebar")
        .accessibilityIdentifier("group-menu")
    }

    private var runHelp: String {
        if job.isRunning {
            return "This job is running"
        }
        if job.runtime.phase == .unloaded || job.runtime.isEnabled == false {
            return "Enable the job before running it"
        }
        if !job.canControl {
            return "Cannot run until the state can be verified"
        }
        return "Run the registered command once"
    }

    private var scheduleCard: some View {
        JobletCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("Schedule", systemImage: "calendar.badge.clock")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(job.scheduleDescription)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("detail-schedule")
            }

            if job.runtime.phase == .unloaded, job.runtime.isDisabled == false {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The job is not registered now, but it is set to load at the next login. Use the switch to register it in this session too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Keep Disabled After Next Login") { onAction(.disable) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(store.isBusy || !job.canControl)
                }
            }

            if let schedule = job.schedule,
               let nextDate = schedule.nextCalendarRun()
            {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                    Text("Next run per settings (estimate): \(calendarEstimateText(nextDate))")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text("Based on this Mac's time zone. The actual start depends on the enabled state and whether the Mac is awake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if job.schedule?.kind == .interval {
                Text("The next run of an interval job is not shown. Time elapsed during sleep is not guaranteed to run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if job.draft?.runAtLoad == true {
                Label("Also runs at login or when the job is loaded", systemImage: "power")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if job.isRunning {
                Text("Once the run finishes you can edit, disable or delete the job.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runtimeCard: some View {
        JobletCard {
            Label("Run State", systemImage: "waveform.path.ecg")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Status") { Text(job.runtime.phase.title) }
                if let pid = job.runtime.pid {
                    LabeledContent("Process ID") {
                        Text(String(pid)).monospacedDigit().textSelection(.enabled)
                    }
                }
                if let exitCode = job.runtime.lastExitCode {
                    LabeledContent("Exit code (as reported by launchd)") {
                        Text(String(exitCode)).monospacedDigit().textSelection(.enabled)
                    }
                    Text("launchd may report 0 before the first run. This value alone does not show whether or when the job ran.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            if let detail = job.runtime.detail, !detail.isEmpty {
                DisclosureGroup("State details") {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var commandCard: some View {
        JobletCard {
            HStack {
                Label("Command", systemImage: "terminal")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    copyJobletText(job.command)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(job.command.isEmpty)
                .help("Copy the command")
            }

            Text(job.command.isEmpty ? "The command could not be read." : job.command)
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityIdentifier("detail-command")

            if let directory = job.workingDirectory, !directory.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "folder")
                    Text(directory)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
                .help("Working directory")
            }
        }
    }

    private var fileInformation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Plist file")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("Reveal in Finder") { store.reveal(job.plistURL) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Text(job.plistURL.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Showing a LaunchAgent of the current user.")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}

/// Shows either the job's logs (stdout/stderr) or its plist.
@MainActor
private struct JobOutputView: View {
    @EnvironmentObject private var store: JobStore
    let job: LaunchJob
    let showsPlist: Bool
    @State private var stream: LogStream = .stdout
    @State private var text = ""
    @State private var isLoading = false
    @State private var revision = 0

    private struct LoadRequest: Equatable {
        let jobID: String
        let stream: LogStream
        let revision: Int
    }

    private var request: LoadRequest {
        LoadRequest(jobID: job.id, stream: stream, revision: revision)
    }

    private var logPath: String? {
        stream == .stdout ? job.standardOutPath : job.standardErrorPath
    }

    var body: some View {
        JobletCard {
            HStack(spacing: 12) {
                Label(showsPlist ? "Plist" : "Logs", systemImage: showsPlist ? "doc.plaintext" : "text.alignleft")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    revision += 1
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(store.isBusy || isLoading)
                .help("Reload")
                Button {
                    copyJobletText(text)
                } label: {
                    Label(showsPlist ? "Copy Plist" : "Copy", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(text.isEmpty || isLoading)
                .help(showsPlist ? "Copy the plist" : "Copy the log")
                .accessibilityIdentifier("copy-output-button")
            }

            if !showsPlist {
                HStack {
                    Picker("Log stream", selection: $stream) {
                        ForEach(LogStream.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button("Open Folder", systemImage: "folder") {
                        store.openLogsFolder(for: job)
                    }
                    .buttonStyle(.borderless)
                    .disabled(job.standardOutPath == nil && job.standardErrorPath == nil)
                }
                .font(.caption)
            }

            ScrollView([.horizontal, .vertical]) {
                Text(text.isEmpty ? (isLoading ? "Loading…" : "Nothing to show.") : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                    .accessibilityIdentifier("output-text")
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))

            if !showsPlist {
                Text("Shows up to the last 64 KiB of the file. Reload to see new output.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let logPath {
                    Text(logPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("This output destination is not configured.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: request) {
            isLoading = true
            let result: String = if showsPlist {
                await store.plist(for: job)
            } else {
                await store.log(for: job, stream: stream)
            }
            guard !Task.isCancelled else { return }
            text = result
            isLoading = false
        }
    }
}
