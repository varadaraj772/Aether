import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    ZStack {
      WindowConfigurator(appMode: appState.appMode, isDark: appState.isDark)

      Group {
        switch appState.appMode {
        case .launcher:
          LauncherView()
            .containerBackground(.clear, for: .window)
        case .workspace:
          WorkspaceView()
        }
      }
    }
    .background(Color.clear)
    .alert(
      "Error",
      isPresented: Binding(
        get: { appState.backendError != nil },
        set: { if !$0 { appState.backendError = nil } }
      )
    ) {
      Button("Retry") {
        appState.backendError = nil
        Task { await appState.recoverBackend() }
      }
      Button("OK", role: .cancel) { appState.backendError = nil }
    } message: {
      Text(appState.backendError ?? "")
    }
    .onAppear {
      Task { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        appState.bootstrap()
        if appState.appMode == .launcher {
          appState.prepareLauncherWindow()
          appState.requestSearchFocus()
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      appState.shutdown()
    }
    .onReceive(NotificationCenter.default.publisher(for: .aetherBackendTerminated)) { _ in
      Task { await appState.recoverBackend() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      Task { @MainActor in appState.updateTheme() }
    }
    .sheet(isPresented: $appState.showPrivacySheet) {
      PrivacyView()
    }
    .sheet(isPresented: $appState.showDuplicateSheet) {
      DuplicatesView()
        .environmentObject(appState)
    }
    .sheet(isPresented: $appState.showOnboarding) {
      OnboardingView()
        .environmentObject(appState)
    }
  }
}

struct WorkspaceView: View {
  @EnvironmentObject private var appState: AppState
  @FocusState private var searchFocused: Bool
  @State private var isDropTargeted = false

  var body: some View {
    VStack(spacing: 10) {
      topBar

      HSplitView {
        FoldersPanelView()
          .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

        ResultsPanelView()
          .frame(minWidth: 340, idealWidth: 440)

        PreviewPanelView()
          .frame(minWidth: 300, idealWidth: 380)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 14)
      .folderDropTarget(isTargeted: $isDropTargeted)

      statusLine
    }
    .padding(.top, 6)
    .background(appState.colors.backdrop)
    .onKeyPress(.escape) {
      Task { @MainActor in
        if appState.isQuickLookOpen {
          appState.closeQuickLook()
        } else {
          appState.openLauncher()
        }
      }
      return .handled
    }
    .onKeyPress(.upArrow) {
      Task { @MainActor in
        searchFocused = false
        appState.moveLauncherSelection(delta: -1)
      }
      return .handled
    }
    .onKeyPress(.downArrow) {
      Task { @MainActor in
        searchFocused = false
        appState.moveLauncherSelection(delta: 1)
      }
      return .handled
    }
    .onKeyPress(.space) {
      guard !searchFocused, appState.selectedResult != nil else { return .ignored }
      appState.toggleQuickLookForSelectedResult()
      return .handled
    }
    .onAppear { focusWorkspaceSearch() }
    .onChange(of: appState.searchReady) { _, _ in
      focusWorkspaceSearch()
    }
  }

  private func focusWorkspaceSearch() {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(50))
      searchFocused = true
    }
  }

  private var searchPlaceholder: String {
    if appState.isStartingBackend || !appState.backendReady {
      return appState.statusMessage.hasPrefix("Starting")
        || appState.statusMessage.hasPrefix("Restarting")
        || appState.statusMessage.hasPrefix("Downloading")
        || appState.statusMessage.hasPrefix("Loading")
        ? appState.statusMessage
        : "Starting backend…"
    }
    if !appState.searchReady {
      return appState.statusMessage.hasPrefix("Downloading")
        || appState.statusMessage.hasPrefix("Loading")
        || appState.statusMessage.hasPrefix("Search model")
        ? appState.statusMessage
        : "Loading search model…"
    }
    if appState.searchScopeSelectedFolder, let folder = appState.selectedFolder {
      return "Search in \(appState.folderStore.displayName(for: folder))…"
    }
    return "Search indexed folders…"
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      Button {
        appState.openLauncher()
      } label: {
        Label("Launcher", systemImage: "chevron.left")
          .font(.system(size: 12, weight: .medium))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.primary.opacity(0.06), in: Capsule())
      }
      .buttonStyle(.plain)
      .help("Back to compact search · esc")

      AetherSearchField(
        text: $appState.searchQuery,
        placeholder: searchPlaceholder,
        focused: $searchFocused,
        style: .workspace
      )
      .help("Search across all indexed folders · ⌘⇧Space to toggle window")

      if appState.selectedFolder != nil {
        let scoped = appState.searchScopeSelectedFolder
        let folderName = appState.selectedFolder.map { appState.folderStore.displayName(for: $0) } ?? "folder"
        Button {
          appState.toggleSearchScopeSelectedFolder()
        } label: {
          Label(
            scoped ? "This Folder" : "All Folders",
            systemImage: scoped ? "folder.fill" : "folder"
          )
          .font(.system(size: 11, weight: .semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            scoped ? appState.colors.accent.opacity(0.18) : .primary.opacity(0.06),
            in: Capsule()
          )
          .foregroundStyle(scoped ? appState.colors.accent : .secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: [.command, .option])
        .help(scoped ? "Searching in \(folderName) · ⌥⌘F for all folders" : "Search all folders · ⌥⌘F to limit to \(folderName)")
        .accessibilityLabel(scoped ? "Search this folder" : "Search all folders")
        .accessibilityHint("Toggle search scope to the selected folder")
      }

      if !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ToolbarIconButton(
          systemImage: "bookmark",
          help: "Save search"
        ) {
          appState.saveCurrentSearch(name: appState.searchQuery)
        }
      }

      if appState.isStartingBackend || !appState.searchReady {
        ProgressView().controlSize(.small)
      }

      ToolbarIconButton(
        systemImage: appState.liveSyncEnabled
          ? "arrow.triangle.2.circlepath.circle.fill"
          : "arrow.triangle.2.circlepath",
        help: appState.liveSyncEnabled ? "Live sync on" : "Live sync off",
        isActive: appState.liveSyncEnabled,
        activeTint: appState.colors.success
      ) {
        appState.toggleLiveSync()
      }

      Menu {
        Button("Index Selected") { appState.indexSelectedFolder() }
          .disabled(appState.isIndexing || appState.selectedFolder == nil)
        Button("Index All") { appState.indexAllFolders() }
          .disabled(appState.isIndexing)
        Divider()
        Button("Find Duplicates") { Task { await appState.loadDuplicates() } }
        Button("Privacy") { appState.showPrivacySheet = true }
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.leading, 78)
    .padding(.trailing, 14)
  }

  private var statusLine: some View {
    HStack(spacing: 8) {
      if appState.isStartingBackend || !appState.searchReady {
        ProgressView().controlSize(.small)
      } else if appState.isIndexing {
        ProgressView(value: Double(appState.indexProgressCurrent), total: Double(max(appState.indexProgressTotal, 1)))
          .frame(width: 80)
      }

      Text(appState.statusMessage)
        .font(.system(size: 11))
        .foregroundStyle(appState.colors.textTertiary)
        .lineLimit(1)

      if appState.isIndexing {
        Button("Cancel") { appState.cancelIndexing() }
          .font(.system(size: 11))
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
      }

      if !appState.backendReady && !appState.isStartingBackend {
        Text("· Backend offline").font(.system(size: 11)).foregroundStyle(.orange)
        Button("Retry") {
          Task { await appState.recoverBackend() }
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
      }
      Spacer()
      Label("Local only", systemImage: "lock.shield")
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .help("All search runs locally on your Mac")
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 10)
  }
}

#Preview {
  ContentView()
    .environmentObject(AppState())
    .frame(width: 1200, height: 800)
}
