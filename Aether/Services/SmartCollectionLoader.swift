import Combine
import Foundation

@MainActor
final class SmartCollectionLoader: ObservableObject {
  @Published private(set) var items: [FolderEntry] = []
  @Published private(set) var isLoading = false

  private var loadTask: Task<Void, Never>?

  func load(
    collection: SmartCollection,
    folders: [String],
    folderStats: [String: FolderStats]
  ) {
    loadTask?.cancel()

    loadTask = Task { @MainActor in
      guard collection != .all else {
        items = []
        isLoading = false
        return
      }

      isLoading = true
      let snapshotFolders = folders
      let snapshotStats = folderStats
      let entries = await Task.detached(priority: .userInitiated) {
        SmartCollectionResolver.items(
          for: collection,
          folders: snapshotFolders,
          folderStats: snapshotStats
        )
      }.value

      guard !Task.isCancelled else { return }
      items = entries
      isLoading = false
    }
  }

  func cancel() {
    loadTask?.cancel()
    loadTask = nil
    Task { @MainActor in
      isLoading = false
    }
  }
}
