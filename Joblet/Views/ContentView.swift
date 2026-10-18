import JobletCore
import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var store: JobStore
    @State private var searchText = ""
    @State private var filter: JobFilter = .all
    @State private var editor: EditorPresentation?
    @State private var pendingAction: PendingJobAction?

    private struct EditorPresentation: Identifiable {
        let id = UUID()
        let job: LaunchJob?
    }

    private var visibleJobs: [LaunchJob] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.jobs.filter { job in
            filter.includes(job) && (query.isEmpty ||
                job.name.localizedCaseInsensitiveContains(query) ||
                job.label.localizedCaseInsensitiveContains(query) ||
                job.command.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 225, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if !store.warnings.isEmpty {
                    DiscoveryWarningsView(warnings: store.warnings)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                }

                if let job = store.selectedJob {
                    JobDetailView(
                        job: job,
                        onEdit: { showEditor(for: job) },
                        onAction: { request($0, for: job) }
                    )
                    .id(job.id)
                } else {
                    emptyDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Joblet")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy || store.isRefreshing)
                .help("Reload LaunchAgents and run states (⌘R)")
                .accessibilityIdentifier("refresh-button")
            }
        }
        .sheet(item: $editor) { presentation in
            JobEditorView(editing: presentation.job)
                .environmentObject(store)
        }
        .confirmationDialog(
            Text(pendingAction?.title ?? "Confirm Action"),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action.buttonTitle, role: action.isDestructive ? .destructive : nil) {
                perform(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .alert(
            "The operation could not be completed",
            isPresented: Binding(
                get: { editor == nil && store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("Close", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onChange(of: filter) { _, _ in keepSelectionVisible() }
        .onChange(of: searchText) { _, _ in keepSelectionVisible() }
        .onChange(of: store.jobs.map(\.id)) { _, _ in keepSelectionVisible() }
        .onChange(of: store.selectedID) { _, selectedID in
            // A selection from the menu bar must also be visible in the list.
            if let selectedID,
               store.jobs.contains(where: { $0.id == selectedID }),
               !visibleJobs.contains(where: { $0.id == selectedID })
            {
                filter = .all
                searchText = ""
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Joblet")
                            .font(.title2.weight(.semibold))
                        Text("Scheduled jobs for your Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(spacing: 2) {
                    ForEach(JobFilter.allCases) { value in
                        filterRow(value)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            List(selection: $store.selectedID) {
                ForEach(visibleJobs) { job in
                    JobListRow(job: job) { enabled in
                        request(enabled ? .enable : .disable, for: job)
                    }
                    .tag(job.id)
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("job-list")
            .overlay {
                if visibleJobs.isEmpty, !store.isBusy, !store.isRefreshing {
                    VStack(spacing: 8) {
                        Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                            .font(.title2)
                        Text(searchText.isEmpty ? "No jobs" : "No matching jobs")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                    .allowsHitTesting(false)
                }
            }
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search jobs")

            Divider()
            Button {
                showEditor(for: nil)
            } label: {
                Label("Add Job", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(store.isBusy)
            .keyboardShortcut("n", modifiers: .command)
            .help("Create a new job (⌘N)")
            .accessibilityIdentifier("add-job-button")
            .padding(.horizontal, 14)
            .padding(.top, 10)
            HStack(spacing: 6) {
                if store.isBusy || store.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("Working…")
                } else if let refreshed = store.lastRefreshed {
                    Image(systemName: "arrow.clockwise")
                    Text("Checked \(refreshed.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("User LaunchAgents")
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func filterRow(_ value: JobFilter) -> some View {
        Button {
            filter = value
        } label: {
            HStack(spacing: 8) {
                Image(systemName: value.symbol).frame(width: 18)
                Text(value.title)
                Spacer()
                Text("\(store.jobs.filter(value.includes).count)")
                    .font(.caption.monospacedDigit())
                    .opacity(0.8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(filter == value ? Color.white : Color.primary)
            .background(filter == value ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter-\(value.rawValue)")
        .accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    @ViewBuilder
    private var emptyDetail: some View {
        if store.isBusy || store.isRefreshing, store.jobs.isEmpty {
            ProgressView("Loading jobs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.jobs.isEmpty {
            ContentUnavailableView {
                Label("Small jobs, on your schedule.", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Register a command and when it should run.\nmacOS keeps running the schedule after you close the app.")
            } actions: {
                Button("Create Your First Job", systemImage: "plus") {
                    showEditor(for: nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
                .accessibilityIdentifier("empty-add-job-button")
            }
        } else {
            ContentUnavailableView {
                Label("Select a Job", systemImage: "sidebar.left")
            } description: {
                Text("Choose a job in the sidebar to see\nits schedule, command and logs.")
            }
        }
    }

    private func keepSelectionVisible() {
        guard !visibleJobs.contains(where: { $0.id == store.selectedID }) else { return }
        store.selectedID = visibleJobs.first?.id
    }

    private func showEditor(for job: LaunchJob?) {
        // Keep the saved job visible even if its name changes or a new job is
        // created while the sidebar is filtered to external LaunchAgents.
        filter = .all
        searchText = ""
        editor = EditorPresentation(job: job)
    }

    private func request(_ kind: JobActionKind, for job: LaunchJob) {
        let action = PendingJobAction(kind: kind, job: job)
        if action.requiresConfirmation {
            pendingAction = action
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingJobAction) {
        Task {
            switch action.kind {
            case .run: await store.runNow(action.job)
            case .enable: await store.setEnabled(action.job, enabled: true)
            case .disable: await store.setEnabled(action.job, enabled: false)
            case .delete: _ = await store.delete(action.job)
            }
        }
    }
}
