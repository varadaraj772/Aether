import SwiftUI

struct LauncherView: View {
  @EnvironmentObject private var appState: AppState
  @FocusState private var focused: Bool

  private let cardWidth: CGFloat = 660
  private let cardTopInset: CGFloat = 128

  var body: some View {
    ZStack {
      // Tap outside the card to dismiss; dimming is the window backgroundColor.
      Color.clear
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .onTapGesture { dismissLauncher() }

      VStack(spacing: 0) {
        Spacer().frame(height: cardTopInset)

        launcherCard
          .frame(width: cardWidth)

        Spacer()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
    .onAppear { focusSearchField() }
    .onChange(of: appState.searchFocusGeneration) { _, _ in
      focusSearchField()
    }
    .onChange(of: appState.searchReady) { _, _ in
      focusSearchField()
    }
    .onKeyPress(.upArrow) {
      Task { @MainActor in appState.moveLauncherSelection(delta: -1) }
      return .handled
    }
    .onKeyPress(.downArrow) {
      Task { @MainActor in appState.moveLauncherSelection(delta: 1) }
      return .handled
    }
    .onKeyPress(.return) {
      Task { @MainActor in
        if NSEvent.modifierFlags.contains(.command) {
          openSelectionInWorkspace()
        } else {
          openSelectionAndDismiss()
        }
      }
      return .handled
    }
    .onKeyPress(.escape) {
      dismissLauncher()
      return .handled
    }
  }

  private var launcherCard: some View {
    VStack(spacing: 0) {
      searchRow

      Rectangle()
        .fill(.primary.opacity(0.08))
        .frame(height: 1)

      contentArea
        .frame(maxHeight: 340)

      Rectangle()
        .fill(.primary.opacity(0.06))
        .frame(height: 1)

      hintBar
    }
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
  }

  private var launcherPlaceholder: String {
    guard !appState.searchReady else { return "Search" }
    let status = appState.statusMessage
    if status.hasPrefix("Starting")
      || status.hasPrefix("Restarting")
      || status.hasPrefix("Downloading")
      || status.hasPrefix("Loading")
      || status.hasPrefix("Search model")
    {
      return status
    }
    if appState.isStartingBackend { return "Starting backend…" }
    return "Loading search…"
  }

  private var searchRow: some View {
    HStack(spacing: 12) {
      AetherSearchField(
        text: $appState.searchQuery,
        placeholder: launcherPlaceholder,
        focused: $focused,
        style: .launcher
      )

      if !appState.searchReady || appState.isStartingBackend {
        ProgressView().controlSize(.small)
      } else if !appState.searchQuery.isEmpty {
        Button { appState.searchQuery = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
      }

      Menu {
        Button("Open workspace") { appState.openWorkspace() }
        Button("Find duplicates") { Task { await appState.loadDuplicates() } }
        Button("Privacy") { appState.showPrivacySheet = true }
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.system(size: 15))
          .foregroundStyle(.tertiary)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 18)
  }

  @ViewBuilder
  private var contentArea: some View {
    let query = appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.count >= 2 {
      if appState.filteredResults.isEmpty && appState.statusMessage.contains("Searching") {
        loadingState
      } else if appState.filteredResults.isEmpty {
        emptyResults
      } else {
        resultsList
      }
    } else {
      idleState
    }
  }

  private var idleState: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if appState.folderStore.recentSearches.isEmpty && appState.folderStore.savedSearches.isEmpty {
          idleEmptyState
        }

        if !appState.folderStore.recentSearches.isEmpty {
          launcherSectionHeader("Recent")
          ForEach(appState.folderStore.recentSearches, id: \.self) { query in
            idleRow(icon: "clock", title: query, onRemove: {
              appState.deleteRecentSearch(query)
            }) {
              appState.runSearch(query)
            }
          }
        }

        if !appState.folderStore.savedSearches.isEmpty {
          launcherSectionHeader("Saved")
          ForEach(appState.folderStore.savedSearches) { saved in
            idleRow(icon: "bookmark.fill", title: saved.name, subtitle: saved.query) {
              appState.runSearch(saved.query)
            }
            .contextMenu {
              Button("Delete", role: .destructive) {
                appState.deleteSavedSearch(saved)
              }
            }
          }
        }
      }
      .padding(.vertical, 4)
    }
  }

