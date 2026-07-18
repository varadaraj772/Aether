import Foundation

enum ExcludePathStore {
  static let defaultsKey = "excludedDirNames"

  static let defaultExcludes: [String] = [
    ".git",
    ".svn",
    ".hg",
    "node_modules",
    "__pycache__",
    ".venv",
    "venv",
    "dist",
    "build",
    ".cache",
    ".Trash",
    ".idea",
    ".cursor",
    "site-packages",
  ]

  nonisolated static func load() -> [String] {
    guard let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else {
      return defaultExcludes
    }
    return normalize(stored)
  }

  nonisolated static func save(_ names: [String]) {
    UserDefaults.standard.set(normalize(names), forKey: defaultsKey)
  }

  nonisolated static func restoreDefaults() -> [String] {
    save(defaultExcludes)
    return defaultExcludes
  }

  nonisolated static func normalize(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for raw in names {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      result.append(trimmed)
    }
    return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// True if any path component equals an exclude name, or the path ends with an exclude suffix.
  nonisolated static func shouldSkip(path: String, excludes: [String]) -> Bool {
    guard !excludes.isEmpty else { return false }
    let normalized = (path as NSString).standardizingPath
    let parts = normalized.split(separator: "/").map(String.init)
    for exclude in excludes {
      let needle = exclude.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !needle.isEmpty else { continue }
      if parts.contains(where: { $0.caseInsensitiveCompare(needle) == .orderedSame }) {
        return true
      }
      if normalized.lowercased().hasSuffix("/" + needle.lowercased())
          || normalized.caseInsensitiveCompare(needle) == .orderedSame
      {
        return true
      }
    }
    return false
  }

  nonisolated static func shouldSkipDirectoryName(_ name: String, excludes: [String]) -> Bool {
    excludes.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
  }
}
