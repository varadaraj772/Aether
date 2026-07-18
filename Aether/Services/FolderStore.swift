import Foundation
import AppKit
import Combine

@MainActor
final class FolderStore: ObservableObject {
  @Published private(set) var folders: [String] = []
  @Published private(set) var recentSearches: [String] = []
  @Published private(set) var savedSearches: [SavedSearch] = []

  private let bookmarkAccess = BookmarkAccessManager()

  init() {
    bookmarkAccess.restoreAccess(for: folders)
  }

  func applyFromBackend(folders backendFolders: [String], recent: [String], saved: [SavedSearch]) {
    folders = backendFolders.map(normalize)
    recentSearches = recent
    savedSearches = saved
    bookmarkAccess.restoreAccess(for: folders)
  }

  func addFolderLocally(_ folder: String) {
    let normalized = normalize(folder)
    guard !folders.contains(normalized) else { return }
    folders.append(normalized)
    bookmarkAccess.storeBookmark(for: normalized)
  }

  func removeFolderLocally(_ folder: String) {
    let normalized = normalize(folder)
    folders.removeAll { $0 == normalized }
    bookmarkAccess.removeBookmark(for: normalized)
  }

  func applyRecentSearches(_ searches: [String]) {
    recentSearches = searches
  }

  func removeRecentSearchLocally(_ query: String) {
    recentSearches.removeAll { $0 == query }
  }

  func applySavedSearches(_ searches: [SavedSearch]) {
    savedSearches = searches
  }

  func addSavedSearchLocally(_ search: SavedSearch) {
    savedSearches.removeAll { $0.name == search.name }
    savedSearches.insert(search, at: 0)
    if savedSearches.count > 20 {
      savedSearches = Array(savedSearches.prefix(20))
    }
  }

  func removeSavedSearchLocally(_ name: String) {
    savedSearches.removeAll { $0.name == name }
  }

  func displayName(for folder: String) -> String {
    let normalized = normalize(folder)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if normalized == home { return "~" }
    if normalized.hasPrefix(home + "/") {
      return "~" + normalized.dropFirst(home.count)
    }
    return normalized
  }

  func folderHint(for path: String) -> String {
    displayName(for: (path as NSString).deletingLastPathComponent)
  }

  func beginAccess(for path: String) {
    bookmarkAccess.beginAccess(for: path)
  }

  private func normalize(_ folder: String) -> String {
    var path = (folder as NSString).standardizingPath
    while path.hasSuffix("/"), path.count > 1 {
      path.removeLast()
    }
    return path
  }
}

@MainActor
final class BookmarkAccessManager {
  private let bookmarksKey = "folder_bookmarks"
  private var activeURLs: [String: URL] = [:]

  func storeBookmark(for path: String) {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard url.startAccessingSecurityScopedResource() else { return }
    defer { url.stopAccessingSecurityScopedResource() }

    do {
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
      bookmarks[path] = bookmark
      UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
      beginAccess(for: path)
    } catch {
      // Bookmarking is best-effort.
    }
  }

  func removeBookmark(for path: String) {
    endAccess(for: path)
    var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
    bookmarks.removeValue(forKey: path)
    UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
  }

  func restoreAccess(for paths: [String]) {
    guard let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] else {
      return
    }

    let relevant = Set(paths)
    for path in relevant {
      guard let data = bookmarks[path] else { continue }
      var stale = false
      guard let url = try? URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      ) else { continue }

      if stale {
        storeBookmark(for: path)
        continue
      }
      beginAccess(for: path, url: url)
    }
  }

  func beginAccess(for path: String, url: URL? = nil) {
    if activeURLs[path] != nil { return }

    let resolved: URL
    if let url {
      resolved = url
    } else if let data = (UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data])?[path] {
      var stale = false
      guard let bookmarkURL = try? URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      ) else { return }
      if stale {
        storeBookmark(for: path)
        return
      }
      resolved = bookmarkURL
    } else {
      resolved = URL(fileURLWithPath: path, isDirectory: true)
    }

    if resolved.startAccessingSecurityScopedResource() {
      activeURLs[path] = resolved
    }
  }

  func endAccess(for path: String) {
    guard let url = activeURLs.removeValue(forKey: path) else { return }
    url.stopAccessingSecurityScopedResource()
  }
}