  private var resultsList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(Array(appState.filteredResults.enumerated()), id: \.element.id) { index, item in
            resultRow(item, selected: index == appState.launcherSelectionIndex)
              .contentShape(Rectangle())
              .id(index)
              .onHover { hovering in
                guard hovering else { return }
                Task { @MainActor in
                  appState.selectLauncherItem(at: index)
                }
              }
              .onTapGesture {
                Task { @MainActor in
                  appState.selectLauncherItem(at: index)
                  openItem(at: index)
                }
              }
              .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                  Task { @MainActor in
                    appState.selectLauncherItem(at: index)
                    openItemInWorkspace(at: index)
                  }
                }
              )
          }
        }
      }
      .onChange(of: appState.launcherSelectionIndex) { _, index in
        withAnimation(.easeInOut(duration: 0.12)) {
          proxy.scrollTo(index, anchor: .center)
        }
      }
      .onChange(of: appState.results.count) { _, _ in
        let index = appState.launcherSelectionIndex
        guard appState.filteredResults.indices.contains(index) else { return }
        proxy.scrollTo(index, anchor: .top)
      }
    }
  }

  private var loadingState: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Searching…")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }

  @ViewBuilder
  private var idleEmptyState: some View {
    if appState.folderStore.folders.isEmpty {
      EmptyStateView(
        systemImage: "folder.badge.plus",
        title: "Add -> Index -> Search",
        message: "Add a folder, index it, then search by name, content, or idea.",
        actionTitle: "Add folder",
        action: {
          appState.openWorkspace()
          appState.addFolder()
        },
        secondaryActionTitle: "Open workspace",
        secondaryAction: { appState.openWorkspace() }
      )
    } else if appState.noneFoldersIndexed {
      EmptyStateView(
        systemImage: "cylinder.split.1x2",
        title: "Index your folders",
        message: "Folders are added. Index them so Aether can search by meaning.",
        actionTitle: "Index all",
        action: {
          appState.openWorkspace()
          appState.indexAllFolders()
        },
        secondaryActionTitle: "Open workspace",
        secondaryAction: { appState.openWorkspace() }
      )
    } else {
      EmptyStateView(
        systemImage: "sparkle.magnifyingglass",
        title: "Search by meaning",
        message: "Type at least 2 characters to find files by name, content, or idea."
      )
    }
  }

  @ViewBuilder
  private var emptyResults: some View {
    if appState.folderStore.folders.isEmpty {
      EmptyStateView(
        systemImage: "folder.badge.plus",
        title: "No folders yet",
        message: "Add a folder, index it, then search.",
        actionTitle: "Add folder",
        action: {
          appState.openWorkspace()
          appState.addFolder()
        }
      )
    } else if appState.noneFoldersIndexed {
      EmptyStateView(
        systemImage: "cylinder.split.1x2",
        title: "Nothing indexed yet",
        message: "Index your folders so Aether can search by meaning.",
        actionTitle: appState.selectedFolder != nil ? "Index selected" : "Index all",
        action: {
          appState.openWorkspace()
          if appState.selectedFolder != nil {
            appState.indexSelectedFolder()
          } else {
            appState.indexAllFolders()
          }
        },
        secondaryActionTitle: appState.selectedFolder != nil ? "Index all" : nil,
        secondaryAction: appState.selectedFolder != nil
          ? { appState.indexAllFolders() }
          : nil
      )
    } else {
      EmptyStateView(
        systemImage: "magnifyingglass",
        title: "No results",
        message: "Try different words, or open the workspace to index more folders.",
        actionTitle: "Open workspace",
        action: { appState.openWorkspace() }
      )
    }
  }

  private var hintBar: some View {
    HStack(spacing: 16) {
      hint("↩", "Open file")
      hint("⌘↩", "Workspace")
      hint("esc", "Close")
      Spacer()
      if appState.searchReady {
        Label("Local", systemImage: "lock.fill")
          .font(.system(size: 10))
          .foregroundStyle(.quaternary)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  private func launcherSectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 20)
      .padding(.top, 10)
      .padding(.bottom, 4)
  }

  private func idleRow(
    icon: String,
    title: String,
    subtitle: String? = nil,
    onRemove: (() -> Void)? = nil,
    action: @escaping () -> Void
  ) -> some View {
    IdleRowView(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onRemove: onRemove,
      action: action
    )
  }

  private func resultRow(_ item: SearchResultItem, selected: Bool) -> some View {
    let meta = ExtMetaLookup.meta(for: item.fileName)

    return HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(meta.color.opacity(0.18))
        .frame(width: 36, height: 36)
        .overlay {
          Text(meta.tag.prefix(3))
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(meta.color)
        }

      VStack(alignment: .leading, spacing: 2) {
        Text(item.fileName)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Text(item.displaySnippet)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Text(appState.folderStore.folderHint(for: item.path))
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      Text("\(item.relevancePercent)%")
        .font(.system(size: selected ? 11 : 10, weight: selected ? .medium : .regular))
        .foregroundStyle(selected ? .secondary : .tertiary)
        .monospacedDigit()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      selected ? appState.colors.accent.opacity(0.18) : Color.clear,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .padding(.horizontal, 8)
    .padding(.vertical, 1)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(item.fileName), \(appState.folderStore.folderHint(for: item.path)), \(item.relevancePercent) percent")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func hint(_ key: String, _ label: String) -> some View {
    HStack(spacing: 4) {
      Text(key)
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
      Text(label)
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
  }

  private func openItem(at index: Int) {
    guard appState.filteredResults.indices.contains(index) else { return }
    appState.selectedResult = appState.filteredResults[index]
    appState.openSelectedResult()
    dismissLauncher()
  }

  private func openItemInWorkspace(at index: Int) {
    guard appState.filteredResults.indices.contains(index) else {
      appState.openWorkspace()
      return
    }
    let item = appState.filteredResults[index]
    appState.selectedResult = item
    appState.openWorkspace()
    Task { await appState.selectResult(item) }
  }

  private func openSelectionAndDismiss() {
    openItem(at: appState.launcherSelectionIndex)
  }

  private func openSelectionInWorkspace() {
    openItemInWorkspace(at: appState.launcherSelectionIndex)
  }

  private func focusSearchField() {
    Task { @MainActor in
      NSApp.activate(ignoringOtherApps: true)
      try? await Task.sleep(for: .milliseconds(50))
      focused = true
    }
  }

  private func dismissLauncher() {
    NSApp.keyWindow?.orderOut(nil)
  }
}

private struct IdleRowView: View {
  let icon: String
  let title: String
  var subtitle: String? = nil
  var onRemove: (() -> Void)? = nil
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 0) {
      Button(action: action) {
        HStack(spacing: 12) {
          Image(systemName: icon)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(.system(size: 14))
              .foregroundStyle(.primary)
              .lineLimit(1)
            if let subtitle {
              Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if let onRemove {
        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .help("Remove")
      }
    }
    .padding(.horizontal, 8)
    .background(
      isHovered ? Color.primary.opacity(0.06) : Color.clear,
      in: RoundedRectangle(cornerRadius: GlassMetrics.rowRadius)
    )
    .onHover { isHovered = $0 }
  }
}

struct DuplicatesView: View {
  @EnvironmentObject private var appState: AppState
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Duplicate files")
          .font(.title3.bold())
        Spacer()
        Button("Done") { dismiss() }
      }

      if appState.isLoadingDuplicates {
        VStack(spacing: 12) {
          ProgressView("Scanning for duplicates…")
          Text("This may take a minute on large indexes.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if appState.duplicateGroups.isEmpty {
        EmptyStateView(
          systemImage: "checkmark.circle",
          title: "No duplicates found",
          message: "Your indexed files look unique"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(appState.duplicateGroups) { group in
              VStack(alignment: .leading, spacing: 8) {
                Text("\(group.title) · \(group.files.count) files")
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(.secondary)

                ForEach(group.files) { file in
                  VStack(alignment: .leading, spacing: 2) {
                    Text(file.fileName)
                      .font(.system(size: 13, weight: .medium))
                      .foregroundStyle(.primary)
                      .lineLimit(1)
                    Text(file.path)
                      .font(.system(size: 10, design: .monospaced))
                      .foregroundStyle(.tertiary)
                      .lineLimit(2)
                      .textSelection(.enabled)
                  }
                  .padding(.vertical, 2)
                }
              }
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
              .overlay {
                RoundedRectangle(cornerRadius: 10)
                  .stroke(.primary.opacity(0.06), lineWidth: 1)
              }
            }
          }
        }
      }
    }
    .padding(20)
    .frame(width: 560, height: 420)
  }
}

struct PrivacyView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Privacy", systemImage: "lock.shield.fill")
          .font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }
      }

      VStack(alignment: .leading, spacing: 10) {
        privacyCard(
          icon: "lock.shield",
          title: "100% local",
          detail: "All indexing and search runs on your Mac. Nothing is sent to the cloud."
        )
        privacyCard(
          icon: "internaldrive",
          title: "Your files stay yours",
          detail: "Content is stored in ~/.aether for search only."
        )
        privacyCard(
          icon: "chart.bar.xaxis",
          title: "No telemetry",
          detail: "Aether does not collect usage data or analytics."
        )
        privacyCard(
          icon: "brain",
          title: "Semantic, not surveillance",
          detail: "Embeddings are computed locally to understand meaning - not to track you."
        )
      }

      Text("Index location: ~/.aether/db")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)

      Spacer()
    }
    .padding(24)
    .frame(width: 480, height: 400)
  }

  private func privacyCard(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 32, height: 32)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
  }
}
