import SwiftUI

/// The new-agent sheet (#12, User Story 8): pick a Host and a launch target
/// (an existing Workspace or a new one at a remote directory), type an
/// installed Agent and its native arguments, and dispatch it through the
/// Transport launch flow. On success the sheet dismisses and hands the
/// started Agent's identity to `onStarted`; the owner opens it, so a fresh
/// launch lands in its terminal instead of back on the list.
struct StartAgentView: View {
    @State private var store: StartAgentStore
    @State private var directoryBrowser: RemoteDirectoryBrowser?
    private let onStarted: (ConsoleAgent.ID) -> Void
    private let console: ConsoleStore
    @Environment(\.dismiss) private var dismiss

    init(
        hosts: [Host], console: ConsoleStore,
        origin: StartAgentStore.LaunchOrigin? = nil,
        onStarted: @escaping (ConsoleAgent.ID) -> Void
    ) {
        self.onStarted = onStarted
        self.console = console
        _store = State(
            initialValue: StartAgentStore(
                hosts: hosts,
                workspaces: { console.workspaces(for: $0) },
                existingAgentNames: { hostID in
                    Set(
                        console.agents
                            .filter { $0.hostID == hostID }
                            .compactMap { $0.agent.name })
                },
                discoverAgentKinds: { try await console.availableAgentKinds(on: $0) },
                start: { params, destination, hostID in
                    switch destination {
                    case .existingWorkspace:
                        try await console.startAgent(params, on: hostID)
                    case .newWorktree(let worktree):
                        try await console.startAgentInNewWorktree(
                            params, worktree: worktree, on: hostID)
                    case .newWorkspace(let workspace):
                        try await console.startAgentInNewWorkspace(
                            params, workspace: workspace, on: hostID)
                    }
                },
                awaitAgentVisible: { await console.waitForAgent($0) },
                origin: origin))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let origin = store.origin {
                    Section {
                        Text(origin.cwd)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } header: {
                        Text("Directory")
                    } footer: {
                        Text("The Agent starts in a new tab here, next to the one you opened this from.")
                    }
                } else {
                    Section("Host") {
                        Picker("Host", selection: $store.selectedHostID) {
                            if store.selectedHostID == nil {
                                Text("Select a Host").tag(Host.ID?.none)
                            }
                            ForEach(store.hosts) { host in
                                Text(host.displayName).tag(Host.ID?.some(host.id))
                            }
                        }
                    }

                    Section("Workspace") {
                        StartWorkspacePicker(
                            workspaces: store.workspaces,
                            selectedWorkspaceID: store.launchTarget == .existingWorkspace
                                ? store.selectedWorkspaceID : nil,
                            newDirectory: store.launchTarget == .newWorkspace
                                ? store.newWorkspaceDirectory : nil,
                            canBrowse: store.selectedHostID != nil,
                            onSelect: store.selectExistingWorkspace,
                            onNewWorkspace: openDirectoryBrowser)
                    }
                }

                if store.offersWorktree {
                    Section {
                        Toggle("Start in a new worktree", isOn: $store.startsInNewWorktree)
                            .disabled(store.selectedWorkspaceID == nil)
                        if store.startsInNewWorktree {
                            TextField("Branch (optional)", text: $store.worktreeBranch)
                                .font(.callout.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            TextField("Base (optional)", text: $store.worktreeBase)
                                .font(.callout.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    } header: {
                        Text("Worktree")
                    } footer: {
                        if let message = store.worktreeBranchErrorMessage {
                            Text(message)
                                .foregroundStyle(.red)
                        } else if store.startsInNewWorktree {
                            Text(
                                "A fresh checkout of the workspace's repository. Empty fields use a generated worktree/ branch off HEAD."
                            )
                        } else {
                            Text(
                                "Run the agent in a clean checkout instead of the workspace itself."
                            )
                        }
                    }
                }

                Section {
                    switch store.agentDiscoveryState {
                    case .idle:
                        Text("Select a Host to detect installed Agents.")
                            .foregroundStyle(.secondary)
                    case .loading:
                        HStack {
                            ProgressView()
                            Text("Detecting installed Agents…")
                        }
                    case .loaded where store.availableAgentKinds.isEmpty:
                        ContentUnavailableView(
                            "No Agents Found",
                            systemImage: "magnifyingglass",
                            description: Text(
                                "Install a supported Agent CLI on this Host, then try again."))
                        Button("Detect Again", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    case .loaded:
                        Picker("Agent", selection: $store.selectedAgentKind) {
                            ForEach(store.availableAgentKinds) { kind in
                                Text("\(kind.displayName) (\(kind.executable))")
                                    .tag(SupportedAgentKind?.some(kind))
                            }
                        }
                        Button("Detect Again", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Retry", systemImage: "arrow.clockwise") {
                            Task { await store.discoverAgents() }
                        }
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Agents installed and launchable from this Host's PATH.")
                }

                Section {
                    TextField(store.defaultAgentName ?? "e.g. reviewer", text: $store.name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Agent Name")
                } footer: {
                    if let message = store.nameErrorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    } else if let defaultName = store.defaultAgentName {
                        Text("Optional. Empty names the agent \(Text(defaultName).monospaced()).")
                    } else {
                        Text("Optional. Empty names the agent after its kind.")
                    }
                }

                Section {
                    AgentArgumentsField(
                        text: $store.arguments,
                        placeholder: #"e.g. --model "gpt 5" --continue"#)
                } header: {
                    Text("Arguments")
                } footer: {
                    if let message = store.argumentErrorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                    } else {
                        Text("Optional. Quotes and backslash escapes are supported.")
                    }
                }

                if case .failed(let message) = store.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(!store.canDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.state == .starting {
                        ProgressView()
                    } else {
                        Button("Start") {
                            Task { await store.submit() }
                        }
                        .disabled(!store.canSubmit)
                    }
                }
            }
            .onChange(of: store.state) {
                if case .started(let id) = store.state {
                    dismiss()
                    onStarted(id)
                }
            }
            .task(id: store.selectedHostID) {
                await store.discoverAgents()
            }
            // The presented item also supplies the content, so the first
            // presentation cannot capture an empty browser from an older view.
            .sheet(item: $directoryBrowser) { browser in
                RemoteDirectoryBrowserView(browser: browser) { path in
                    store.applyBrowsedDirectory(path)
                    directoryBrowser = nil
                }
            }
            .interactiveDismissDisabled(!store.canDismiss)
        }
    }

    private func openDirectoryBrowser() {
        guard let hostID = store.selectedHostID else { return }
        directoryBrowser = RemoteDirectoryBrowser(
            resolveHome: { try await console.remoteHomeDirectory(on: hostID) },
            list: { try await console.listRemoteDirectories(at: $0, on: hostID) })
    }
}

/// Selects an existing Workspace through the native menu, with creation below.
/// A directory pick remains a draft until the user taps Start.
struct StartWorkspacePicker: View {
    let workspaces: [ConsoleWorkspace]
    let selectedWorkspaceID: String?
    let newDirectory: String?
    let canBrowse: Bool
    let onSelect: (String) -> Void
    let onNewWorkspace: () -> Void

    var body: some View {
        Group {
            Picker("Workspace", selection: Binding<String?>(
                get: { selectedWorkspaceID },
                set: { if let id = $0 { onSelect(id) } }
            )) {
                if selectedWorkspaceID == nil {
                    Text(workspaces.isEmpty ? "None reported" : "Select a Workspace")
                        .tag(String?.none)
                }
                ForEach(workspaces) { workspace in
                    Text(workspace.label).tag(String?.some(workspace.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(!canBrowse || workspaces.isEmpty)
            .accessibilityIdentifier("start-workspace-picker")

            if let newDirectory {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New Workspace")
                        Text(newDirectory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("new-workspace-directory")
            }

            Button(action: onNewWorkspace) {
                Label("New Workspace", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(!canBrowse)
            .accessibilityIdentifier("new-workspace")
        }
    }
}
