import SwiftUI

struct FolderRowView: View {
  let name: String
  let path: String
  let status: String
  let selected: Bool
  let colors: ThemeColors

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "folder.fill")
        .font(.system(size: 14))
        .foregroundStyle(selected ? colors.accent : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(name)
          .font(.system(size: 12, weight: selected ? .semibold : .regular))
          .foregroundStyle(colors.title)
          .lineLimit(1)
        Text(status)
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(selected ? colors.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
    .help("\(path)\n\(status)\nDouble-click to browse")
    .accessibilityLabel("\(name), \(status)")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct FolderEntryRowView: View {
  let entry: FolderEntry
  let selected: Bool
  let colors: ThemeColors

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: entry.isDirectory ? "folder" : "doc")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
      Text(entry.name)
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .foregroundStyle(colors.title)
        .lineLimit(1)
      Spacer(minLength: 0)
      if entry.isDirectory {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.quaternary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(selected ? colors.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
    .help(
      entry.isDirectory
        ? "\(entry.path)\nDouble-click to open"
        : "\(entry.path)\nClick to preview · Double-click to open"
    )
    .accessibilityLabel(entry.name)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct FoldersPanelView: View {
  @EnvironmentObject private var appState: AppState
  @StateObject private var collectionLoader = SmartCollectionLoader()
  @State private var isDropTargeted = false
  @State private var browseStack: [String] = []
  @State private var selectedEntryPath: String?
  @State private var browseSort: BrowseSortMode = .name
  @State private var browseEntries: [FolderEntry] = []
  @State private var isLoadingBrowse = false
  @State private var browseLoadTask: Task<Void, Never>?

  private var isBrowsing: Bool { !browseStack.isEmpty }
  private var currentBrowsePath: String? { browseStack.last }
  private var browseRoot: String? { browseStack.first }

  var body: some View {
    GlassPanel {
      VStack(alignment: .leading, spacing: 10) {
        header
        collectionsBar

        if isBrowsing, let path = currentBrowsePath {
          breadcrumbs(for: path)
          browseToolbar
        }

        ScrollView {
          LazyVStack(spacing: 2) {
            if appState.activeSmartCollection != .all, !isBrowsing {
              if collectionLoader.isLoading {
                ProgressView("Scanning…")
                  .controlSize(.small)
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 16)
              } else if sortedCollectionItems.isEmpty {
                EmptyStateView(
                  systemImage: "tray",
                  title: "Nothing here"
                )
              } else {
                ForEach(sortedCollectionItems) { entry in
                  collectionRow(entry)
                }
              }
            } else if isBrowsing {
              browseContents
            } else {
              rootsList
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if !isBrowsing && appState.activeSmartCollection == .all {
          Button { appState.addFolder() } label: {
            Label("Add folder", systemImage: "plus")
              .font(.system(size: 12))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.glass)
          .help("Choose a folder to index, or drag one here")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .folderDropTarget(isTargeted: $isDropTargeted)
    .onChange(of: appState.activeSmartCollection) { _, collection in
      Task { @MainActor in reloadCollection(collection) }
    }
    .onChange(of: browseStack) { _, _ in
      Task { @MainActor in reloadBrowseEntries() }
    }
    .onChange(of: browseSort) { _, _ in
      Task { @MainActor in reloadBrowseEntries() }
    }
    .onAppear {
      Task { @MainActor in
        reloadCollection(appState.activeSmartCollection)
        reloadBrowseEntries()
      }
    }
  }

  private var sortedCollectionItems: [FolderEntry] {
    FolderBrowser.sortEntries(collectionLoader.items, by: browseSort)
  }

  private func reloadCollection(_ collection: SmartCollection) {
    collectionLoader.load(
      collection: collection,
      folders: appState.folderStore.folders,
      folderStats: appState.folderStats
    )
  }

  private func reloadBrowseEntries() {
    browseLoadTask?.cancel()

    Task { @MainActor in
      guard let path = currentBrowsePath else {
        browseEntries = []
        isLoadingBrowse = false
        return
      }

      isLoadingBrowse = true
      let sort = browseSort
      browseLoadTask = Task { @MainActor in
        let entries = await Task.detached(priority: .userInitiated) {
          FolderBrowser.list(path: path, sort: sort)
        }.value

        guard !Task.isCancelled else { return }
        browseEntries = entries
        isLoadingBrowse = false
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      if isBrowsing {
        Button {
          selectedEntryPath = nil
          if browseStack.count == 1 {
            browseStack = []
          } else {
            browseStack.removeLast()
          }
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.plain)
        .help("Go back")
      }

      PanelHeader(title: headerTitle, trailing: headerTrailing)
    }
  }

  private var collectionsBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(SmartCollection.allCases) { collection in
          let selected = appState.activeSmartCollection == collection
          Button {
            appState.activeSmartCollection = collection
            browseStack = []
          } label: {
            Label(collection.label, systemImage: collection.systemImage)
              .font(.system(size: 10, weight: selected ? .medium : .regular))
              .foregroundStyle(selected ? .primary : .secondary)
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            selected
              ? appState.colors.accent.opacity(0.18)
              : Color.primary.opacity(0.05),
            in: Capsule()
          )
          .accessibilityLabel(collection.label)
          .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
          .accessibilityHint(selected ? "Selected collection" : "Show \(collection.label) collection")
        }
      }
    }
  }

  private var browseToolbar: some View {
    Picker("Sort", selection: $browseSort) {
      ForEach(BrowseSortMode.allCases) { mode in
        Text(mode.label).tag(mode)
      }
    }
    .labelsHidden()
    .frame(maxWidth: 120)
  }

  @ViewBuilder
  private func breadcrumbs(for path: String) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(FolderBrowser.breadcrumbs(for: path, root: browseRoot), id: \.self) { crumb in
          Button((crumb as NSString).lastPathComponent) {
            if let index = browseStack.firstIndex(of: crumb) {
              browseStack = Array(browseStack.prefix(through: index))
            }
          }
          .buttonStyle(.plain)
          .font(.system(size: 10, weight: crumb == path ? .semibold : .regular))
          if crumb != path {
            Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.quaternary)
          }
        }
      }
    }
  }

  private var headerTitle: String {
    if appState.activeSmartCollection != .all, !isBrowsing {
      return appState.activeSmartCollection.label
    }
    guard let path = currentBrowsePath else { return "Folders" }
    return (path as NSString).lastPathComponent
  }

  private var headerTrailing: String? {
    if appState.activeSmartCollection != .all, !isBrowsing {
      return collectionLoader.isLoading ? "…" : "\(sortedCollectionItems.count)"
    }
    if isBrowsing {
      if isLoadingBrowse { return "…" }
      return "\(browseEntries.count)"
    }
    return "\(appState.folderStore.folders.count)"
  }

  @ViewBuilder
  private var rootsList: some View {
    if appState.folderStore.folders.isEmpty {
      EmptyStateView(
        systemImage: "folder.badge.plus",
        title: "Add a folder to start",
        message: "Add -> Index -> Search. Drop a folder here, or use Add folder.",
        actionTitle: "Add folder",
        action: { appState.addFolder() }
      )
    }

    ForEach(appState.folderStore.folders, id: \.self) { folder in
      Button {
        appState.selectedFolder = folder
      } label: {
        FolderRowView(
          name: appState.folderStore.displayName(for: folder),
          path: folder,
          status: folderStatus(folder),
          selected: appState.selectedFolder == folder,
          colors: appState.colors
        )
      }
      .buttonStyle(.plain)
      .simultaneousGesture(
        TapGesture(count: 2).onEnded {
          appState.selectedFolder = folder
          appState.activeSmartCollection = .all
          browseStack = [folder]
        }
      )
      .contextMenu { folderContext(folder) }
    }
  }

  @ViewBuilder
  private var browseContents: some View {
    if isLoadingBrowse && browseEntries.isEmpty {
      ProgressView("Loading…")
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    } else if browseEntries.isEmpty {
      EmptyStateView(
        systemImage: "folder",
        title: "Empty folder"
      )
    } else {
      ForEach(browseEntries) { entry in
        browseRow(entry)
      }
    }
  }

  private func browseRow(_ entry: FolderEntry) -> some View {
    Button {
      selectedEntryPath = entry.path
      if entry.isDirectory {
        appState.selectedFolder = browseStack.first
      } else {
        Task { await appState.previewFile(at: entry.path) }
      }
    } label: {
      HStack {
        FolderEntryRowView(entry: entry, selected: selectedEntryPath == entry.path, colors: appState.colors)
        if !entry.isDirectory, let size = entry.fileSize {
          Text(FolderBrowser.formatSize(size))
            .font(.system(size: 9))
            .foregroundStyle(.quaternary)
        }
      }
    }
    .buttonStyle(.plain)
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        if entry.isDirectory {
          browseStack.append(entry.path)
        } else {
          appState.openFile(at: entry.path)
        }
      }
    )
    .contextMenu { entryContext(entry) }
  }

  private func collectionRow(_ entry: FolderEntry) -> some View {
    Button {
      selectedEntryPath = entry.path
      if entry.isDirectory {
        appState.selectedFolder = entry.path
      } else {
        Task { await appState.previewFile(at: entry.path) }
      }
    } label: {
      FolderEntryRowView(
        entry: entry,
        selected: selectedEntryPath == entry.path,
        colors: appState.colors
      )
    }
    .buttonStyle(.plain)
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        if entry.isDirectory {
          appState.activeSmartCollection = .all
          browseStack = [entry.path]
        } else {
          appState.openFile(at: entry.path)
        }
      }
    )
  }

  @ViewBuilder
  private func folderContext(_ folder: String) -> some View {
    Button("Browse") {
      appState.selectedFolder = folder
      browseStack = [folder]
    }
    Button("Index") {
      appState.selectedFolder = folder
      appState.indexSelectedFolder()
    }
    Button("Re-index") {
      appState.selectedFolder = folder
      appState.indexSelectedFolder(force: true)
    }
    Button("Remove", role: .destructive) {
      appState.selectedFolder = folder
      Task { await appState.removeSelectedFolder() }
    }
  }

  @ViewBuilder
  private func entryContext(_ entry: FolderEntry) -> some View {
    if entry.isDirectory {
      Button("Open") { browseStack.append(entry.path) }
    } else {
      Button("Open") { appState.openFile(at: entry.path) }
      Button("Preview") { Task { await appState.previewFile(at: entry.path) } }
      Button("Reveal in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
      }
    }
  }

  private func folderStatus(_ folder: String) -> String {
    if let stats = appState.folderStats[folder], stats.indexed {
      return "\(stats.fileCount) files"
    }
    return "Not indexed"
  }
}
