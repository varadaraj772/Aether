import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
  @Published var searchQuery = ""
  @Published var results: [SearchResultItem] = []
  @Published var selectedFolder: String?
  @Published var searchScopeSelectedFolder = false
  @Published var selectedResult: SearchResultItem?
  @Published var previewContent = ""
  @Published var activeFilter: FileTypeFilter = .all
  @Published var sortMode: SortMode = .relevance
  @Published var statusMessage = "Ready"
  @Published var isIndexing = false
  @Published var isSearching = false
  @Published var lastSearchError: String?
  @Published var liveSyncEnabled = false
  @Published var folderStats: [String: FolderStats] = [:]
  @Published var isDark = true
  @Published var colors = ThemeColors.palette(isDark: true)
  @Published var backendReady = false
  @Published var searchReady = false
  @Published var isStartingBackend = false
  @Published var backendError: String?
  @Published var appMode: AppMode = .launcher
  @Published var showPrivacySheet = false
  @Published var showDuplicateSheet = false
  @Published var relatedResults: [SearchResultItem] = []
  @Published var duplicateGroups: [DuplicateGroup] = []
  @Published var activeSmartCollection: SmartCollection = .all
  @Published var launcherSelectionIndex = 0
  @Published private(set) var searchFocusGeneration = 0
  @Published var showOnboarding = false
  @Published var autoIndexOnLaunch = UserDefaults.standard.bool(forKey: "autoIndexOnLaunch")
  @Published var indexNotificationsEnabled = UserDefaults.standard.object(forKey: "indexNotificationsEnabled") as? Bool ?? true
  @Published var indexProgressCurrent = 0
  @Published var indexProgressTotal = 0
  @Published var isLoadingDuplicates = false
  @Published private(set) var activeSearchToken = 0
  @Published var excludedDirNames: [String] = ExcludePathStore.load()
  @Published var isRefreshingFolderHealth = false
  @Published var newExcludeDraft = ""

  let folderStore = FolderStore()
  private let quickLookPreview = QuickLookPreviewCoordinator()
  private let backend = BackendClient.shared
  private let watcher = FileWatcherService()
  private let hotKey = HotKeyManager()
  private let statusBar = StatusBarController()
  private var searchTask: Task<Void, Never>?
  private var indexTask: Task<Void, Never>?
  private var didBootstrap = false
  private var cancellables = Set<AnyCancellable>()
  private var searchGeneration = 0
  /// Bumped to invalidate in-flight index polling after cancel/recovery.
  private var indexSession = 0
  /// True while an index job is outstanding (survives brief isIndexing clears on crash).
  private var indexInFlight = false
  private static let recentOpenedPathsKey = "recentOpenedPaths"
  private static let recentOpenedItemsKey = "recentOpenedItems"
  private static let maxRecentOpenedItems = 100

  init() {
    folderStore.objectWillChange
      .sink { [weak self] _ in
        guard let self else { return }
        DispatchQueue.main.async {
          self.objectWillChange.send()
        }
      }
      .store(in: &cancellables)
  }

  private var recentOpenedItems: [RecentOpenedItem] {
    get { loadRecentOpenedItems() }
    set { saveRecentOpenedItems(newValue) }
  }

  private func loadRecentOpenedItems() -> [RecentOpenedItem] {
    if let data = UserDefaults.standard.data(forKey: Self.recentOpenedItemsKey),
       let items = try? JSONDecoder().decode([RecentOpenedItem].self, from: data)
    {
      return items
    }

    // Migrate legacy string list so existing open history is preserved.
    let legacy = UserDefaults.standard.stringArray(forKey: Self.recentOpenedPathsKey) ?? []
    guard !legacy.isEmpty else { return [] }
    let now = Date()
    let migrated: [RecentOpenedItem] = legacy.enumerated().map { index, path in
      RecentOpenedItem(
        path: path,
        openCount: 1,
        lastOpenedAt: now.addingTimeInterval(TimeInterval(-index))
      )
    }
    saveRecentOpenedItems(migrated)
    UserDefaults.standard.removeObject(forKey: Self.recentOpenedPathsKey)
    return migrated
  }

  private func saveRecentOpenedItems(_ items: [RecentOpenedItem]) {
    guard let data = try? JSONEncoder().encode(items) else { return }
    UserDefaults.standard.set(data, forKey: Self.recentOpenedItemsKey)
  }

  private func rememberOpenedPath(_ path: String) {
    var items = recentOpenedItems
    let now = Date()
    if let index = items.firstIndex(where: { $0.path == path }) {
      var item = items.remove(at: index)
      item.openCount += 1
      item.lastOpenedAt = now
      items.insert(item, at: 0)
    } else {
      items.insert(RecentOpenedItem(path: path, openCount: 1, lastOpenedAt: now), at: 0)
    }
    if items.count > Self.maxRecentOpenedItems {
      items = Array(items.prefix(Self.maxRecentOpenedItems))
    }
    recentOpenedItems = items
  }

  private var recentItemsBridgePayload: [[String: Any]] {
    recentOpenedItems.map { $0.bridgePayload() }
  }

  var filteredResults: [SearchResultItem] {
    computeFilteredResults()
  }

  private func computeFilteredResults() -> [SearchResultItem] {
    var items = results.filter { activeFilter.matches(fileName: $0.fileName) }
    if searchScopeSelectedFolder, let folder = selectedFolder {
      items = items.filter { item in
        item.path == folder || item.path.hasPrefix(folder + "/")
      }
    }
    switch sortMode {
    case .relevance:
      items.sort { $0.finalScore > $1.finalScore }
    case .name:
      items.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    case .date:
      items.sort { lhs, rhs in
        modificationDate(for: lhs.path) > modificationDate(for: rhs.path)
      }
    }
    return items
  }

  private func modificationDate(for path: String) -> Date {
    (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
  }

  var resultsHeadline: String {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = filteredResults
    let scopeSuffix: String = {
      guard searchScopeSelectedFolder, let folder = selectedFolder else { return "" }
      return " in \(folderStore.displayName(for: folder))"
    }()
    if query.isEmpty { return "Start typing to search" }
    if filtered.isEmpty { return "No results found\(scopeSuffix)" }
    if activeFilter != .all, filtered.count < results.count {
      return "\(filtered.count) of \(results.count) results\(scopeSuffix)"
    }
    return "\(filtered.count) result\(filtered.count == 1 ? "" : "s")\(scopeSuffix)"
  }

  func bootstrap() {
    guard !didBootstrap else { return }
    didBootstrap = true

    updateTheme()
    statusBar.install(appState: self)
    hotKey.register { [weak self] in
      self?.toggleWindow()
    }

    NotificationCenter.default.publisher(for: .aetherIndexProgress)
      .receive(on: RunLoop.main)
      .sink { [weak self] notification in
        self?.applyIndexProgress(notification.userInfo)
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: .aetherModelProgress)
      .receive(on: RunLoop.main)
      .sink { [weak self] notification in
        guard let stage = notification.userInfo?["stage"] as? String else { return }
        self?.applyModelProgress(stage)
      }
      .store(in: &cancellables)

    $searchQuery
      .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
      .sink { [weak self] query in
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self?.handleDebouncedSearchQuery(trimmed)
      }
      .store(in: &cancellables)

    Publishers.CombineLatest($selectedFolder, $searchScopeSelectedFolder)
      .dropFirst()
      .sink { [weak self] _, _ in
        guard let self else { return }
        let trimmed = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        self.searchTask?.cancel()
        self.searchTask = Task { await self.performSearch(query: trimmed) }
      }
      .store(in: &cancellables)

    Task {
      // Bring the UI up as soon as the Python process responds; model warmup continues in background.
      await startBackend(warmupInBackground: true)
      await refreshConfigFromBackend()
      await refreshAllFolderStats()
      if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        showOnboarding = true
      } else if autoIndexOnLaunch {
        await waitForSearchReady(timeoutSeconds: 300)
        if searchReady {
          await indexMissingFolders()
        }
      }
    }
  }

  func completeOnboarding() {
    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    UserDefaults.standard.set(autoIndexOnLaunch, forKey: "autoIndexOnLaunch")
    showOnboarding = false
    if autoIndexOnLaunch {
      Task { await indexMissingFolders() }
    }
  }

  func shutdown() {
    watcher.stop()
    hotKey.unregister()
    statusBar.uninstall()
    Task { await backend.stop() }
  }

  var hasIndexedFolders: Bool {
    folderStore.folders.contains { folderStats[$0]?.indexed == true }
  }

  var noneFoldersIndexed: Bool {
    !folderStore.folders.isEmpty && !hasIndexedFolders
  }

  func refreshFolderHealth() async {
    isRefreshingFolderHealth = true
    await refreshConfigFromBackend()
    await refreshAllFolderStats()
    isRefreshingFolderHealth = false
  }

  func addExcludePath(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var next = excludedDirNames
    if !next.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      next.append(trimmed)
    }
    applyExcludes(next)
    newExcludeDraft = ""
  }

  func removeExcludePath(_ name: String) {
    applyExcludes(excludedDirNames.filter { $0.caseInsensitiveCompare(name) != .orderedSame })
  }

  func restoreDefaultExcludes() {
    applyExcludes(ExcludePathStore.restoreDefaults())
  }

  private func applyExcludes(_ names: [String]) {
    let normalized = ExcludePathStore.normalize(names)
    excludedDirNames = normalized
    ExcludePathStore.save(normalized)
    Task { await pushExcludesToBackend() }
  }

  func recoverBackend() async {
    guard didBootstrap else { return }
    let wasIndexing = isIndexing || indexInFlight
    backendReady = false
    searchReady = false
    resetIndexProgressState(cancelPolling: true)
    statusMessage = "Restarting backend…"
    await backend.stop()
    await startBackend(warmupInBackground: true)
    await refreshConfigFromBackend()
    await refreshAllFolderStats()
    if liveSyncEnabled { restartWatcher() }
    if wasIndexing, searchReady {
      statusMessage = "Backend restarted - indexing may be incomplete"
      backendError = """
      Indexing was interrupted when the backend restarted. \
      Re-index the affected folder(s) (Index Selected / Index All) to finish.
      """
    }
  }

  private func resetIndexProgressState(cancelPolling: Bool) {
    if cancelPolling {
      indexSession += 1
      indexTask?.cancel()
      indexTask = nil
    }
    isIndexing = false
    indexInFlight = false
    indexProgressCurrent = 0
    indexProgressTotal = 0
  }

  private func applyModelProgress(_ stage: String) {
    guard isStartingBackend || !searchReady else { return }
    switch stage.lowercased() {
    case "downloading":
      statusMessage = "Downloading search model…"
    case "loading":
      statusMessage = "Loading search model…"
    case "ready":
      statusMessage = "Search model ready"
    case "error":
      statusMessage = "Search model failed to load"
    default:
      break
    }
  }

  func updateTheme() {
    isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    colors = ThemeColors.palette(isDark: isDark)
  }

  func requestSearchFocus() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    searchFocusGeneration += 1
  }

  func toggleWindow() {
    guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
    if window.isVisible, NSApp.isActive, window.isKeyWindow {
      if appMode == .workspace {
        openLauncher()
      } else {
        window.orderOut(nil)
      }
    } else {
      appMode = .launcher
      launcherSelectionIndex = 0
      resetLauncherSession()
      resizeWindow(for: .launcher)
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      requestSearchFocus()
    }
  }

  func openWorkspace() {
    appMode = .workspace
    scheduleWindowResize(for: .workspace)
    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count >= 2, results.isEmpty {
      runSearch(trimmed)
    }
  }

  func openLauncher(preserveSession: Bool = true) {
    quickLookPreview.close()
    appMode = .launcher
    if !preserveSession {
      resetLauncherSession()
      launcherSelectionIndex = 0
    }
    resizeWindow(for: .launcher)
    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    requestSearchFocus()
  }

  func prepareLauncherWindow() {
    resizeWindow(for: .launcher)
  }

  func resetLauncherSession() {
    searchTask?.cancel()
    searchQuery = ""
    clearSearchResults()
  }

  private func scheduleWindowResize(for mode: AppMode) {
    DispatchQueue.main.async {
      self.resizeWindow(for: mode)
    }
  }

  private func resizeWindow(for mode: AppMode) {
    guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
    if mode == .launcher {
      if let frame = (window.screen ?? NSScreen.main)?.visibleFrame {
        window.setFrame(frame, display: true)
      }
    } else {
      window.setContentSize(NSSize(width: 1280, height: 820))
      window.center()
    }
  }

  func dismissLauncher() {
    NSApp.keyWindow?.orderOut(nil)
  }

  private func clearSearchResults() {
    activeSearchToken += 1
    results = []
    selectedResult = nil
    previewContent = ""
    relatedResults = []
    launcherSelectionIndex = 0
    isSearching = false
    lastSearchError = nil
    statusMessage = "Ready"
  }

  private func beginSearchUI() {
    activeSearchToken += 1
    results = []
    selectedResult = nil
    previewContent = ""
    relatedResults = []
    launcherSelectionIndex = 0
    isSearching = true
    lastSearchError = nil
    statusMessage = "Searching..."
  }

  private func handleDebouncedSearchQuery(_ query: String) {
    searchTask?.cancel()
    guard query.count >= 2 else {
      clearSearchResults()
      return
    }

    beginSearchUI()
    searchTask = Task {
      await performSearch(query: query)
    }
  }

  func performSearch(query: String) async {
    guard searchReady else {
      isSearching = false
      lastSearchError = nil
      statusMessage = "Search model still loading…"
      return
    }

    searchGeneration += 1
    let generation = searchGeneration
    isSearching = true
    lastSearchError = nil
    statusMessage = "Searching..."
    do {
      var args: [String: Any] = [
        "query": query,
        "recent_items": recentItemsBridgePayload,
      ]
      if searchScopeSelectedFolder, let folder = selectedFolder {
        args["folder"] = folder
      }
      let payload: [SearchResultItem] = try await backend.requestRaw("search", args: args)
      guard !Task.isCancelled, generation == searchGeneration else { return }
      results = payload
      selectedResult = nil
      previewContent = ""
      relatedResults = []
      launcherSelectionIndex = 0
      isSearching = false
      lastSearchError = nil
      let scopeNote: String = {
        guard searchScopeSelectedFolder, let folder = selectedFolder else { return "" }
        return " in \(folderStore.displayName(for: folder))"
      }()
      statusMessage = "Found \(results.count) result\(results.count == 1 ? "" : "s")\(scopeNote)"
      Task {
        try? await backend.requestVoid("recent_searches", args: ["add": query])
        await refreshRecentSearchesFromBackend()
      }
    } catch {
      guard !Task.isCancelled, generation == searchGeneration else { return }
      isSearching = false
      lastSearchError = error.localizedDescription
      statusMessage = "Search failed"
    }
  }

  func retryLastSearch() async {
    searchTask?.cancel()
    lastSearchError = nil
    if !backendReady || !searchReady {
      await recoverBackend()
    }
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return }
    guard searchReady else { return }
    beginSearchUI()
    await performSearch(query: trimmed)
  }

  func clearActiveFilter() {
    activeFilter = .all
  }

  func clearSearchScope() {
    searchScopeSelectedFolder = false
  }

  /// Index a specific folder from Settings without requiring prior sidebar selection.
  func indexFolder(_ folder: String, force: Bool = false) {
    selectedFolder = folder
    indexFolders([folder], force: force, showStatus: true)
  }

  func toggleSearchScopeSelectedFolder() {
    guard selectedFolder != nil else { return }
    searchScopeSelectedFolder.toggle()
  }

  func selectResult(_ item: SearchResultItem) async {
    selectedResult = item
    if let index = filteredResults.firstIndex(where: { $0.id == item.id }) {
      launcherSelectionIndex = index
    }
    guard appMode == .workspace else { return }
    await loadSelectionDetails(for: item)
  }

  func selectLauncherItem(at index: Int) {
    guard filteredResults.indices.contains(index) else { return }
    launcherSelectionIndex = index
    selectedResult = filteredResults[index]
  }

  func moveLauncherSelection(delta: Int) {
    guard !filteredResults.isEmpty else { return }
    let next = min(max(launcherSelectionIndex + delta, 0), filteredResults.count - 1)
    launcherSelectionIndex = next
    selectedResult = filteredResults[next]
    guard appMode == .workspace else { return }
    Task { await loadSelectionDetails(for: filteredResults[next]) }
  }

  func activateLauncherSelection() {
    guard filteredResults.indices.contains(launcherSelectionIndex) else { return }
    selectedResult = filteredResults[launcherSelectionIndex]
    openSelectedResult()
  }

  func runSearch(_ query: String) {
    searchQuery = query
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else {
      clearSearchResults()
      return
    }
    beginSearchUI()
    searchTask = Task {
      await performSearch(query: trimmed)
    }
  }

  func saveCurrentSearch(name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, query.count >= 2 else { return }
    folderStore.addSavedSearchLocally(SavedSearch(name: trimmed, query: query))
    Task {
      try? await backend.requestVoid("saved_searches", args: ["name": trimmed, "query": query])
      await refreshSavedSearchesFromBackend()
    }
  }

  func deleteSavedSearch(_ search: SavedSearch) {
    folderStore.removeSavedSearchLocally(search.name)
    Task {
      try? await backend.requestVoid("saved_searches", args: ["delete": search.name])
      await refreshSavedSearchesFromBackend()
    }
  }

  func deleteRecentSearch(_ query: String) {
    folderStore.removeRecentSearchLocally(query)
    Task {
      struct RecentResponse: Decodable {
        let searches: [String]
      }
      do {
        let response: RecentResponse = try await backend.requestValue(
          "recent_searches",
          args: ["delete": query]
        )
        folderStore.applyRecentSearches(response.searches)
      } catch {
        await refreshRecentSearchesFromBackend()
      }
    }
  }

  func loadDuplicates() async {
    guard searchReady else {
      statusMessage = "Search model still loading… try Find Duplicates again when Ready"
      backendError = """
      Duplicate scan needs the search model to be ready.

      Wait for status Ready, or use Retry if the backend failed to start.
      """
      return
    }
    isLoadingDuplicates = true
    duplicateGroups = []
    showDuplicateSheet = true
    do {
      let response: DuplicateGroupsResponse = try await backend.requestValue("duplicates")
      duplicateGroups = response.groups
    } catch {
      backendError = error.localizedDescription
      showDuplicateSheet = false
    }
    isLoadingDuplicates = false
  }

  func cancelIndexing() {
    writeCancelFlag()
    Task { try? await backend.requestVoid("cancel_index") }
    resetIndexProgressState(cancelPolling: true)
    statusMessage = "Indexing cancelled"
  }

  private func writeCancelFlag() {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".aether/index_cancel.flag")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
  }

  private func applyIndexProgress(_ userInfo: [AnyHashable: Any]?) {
    guard isIndexing, let userInfo else { return }
    let current = userInfo["current"] as? Int ?? 0
    let total = max(userInfo["total"] as? Int ?? 1, 1)
    let file = userInfo["file"] as? String ?? ""
    indexProgressCurrent = current
    indexProgressTotal = total
    if file.isEmpty {
      statusMessage = "Indexing \(current)/\(total)…"
    } else {
      statusMessage = "Indexing \(current)/\(total) · \(file)"
    }
  }

  private func loadRelated(for path: String) async {
    guard searchReady else { return }
    do {
      let payload: [SearchResultItem] = try await backend.requestRaw("related", args: ["path": path, "limit": 6])
      relatedResults = payload
    } catch {
      relatedResults = []
    }
  }

  func previewFile(at path: String) async {
    let fileName = (path as NSString).lastPathComponent
    selectedResult = SearchResultItem(
      path: path,
      fileName: fileName,
      chunkId: 0,
      content: "",
      finalScore: 0,
      matchSnippet: nil
    )
    await loadPreview(for: path, fallbackContent: "")
  }

  func openFile(at path: String) {
    guard FileManager.default.fileExists(atPath: path) else { return }
    rememberOpenedPath(path)
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  private func loadSelectionDetails(for item: SearchResultItem) async {
    await loadPreview(for: item.path, fallbackContent: item.content)
    Task { await loadRelated(for: item.path) }
  }

  private func loadPreview(for path: String, fallbackContent: String) async {
    do {
      struct PreviewResponse: Decodable { let content: String }
      let response: PreviewResponse = try await backend.requestValue("preview", args: ["path": path])
      previewContent = response.content
    } catch {
      previewContent = fallbackContent
    }
  }

  func addFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add Folder"
    guard panel.runModal() == .OK else { return }

    addFolders(at: panel.urls)
  }

  func addFolders(at urls: [URL]) {
    let added = urls.compactMap { registerFolder(at: $0) }
    guard let last = added.last else { return }

    selectedFolder = last
    if added.count == 1 {
      statusMessage = "Added \(folderStore.displayName(for: last))"
    } else {
      statusMessage = "Added \(added.count) folders"
    }

    Task {
      for path in added {
        try? await backend.requestVoid("save_folder", args: ["folder": path])
        await refreshFolderStats(path)
      }
      await refreshConfigFromBackend()
      if liveSyncEnabled { restartWatcher() }
    }
  }

  func addDroppedFolders(_ providers: [NSItemProvider]) async {
    var urls: [URL] = []
    for provider in providers {
      if let url = await loadFolderURL(from: provider) {
        urls.append(url)
      }
    }
    guard !urls.isEmpty else { return }
    addFolders(at: urls)
  }

  @discardableResult
  private func registerFolder(at url: URL) -> String? {
    var isDirectory: ObjCBool = false
    let path = url.path
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else { return nil }

    _ = url.startAccessingSecurityScopedResource()
    defer { url.stopAccessingSecurityScopedResource() }

    let before = Set(folderStore.folders)
    folderStore.addFolderLocally(path)
    folderStore.beginAccess(for: path)
    return Set(folderStore.folders).subtracting(before).first
  }

  private func loadFolderURL(from provider: NSItemProvider) async -> URL? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }

    return await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        continuation.resume(returning: Self.folderURL(from: item))
      }
    }
  }

  nonisolated private static func folderURL(from item: NSSecureCoding?) -> URL? {
    let url: URL?
    if let direct = item as? URL {
      url = direct
    } else if let data = item as? Data {
      url = URL(dataRepresentation: data, relativeTo: nil)
    } else if let string = item as? NSString {
      url = URL(fileURLWithPath: string as String)
    } else {
      return nil
    }

    guard let url else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else { return nil }
    return url
  }

  func removeSelectedFolder() async {
    guard let folder = selectedFolder else { return }
    do {
      try await backend.requestVoid("delete_folder", args: ["folder": folder])
      try await backend.requestVoid("remove_folder", args: ["folder": folder])
      folderStore.removeFolderLocally(folder)
      folderStats.removeValue(forKey: folder)
      selectedFolder = folderStore.folders.first
      statusMessage = "Removed \(folderStore.displayName(for: folder))"
      if liveSyncEnabled { restartWatcher() }
    } catch {
      backendError = error.localizedDescription
    }
  }

  func indexSelectedFolder(force: Bool = false) {
    guard let folder = selectedFolder else {
      backendError = "Select a folder from the list first."
      return
    }
    indexFolders([folder], force: force, showStatus: true)
  }

  func indexAllFolders(force: Bool = false) {
    indexFolders(folderStore.folders.filter { FileManager.default.fileExists(atPath: $0) }, force: force, showStatus: true)
  }

  func toggleLiveSync() {
    if liveSyncEnabled {
      watcher.stop()
      liveSyncEnabled = false
      statusMessage = "Live sync stopped"
    } else {
      let folders = folderStore.folders.filter { FileManager.default.fileExists(atPath: $0) }
      guard !folders.isEmpty else {
        backendError = "Add folders before enabling live sync."
        return
      }
      restartWatcher()
      liveSyncEnabled = true
      statusMessage = "Live sync active for \(folders.count) folder(s)"
    }
  }

  func openSelectedResult() {
    guard let path = selectedResult?.path, FileManager.default.fileExists(atPath: path) else { return }
    rememberOpenedPath(path)
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  var isQuickLookOpen: Bool {
    quickLookPreview.isOpen
  }

  func toggleQuickLookForSelectedResult() {
    guard let path = selectedResult?.path else { return }
    quickLookPreview.toggle(path: path)
  }

  func closeQuickLook() {
    quickLookPreview.close()
  }

  func revealSelectedResult() {
    guard let path = selectedResult?.path, FileManager.default.fileExists(atPath: path) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  func copySelectedPath() {
    guard let path = selectedResult?.path else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
    statusMessage = "Path copied"
  }

  func copySelectedSnippet() {
    guard let item = selectedResult else { return }
    let snippet = item.matchSnippet ?? item.content
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(snippet, forType: .string)
    statusMessage = "Snippet copied"
  }

  private func startBackend(warmupInBackground: Bool = false) async {
    isStartingBackend = true
    searchReady = false
    statusMessage = "Starting backend…"

    do {
      let _: OKResponse = try await backend.request("ping")
      backendReady = true
      statusMessage = "Loading search model…"
      isStartingBackend = false

      if warmupInBackground {
        Task { await completeModelWarmup() }
      } else {
        await completeModelWarmup()
      }
    } catch {
      backendReady = false
      searchReady = false
      isStartingBackend = false
      backendError = Self.backendFailureMessage(for: error)
      statusMessage = "Backend unavailable - use Retry"
    }
  }

  private func completeModelWarmup() async {
    struct WarmupResponse: Decodable {
      let ready: Bool
      let cached: Bool?
    }

    do {
      let response: WarmupResponse = try await backend.requestValue("warmup")
      searchReady = true
      if response.cached == true {
        statusMessage = "Ready"
      } else {
        statusMessage = "Ready · model cached for next launch"
      }
      if appMode == .launcher {
        requestSearchFocus()
      }
    } catch {
      searchReady = false
      backendError = Self.backendFailureMessage(for: error)
      statusMessage = "Search model unavailable - use Retry"
    }
  }

  private func waitForSearchReady(timeoutSeconds: Double) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !searchReady, Date() < deadline {
      if backendError != nil { return }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  private static func backendFailureMessage(for error: Error) -> String {
    let description = error.localizedDescription
    let lower = description.lowercased()
    let alreadyActionable = lower.contains("retry")
    if alreadyActionable {
      return description
    }
    if lower.contains("timed out") || lower.contains("timeout") {
      return """
      \(description)

      Model download or warmup may have stalled. Stay online for the first model \
      download, then use Retry to restart the backend.
      """
    }
    if lower.contains("offline")
      || lower.contains("connection")
      || lower.contains("huggingface")
      || lower.contains("hf_hub")
      || lower.contains("network")
    {
      return """
      \(description)

      Connect to the internet for the first search-model download, run \
      ./Scripts/setup-backend.sh if needed, then use Retry.
      """
    }
    if lower.contains("not available") || lower.contains("python") {
      return """
      \(description)

      Use Retry after fixing the Python setup above.
      """
    }
    return """
    \(description)

    Use Retry to restart the backend.
    """
  }

  private func refreshConfigFromBackend() async {
    struct ConfigResponse: Decodable {
      let folders: [String]
      let recentSearches: [String]
      let savedSearches: [SavedSearch]
      let excludedDirNames: [String]?

      enum CodingKeys: String, CodingKey {
        case folders
        case recentSearches = "recent_searches"
        case savedSearches = "saved_searches"
        case excludedDirNames = "excluded_dir_names"
      }
    }

    if let response: ConfigResponse = try? await backend.requestValue("load_config") {
      folderStore.applyFromBackend(
        folders: response.folders,
        recent: response.recentSearches,
        saved: response.savedSearches
      )
      if let remoteExcludes = response.excludedDirNames {
        let normalized = ExcludePathStore.normalize(remoteExcludes)
        excludedDirNames = normalized
        ExcludePathStore.save(normalized)
      } else {
        await pushExcludesToBackend()
      }
      if selectedFolder == nil {
        selectedFolder = folderStore.folders.first
      }
    }
  }

  private func pushExcludesToBackend() async {
    try? await backend.requestVoid(
      "save_excluded_dirs",
      args: ["names": excludedDirNames]
    )
  }

  private func refreshRecentSearchesFromBackend() async {
    struct RecentResponse: Decodable { let searches: [String] }
    if let response: RecentResponse = try? await backend.requestValue("recent_searches") {
      folderStore.applyRecentSearches(response.searches)
    }
  }

  private func refreshSavedSearchesFromBackend() async {
    struct SavedResponse: Decodable { let searches: [SavedSearch] }
    if let response: SavedResponse = try? await backend.requestValue("saved_searches") {
      folderStore.applySavedSearches(response.searches)
    }
  }

  func refreshAllFolderStats() async {
    var updated = folderStats
    for folder in folderStore.folders {
      if let stats: FolderStats = try? await backend.requestValue("folder_stats", args: ["folder": folder]) {
        updated[folder] = stats
      }
    }
    folderStats = updated
  }

  private func refreshFolderStats(_ folder: String) async {
    if let stats: FolderStats = try? await backend.requestValue("folder_stats", args: ["folder": folder]) {
      folderStats[folder] = stats
    }
  }

  private func indexMissingFolders() async {
    var missing: [String] = []
    for folder in folderStore.folders where FileManager.default.fileExists(atPath: folder) {
      struct IndexedResponse: Decodable { let indexed: Bool }
      if let response: IndexedResponse = try? await backend.requestValue("folder_is_indexed", args: ["folder": folder]),
         !response.indexed
      {
        missing.append(folder)
      }
    }
    guard !missing.isEmpty else { return }
    indexFolders(missing, force: false, showStatus: false)
  }

  private struct AsyncIndexAck: Decodable {
    let started: Bool
    let isAsync: Bool?

    enum CodingKeys: String, CodingKey {
      case started
      case isAsync = "async"
    }
  }

  private struct IndexStatusResponse: Decodable {
    let active: Bool
    let done: Bool
    let result: IndexStats?
    let error: String?
  }

  private func indexFolders(_ folders: [String], force: Bool, showStatus: Bool) {
    guard !folders.isEmpty else {
      backendError = "Add at least one folder first."
      return
    }

    indexSession += 1
    let session = indexSession
    indexTask?.cancel()
    isIndexing = true
    indexInFlight = true
    indexProgressCurrent = 0
    indexProgressTotal = 0
    if showStatus {
      statusMessage = folders.count == 1 ? "Indexing…" : "Indexing \(folders.count) folder(s)…"
    }

    indexTask = Task {
      do {
        let _: AsyncIndexAck
        if folders.count == 1 {
          _ = try await backend.requestValue(
            "index_folder",
            args: ["folder": folders[0], "force": force]
          ) as AsyncIndexAck
        } else {
          _ = try await backend.requestValue(
            "index_all",
            args: ["folders": folders, "force": force]
          ) as AsyncIndexAck
        }

        let stats = try await pollIndexStatus()
        guard !Task.isCancelled, session == indexSession else { return }
        isIndexing = false
        indexInFlight = false
        indexProgressCurrent = 0
        indexProgressTotal = 0
        statusMessage = formatIndexMessage(stats)
        if indexNotificationsEnabled {
          notify(title: "Aether", message: statusMessage)
        }
        await refreshAllFolderStats()
      } catch {
        guard session == indexSession else { return }
        isIndexing = false
        indexProgressCurrent = 0
        indexProgressTotal = 0
        guard !Task.isCancelled else { return }
        if error.localizedDescription.localizedCaseInsensitiveContains("cancel") {
          indexInFlight = false
          statusMessage = "Indexing cancelled"
        } else if error.localizedDescription.localizedCaseInsensitiveContains("exited unexpectedly") {
          // Leave indexInFlight set so recoverBackend can offer re-index messaging.
          statusMessage = "Backend restarted - indexing may be incomplete"
        } else {
          indexInFlight = false
          backendError = error.localizedDescription
          statusMessage = "Indexing failed"
        }
      }
    }
  }

  private func pollIndexStatus() async throws -> IndexStats {
    while true {
      try Task.checkCancellation()
      let status: IndexStatusResponse = try await backend.requestValue("index_status")
      if status.done {
        if let error = status.error, !error.isEmpty {
          if error.localizedCaseInsensitiveContains("cancel") {
            throw BackendError.serverError("Indexing cancelled")
          }
          throw BackendError.serverError(error)
        }
        return status.result ?? IndexStats(chunks: 0, updated: 0, removed: 0, skipped: 0, failed: 0)
      }
      try await Task.sleep(for: .milliseconds(400))
    }
  }

  private func restartWatcher() {
    watcher.stop()
    watcher.start(folders: folderStore.folders) { [weak self] path, event in
      guard let self else { return }
      Task { await self.handleWatcherEvent(path: path, event: event) }
    }
  }

  private func handleWatcherEvent(path: String, event: FileWatcherService.WatcherEvent) async {
    switch event {
    case .modified:
      _ = try? await backend.requestValue("index_file", args: ["path": path]) as [String: Int]
    case .deleted:
      try? await backend.requestVoid("delete_file", args: ["path": path])
    case .moved(let from, let to):
      try? await backend.requestVoid("delete_file", args: ["path": from])
      _ = try? await backend.requestValue("index_file", args: ["path": to]) as [String: Int]
    }
    if let folder = selectedFolder {
      await refreshFolderStats(folder)
    }
  }

  private func formatIndexMessage(_ stats: IndexStats) -> String {
    var parts = ["\(stats.chunks) chunks indexed"]
    if stats.updated > 0 { parts.append("\(stats.updated) updated") }
    if stats.skipped > 0 { parts.append("\(stats.skipped) unchanged") }
    if stats.removed > 0 { parts.append("\(stats.removed) removed") }
    var message = parts.joined(separator: ", ")
    if stats.failed > 0 {
      message += " · \(stats.failed) file\(stats.failed == 1 ? "" : "s") skipped"
    }
    return message
  }

  private func notify(title: String, message: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = message
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }
}

import UserNotifications
