import Foundation

enum SmartCollectionResolver {
  nonisolated private static let docExtensions: Set<String> = ["pdf", "docx", "pages", "xlsx", "pptx", "txt", "md"]
  nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]

  nonisolated static func items(
    for collection: SmartCollection,
    folders: [String],
    folderStats: [String: FolderStats]
  ) -> [FolderEntry] {
    switch collection {
    case .all:
      return []
    case .unindexed:
      return folders
        .filter { folderStats[$0]?.indexed != true }
        .map { FolderEntry(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: true, fileSize: nil, modifiedDate: nil) }
    case .recent, .large, .documents, .images:
      return indexedFiles(folders: folders).filter { entry in
        guard !entry.isDirectory else { return false }
        switch collection {
        case .recent:
          guard let date = entry.modifiedDate else { return false }
          return date > Date().addingTimeInterval(-7 * 24 * 3600)
        case .large:
          return (entry.fileSize ?? 0) > 10 * 1024 * 1024
        case .documents:
          return docExtensions.contains((entry.path as NSString).pathExtension.lowercased())
        case .images:
          return imageExtensions.contains((entry.path as NSString).pathExtension.lowercased())
        default:
          return false
        }
      }
    }
  }

  nonisolated private static func indexedFiles(folders: [String]) -> [FolderEntry] {
    var results: [FolderEntry] = []
    let fm = FileManager.default
    let excludes = ExcludePathStore.load()
    for folder in folders {
      guard let enumerator = fm.enumerator(atPath: folder) else { continue }
      for case let relative as String in enumerator {
        let parts = relative.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) { continue }
        let path = (folder as NSString).appendingPathComponent(relative)
        if parts.contains(where: { ExcludePathStore.shouldSkipDirectoryName($0, excludes: excludes) })
            || ExcludePathStore.shouldSkip(path: path, excludes: excludes)
        {
          var isDir: ObjCBool = false
          if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            enumerator.skipDescendants()
          }
          continue
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = attrs?[.size] as? Int64
        let modified = attrs?[.modificationDate] as? Date
        results.append(FolderEntry(
          path: path,
          name: (path as NSString).lastPathComponent,
          isDirectory: isDir.boolValue,
          fileSize: size,
          modifiedDate: modified
        ))
        if results.count > 2000 { return results }
      }
    }
    return results
  }
}
