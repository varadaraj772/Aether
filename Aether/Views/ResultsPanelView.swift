import SwiftUI

struct ResultRowView: View {
  let item: SearchResultItem
  let folderHint: String
  let selected: Bool
  let colors: ThemeColors

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(item.fileName)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(colors.title)
          .lineLimit(1)

        FileTypeBadge(fileName: item.fileName)

        Spacer(minLength: 0)

        Text("\(item.relevancePercent)%")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }

      Text(folderHint)
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .lineLimit(1)

      Text(item.displaySnippet)
        .font(.system(size: 11))
        .foregroundStyle(colors.snippet)
        .lineLimit(2)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      selected ? colors.accent.opacity(0.12) : .clear,
      in: RoundedRectangle(cornerRadius: GlassMetrics.rowRadius)
    )
    .overlay {
      if selected {
        RoundedRectangle(cornerRadius: GlassMetrics.rowRadius)
          .stroke(colors.accent.opacity(0.28), lineWidth: 1)
      }
    }
    .help("\(item.path)\n\(item.relevancePercent)% match · Space for Quick Look · Double-click to open")
  }
}

struct ResultsPanelView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    GlassPanel {
      VStack(alignment: .leading, spacing: 10) {
        headerRow
        resultsList
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var headerRow: some View {
    HStack(spacing: 8) {
      Text(appState.resultsHeadline)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer(minLength: 4)

      scopeControl

      Picker("Filter", selection: $appState.activeFilter) {
        ForEach(FileTypeFilter.allCases) { filter in
          Text(filter.label).tag(filter)
        }
      }
      .labelsHidden()
      .frame(width: 100)
      .help("Filter results by file type")
      .accessibilityLabel("File type filter")

      Picker("Sort", selection: $appState.sortMode) {
        ForEach(SortMode.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .labelsHidden()
      .frame(width: 120)
      .help("Sort results")
      .accessibilityLabel("Sort results")
    }
  }

  @ViewBuilder
  private var scopeControl: some View {
    if let folder = appState.selectedFolder {
      let name = appState.folderStore.displayName(for: folder)
      let scoped = appState.searchScopeSelectedFolder
      Button {
        appState.toggleSearchScopeSelectedFolder()
      } label: {
        Label(
          scoped ? "This Folder: \(name)" : "All Folders",
          systemImage: scoped ? "folder.fill" : "folder"
        )
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          scoped ? appState.colors.accent.opacity(0.14) : .primary.opacity(0.05),
          in: Capsule()
        )
        .foregroundStyle(scoped ? appState.colors.accent : .secondary)
      }
      .buttonStyle(.plain)
      .help(scoped ? "Limited to \(name) · ⌥⌘F to search all" : "Searching all folders · ⌥⌘F to limit to \(name)")
      .accessibilityLabel(scoped ? "Search this folder, \(name)" : "Search all folders")
      .accessibilityValue(scoped ? "On" : "Off")
    }
  }

  private var resultsList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 4) {
          if shouldShowSearching {
            searchingState
          } else if shouldShowEmpty {
            emptyResultsState
          } else if shouldShowPrompt {
            promptState
          } else {
            ForEach(Array(appState.filteredResults.enumerated()), id: \.element.id) { index, item in
              resultButton(item, index: index)
                .id(index)
            }
          }
        }
        .id(appState.activeSearchToken)
        .animation(.easeInOut(duration: 0.15), value: appState.activeSearchToken)
        .frame(maxWidth: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: appState.launcherSelectionIndex) { _, index in
        scrollTo(index, proxy: proxy, anchor: .center)
      }
      .onChange(of: appState.activeSearchToken) { _, _ in
        scrollTo(appState.launcherSelectionIndex, proxy: proxy, anchor: .top)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityLabel("Search results")
  }

  private var searchingState: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("Searching…")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
  }

  @ViewBuilder
  private var emptyResultsState: some View {
    if appState.noneFoldersIndexed {
      EmptyStateView(
        systemImage: "cylinder.split.1x2",
        title: "Nothing indexed yet",
        message: "Index selected or all folders so Aether can search by meaning.",
        actionTitle: appState.selectedFolder != nil ? "Index selected" : "Index all",
        action: {
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
      let scoped = appState.searchScopeSelectedFolder && appState.selectedFolder != nil
      let scopeName = appState.selectedFolder.map { appState.folderStore.displayName(for: $0) }
      EmptyStateView(
        systemImage: "magnifyingglass",
        title: "No results",
        message: {
          if scoped, let scopeName {
            return "No matches in \(scopeName). Try different words, or search all folders."
          }
          return "Try different words, or index more folders."
        }()
      )
    }
  }

  @ViewBuilder
  private var promptState: some View {
    if appState.folderStore.folders.isEmpty {
      EmptyStateView(
        systemImage: "folder.badge.plus",
        title: "Add -> Index -> Search",
        message: "Add a folder, index it, then type to search by meaning.",
        actionTitle: "Add folder",
        action: { appState.addFolder() }
      )
    } else if appState.noneFoldersIndexed {
      EmptyStateView(
        systemImage: "cylinder.split.1x2",
        title: "Index before you search",
        message: "Folders are ready. Index selected or all to enable meaning-based search.",
        actionTitle: appState.selectedFolder != nil ? "Index selected" : "Index all",
        action: {
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
        systemImage: "text.magnifyingglass",
        title: "Search your indexed files",
        message: "Type at least 2 characters"
      )
    }
  }

  private var trimmedQuery: String {
    appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var shouldShowPrompt: Bool {
    trimmedQuery.count < 2
  }

  private var shouldShowSearching: Bool {
    trimmedQuery.count >= 2 && appState.filteredResults.isEmpty && appState.statusMessage.contains("Searching")
  }

  private var shouldShowEmpty: Bool {
    trimmedQuery.count >= 2 && appState.filteredResults.isEmpty && !appState.statusMessage.contains("Searching")
  }

  private func resultButton(_ item: SearchResultItem, index: Int) -> some View {
    Button {
      Task { await appState.selectResult(item) }
    } label: {
      ResultRowView(
        item: item,
        folderHint: appState.folderStore.folderHint(for: item.path),
        selected: appState.selectedResult?.id == item.id,
        colors: appState.colors
      )
    }
    .buttonStyle(.plain)
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        appState.selectedResult = item
        appState.openSelectedResult()
      }
    )
    .accessibilityLabel("\(item.fileName), \(item.relevancePercent) percent match")
    .accessibilityValue(appState.selectedResult?.id == item.id ? "Selected" : "Not selected")
    .accessibilityHint("Select to preview. Press Space for Quick Look. Double-click to open")
  }

  private func scrollTo(_ index: Int, proxy: ScrollViewProxy, anchor: UnitPoint) {
    guard appState.filteredResults.indices.contains(index) else { return }
    withAnimation(.easeInOut(duration: 0.12)) {
      proxy.scrollTo(index, anchor: anchor)
    }
  }
}
