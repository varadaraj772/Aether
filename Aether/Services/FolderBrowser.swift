import Foundation

struct FolderEntry: Identifiable, Hashable {
  let path: String
  let name: String
  let isDirectory: Bool
  let fileSize: Int64?
  let modifiedDate: Date?

  var id: String { path }

  nonisolated init(path: String, name: String, isDirectory: Bool, fileSize: Int64? = nil, modifiedDate: Date? = nil) {
    self.path = path
    self.name = name
    self.isDirectory = isDirectory
    self.fileSize = fileSize
    self.modifiedDate = modifiedDate
  }
}

enum FolderBrowser {
  nonisolated static func list(path: String, sort: BrowseSortMode = .name) -> [FolderEntry] {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return []
    }

    guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
    let excludes = ExcludePathStore.load()

    var entries: [FolderEntry] = []
    for name in names where !name.hasPrefix(".") {
      if ExcludePathStore.shouldSkipDirectoryName(name, excludes: excludes) { continue }
      let fullPath = (path as NSString).appendingPathComponent(name)
      if ExcludePathStore.shouldSkip(path: fullPath, excludes: excludes) { continue }
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
      let attrs = try? fm.attributesOfItem(atPath: fullPath)
      entries.append(FolderEntry(
        path: fullPath,
        name: name,
        isDirectory: isDir.boolValue,
        fileSize: attrs?[.size] as? Int64,
        modifiedDate: attrs?[.modificationDate] as? Date
      ))
    }

    return sortEntries(entries, by: sort)
  }

  nonisolated static func sortEntries(_ entries: [FolderEntry], by sort: BrowseSortMode) -> [FolderEntry] {
    entries.sorted { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
      switch sort {
      case .name:
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      case .date:
        return (lhs.modifiedDate ?? .distantPast) > (rhs.modifiedDate ?? .distantPast)
      case .size:
        return (lhs.fileSize ?? 0) > (rhs.fileSize ?? 0)
      case .kind:
        let le = (lhs.path as NSString).pathExtension.lowercased()
        let re = (rhs.path as NSString).pathExtension.lowercased()
        if le != re { return le.localizedCaseInsensitiveCompare(re) == .orderedAscending }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
    }
  }

  static func breadcrumbs(for path: String, root: String?) -> [String] {
    guard let root else { return [path] }
    var crumbs: [String] = []
    var current = path
    while current.hasPrefix(root), current.count >= root.count {
      crumbs.insert(current, at: 0)
      if current == root { break }
      current = (current as NSString).deletingLastPathComponent
    }
    return crumbs
  }

  static func formatSize(_ size: Int64?) -> String {
    guard let size else { return "-" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: size)
  }
}
