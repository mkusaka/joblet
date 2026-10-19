import AppKit
import JobletCore
import SwiftUI

enum JobFilter: String, CaseIterable, Identifiable {
    case all, managed, external

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "All"
        case .managed: "Created by Joblet"
        case .external: "Existing"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .managed: "terminal"
        case .external: "gearshape"
        }
    }

    func includes(_ job: LaunchJob) -> Bool {
        switch self {
        case .all: true
        case .managed: job.isManaged
        case .external: !job.isManaged
        }
    }
}

extension LaunchJob {
    var isRunning: Bool {
        runtime.phase == .running
    }

    var canEditNow: Bool {
        isManaged && canEdit && canControl && !isRunning
    }

    var canRunNow: Bool {
        canControl && runtime.isEnabled == true && runtime.phase == .waiting
    }

    var canToggle: Bool {
        canControl && runtime.isEnabled != nil && !isRunning
    }
}

struct JobStatusBadge: View {
    let job: LaunchJob

    private var runtime: JobRuntime {
        job.runtime
    }

    private var color: Color {
        if job.isOnceDone {
            return .secondary
        }
        return switch runtime.phase {
        case .running: .green
        case .waiting: runtime.isDisabled == true ? .secondary : .accentColor
        case .unloaded: .secondary
        case .unknown: .orange
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(job.isOnceDone ? "Done" : runtime.phase.title)
                .font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct JobListRow: View {
    @EnvironmentObject private var store: JobStore
    let job: LaunchJob
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.isManaged ? "terminal" : "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(job.isManaged ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(job.name)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                    .accessibilityIdentifier("job-row-name")
                Text(job.scheduleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                JobStatusBadge(job: job)
                    .accessibilityIdentifier("job-row-status")
            }
            Spacer(minLength: 0)
            if let isEnabled = job.runtime.isEnabled {
                Toggle("Enabled", isOn: Binding(get: { isEnabled }, set: onToggle))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(store.isBusy || !job.canToggle)
                    .accessibilityIdentifier("job-row-toggle")
            }
        }
        .padding(.vertical, 7)
        .help(job.label)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("job-row")
    }
}

struct JobletCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        }
    }
}

struct InlineNotice: View {
    let message: String
    var symbol = "info.circle"
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DiscoveryWarningsView: View {
    let warnings: [String]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(warnings.indices, id: \.self) { index in
                        Text(warnings[index])
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 150)
            .padding(.top, 8)
        } label: {
            Label("Items needing attention: \(warnings.count)", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
        .padding(12)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum JobActionKind: Equatable {
    case run, enable, disable, delete
}

struct PendingJobAction: Identifiable {
    let id = UUID()
    let kind: JobActionKind
    let job: LaunchJob

    var requiresConfirmation: Bool {
        switch kind {
        case .delete: true
        case .enable: !job.isManaged || job.draft?.runAtLoad == true
        case .run, .disable: !job.isManaged
        }
    }

    var title: String {
        switch kind {
        case .run: "Run this job now?"
        case .enable: "Enable this job?"
        case .disable: "Disable this job?"
        case .delete: "Delete this job?"
        }
    }

    var buttonTitle: String {
        switch kind {
        case .run: "Run"
        case .enable: "Enable"
        case .disable: "Disable"
        case .delete: "Delete"
        }
    }

    var message: String {
        let identity = "\(job.name)\n\(job.label)"
        switch kind {
        case .run:
            return "\(identity)\n\nThis runs the command defined by this existing LaunchAgent."
        case .enable:
            return "\(identity)\n\nThis registers and enables the job. Depending on settings such as RunAtLoad, the command may run immediately."
        case .disable:
            return "\(identity)\n\nThis unregisters the job and keeps it disabled after the next login. It may affect the background features of the app that owns it."
        case .delete:
            return "\(identity)\n\nThis unregisters the job and deletes its plist. Logs and backups are kept."
        }
    }

    var isDestructive: Bool {
        kind == .delete
    }
}

@MainActor
func copyJobletText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func calendarEstimateText(_ date: Date) -> String {
    date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).weekday(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

/// An estimate that has already passed (for example, delayed by sleep) is shown as due, never as a past time.
func runEstimateText(_ date: Date) -> String {
    date <= Date() ? "due now" : calendarEstimateText(date)
}
