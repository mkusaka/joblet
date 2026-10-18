import AppKit
import JobletCore
import SwiftUI

@MainActor
struct JobEditorView: View {
    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    let editing: LaunchJob?

    @State private var draft: JobDraft
    @State private var validationMessage: String?
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, command, directory
    }

    init(editing: LaunchJob?) {
        self.editing = editing
        var initialDraft = editing?.draft ?? JobDraft()
        if editing == nil, initialDraft.workingDirectory.isEmpty {
            initialDraft.workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        }
        _draft = State(initialValue: initialDraft)
    }

    private var currentEditing: LaunchJob? {
        guard let editing else { return nil }
        return store.jobs.first { $0.id == editing.id }
    }

    private var editingProblem: String? {
        guard let original = editing else { return nil }
        guard let job = currentEditing else {
            return "This job was not found. Close this window and refresh the list."
        }
        guard job.isManaged && job.canEdit else {
            return "The current settings cannot be edited. Close this window and review the job."
        }
        if job.runtime.phase == .running {
            return "This job is running. Changes cannot be saved until it finishes and its state is refreshed."
        }
        if !job.canControl || job.runtime.phase == .unknown {
            return "The current state cannot be verified safely, so changes cannot be saved."
        }
        if job.draft != original.draft {
            return "The settings were changed elsewhere. Close this window and edit again from the latest version."
        }
        return nil
    }

    private var selectedTime: Binding<Date> {
        Binding {
            Calendar.current.date(
                bySettingHour: draft.schedule.hour,
                minute: draft.schedule.minute,
                second: 0,
                of: Date()
            ) ?? Date()
        } set: { value in
            let components = Calendar.current.dateComponents([.hour, .minute], from: value)
            draft.schedule.hour = components.hour ?? 9
            draft.schedule.minute = components.minute ?? 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: editing == nil ? "plus.circle" : "pencil.circle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(editing == nil ? "New Job" : "Edit Job")
                        .font(.title2.weight(.semibold))
                    Text("Set the command and when it should run.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    basicFields
                    Divider()
                    scheduleFields
                    Divider()
                    activationFields
                }
                .padding(24)
            }
            .disabled(isSaving)

            Divider()

            if let problem = editingProblem {
                InlineNotice(message: problem, symbol: "exclamationmark.triangle", color: .orange)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            if let message = validationMessage ?? store.errorMessage {
                editorError(message)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    .accessibilityIdentifier("editor-cancel")
                Button(editing == nil ? "Create Job" : "Save Changes", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || store.isBusy || editingProblem != nil)
                    .accessibilityIdentifier("editor-save")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 620, height: 660)
        .interactiveDismissDisabled(isSaving)
        .onAppear { focusedField = .name }
    }

    private var basicFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Name").font(.callout.weight(.medium))
                TextField("e.g. Morning backup", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("Job name")
                    .accessibilityIdentifier("editor-name")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Command").font(.callout.weight(.medium))
                TextEditor(text: $draft.command)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .command)
                    .padding(8)
                    .frame(height: 100)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    }
                    .accessibilityLabel("zsh command to run")
                    .accessibilityIdentifier("editor-command")
                Text("Runs with /bin/zsh -c. Set any environment variables you need inside the command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Working directory").font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    TextField("/path/to/directory", text: $draft.workingDirectory)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .directory)
                        .accessibilityLabel("Absolute path of the working directory")
                        .accessibilityIdentifier("editor-workdir")
                    Button("Choose…", action: chooseDirectory)
                }
                Text("Relative paths in the command resolve against this folder. If empty, the home folder is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule").font(.callout.weight(.medium))
            Picker("Schedule", selection: $draft.schedule.kind) {
                ForEach(ScheduleKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("editor-schedule")

            switch draft.schedule.kind {
            case .interval:
                HStack(spacing: 10) {
                    Text("Repeat every")
                    Spacer()
                    TextField("Minutes", value: $draft.schedule.intervalMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .accessibilityLabel("Run interval in minutes")
                        .accessibilityIdentifier("editor-interval-minutes")
                    Text("minutes")
                        .foregroundStyle(.secondary)
                }
                Text("Runs while the Mac sleeps, or catch-up runs for elapsed intervals, are not guaranteed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .daily:
                HStack {
                    Text("Time of day")
                    Spacer()
                    timePicker
                }
            case .weekly:
                HStack {
                    Picker("Weekday", selection: $draft.schedule.weekday) {
                        ForEach(0 ..< 7) { weekday in
                            Text(Self.weekdays[weekday]).tag(weekday)
                        }
                    }
                    .frame(maxWidth: 220)
                    Spacer()
                    timePicker
                }
            case .manual:
                Text("Start the job from Run Now. No recurring schedule is set.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let estimate = draft.schedule.nextCalendarRun() {
                Label("Next run per settings (estimate): \(calendarEstimateText(estimate))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Uses this Mac's time zone. The actual start time depends on whether the Mac is awake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timePicker: some View {
        DatePicker("Run time", selection: selectedTime, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Time to run")
    }

    private var activationFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if currentEditing?.runtime.phase == .unloaded, currentEditing?.runtime.isDisabled == false {
                InlineNotice(message: "This job is not registered now, but it is set to load at login. Saving with \"Enable job\" on also registers it in this session.")
            }

            Toggle("Also run at login or when the job is loaded", isOn: $draft.runAtLoad)
                .accessibilityIdentifier("editor-run-at-load")
            if draft.runAtLoad {
                InlineNotice(
                    message: "If the job is enabled when created, saved or enabled, the command also runs at that moment.",
                    symbol: "bolt.circle",
                    color: .orange
                )
            }

            Toggle(editing == nil ? "Enable after creating" : "Enable job", isOn: $draft.enabled)
                .accessibilityIdentifier("editor-enabled")
            Text(draft.enabled
                ? "Registered as a LaunchAgent of the current user. macOS keeps running the schedule after you close the app."
                : "Only the settings are saved. The job will not run until you enable it in the list.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
    }

    private func editorError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            ScrollView {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 64)
            Button {
                validationMessage = nil
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss the error")
            .accessibilityLabel("Dismiss the error")
        }
        .padding(12)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func save() {
        guard !isSaving, !store.isBusy else { return }
        if let problem = editingProblem {
            validationMessage = problem
            return
        }
        do {
            try draft.validate()
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        validationMessage = nil
        // Preserve the snapshot from when the editor opened. The repository
        // compares its file revision before writing, so a refresh must not
        // silently turn a stale draft into a current revision.
        let jobToEdit = editing
        isSaving = true
        Task {
            let succeeded = await store.save(draft, editing: jobToEdit)
            isSaving = false
            if succeeded {
                dismiss()
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Working Directory"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let expanded = (draft.workingDirectory as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in draft.workingDirectory = url.path }
        }
    }

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
}
