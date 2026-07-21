import SwiftUI

enum FileTypeFilter: String, CaseIterable, Identifiable {
    case all, docs, code, data, images

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .docs: "Documents"
        case .code: "Code"
        case .data: "Data"
        case .images: "Images"
        }
    }

    func matches(fileName: String) -> Bool {
        guard self != .all else { return true }
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch self {
        case .docs:
            return ["pdf", "docx", "pages", "xlsx", "pptx", "txt", "md", "rtf", "eml"].contains(ext)
        case .code:
            return [
                "py", "swift", "js", "ts", "tsx", "jsx", "html", "css", "rs", "go", "java", "kt",
                "c", "cpp", "h", "hpp", "m", "mm", "rb", "php", "sh", "yaml", "yml", "toml",
                "xml", "sql", "r", "scala", "vue", "svelte", "json", "md", "txt",
            ].contains(ext)
        case .data:
            return ["csv", "log", "json", "tsv", "parquet"].contains(ext)
        case .images:
            return ["png", "jpg", "jpeg"].contains(ext)
        case .all:
            return true
        }
    }
}

enum SortMode: String, CaseIterable, Identifiable {
    case relevance, name, date

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: "Relevance"
        case .name: "Name A-Z"
        case .date: "Date modified"
        }
    }
}

enum AppMode: String {
    case launcher
    case workspace
}

enum BrowseSortMode: String, CaseIterable, Identifiable {
    case name, date, size, kind

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .date: "Date"
        case .size: "Size"
        case .kind: "Kind"
        }
    }
}

struct SavedSearch: Identifiable, Codable, Hashable {
    let name: String
    let query: String

    var id: String { name }
}

struct RecentOpenedItem: Identifiable, Codable, Hashable {
    let path: String
    var openCount: Int
    var lastOpenedAt: Date

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case openCount = "open_count"
        case lastOpenedAt = "last_opened_at"
    }

    func bridgePayload() -> [String: Any] {
        [
            "path": path,
            "open_count": openCount,
            "last_opened_at": lastOpenedAt.timeIntervalSince1970,
        ]
    }
}

struct DuplicateFile: Identifiable, Codable, Hashable {
    let path: String
    let fileName: String

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case fileName = "file_name"
    }
}

struct DuplicateGroup: Identifiable, Codable, Hashable {
    let kind: String
    let similarity: Double
    let files: [DuplicateFile]

    var id: String { files.map(\.path).sorted().joined(separator: "|") }

    var title: String {
        kind == "exact" ? "Exact duplicate" : "Near duplicate"
    }
}

struct DuplicateGroupsResponse: Codable {
    let groups: [DuplicateGroup]
}

enum SmartCollection: String, CaseIterable, Identifiable {
    case all, recent, large, unindexed, documents, images

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All folders"
        case .recent: "Recently modified"
        case .large: "Large files"
        case .unindexed: "Not indexed"
        case .documents: "Documents"
        case .images: "Images"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "folder"
        case .recent: "clock"
        case .large: "externaldrive"
        case .unindexed: "exclamationmark.triangle"
        case .documents: "doc.text"
        case .images: "photo"
        }
    }
}

struct SearchResultItem: Identifiable, Hashable, Codable {
    var id: String { "\(path)-\(chunkId)" }
    let path: String
    let fileName: String
    let chunkId: Int
    let content: String
    let finalScore: Double
    let matchSnippet: String?

    enum CodingKeys: String, CodingKey {
        case path
        case fileName = "file_name"
        case chunkId = "chunk_id"
        case content
        case finalScore = "final_score"
        case matchSnippet = "match_snippet"
    }

    init(path: String, fileName: String, chunkId: Int, content: String, finalScore: Double, matchSnippet: String?) {
        self.path = path
        self.fileName = fileName
        self.chunkId = chunkId
        self.content = content
        self.finalScore = finalScore
        self.matchSnippet = matchSnippet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        fileName = try container.decode(String.self, forKey: .fileName)
        chunkId = try container.decodeIfPresent(Int.self, forKey: .chunkId) ?? 0
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        finalScore = try container.decodeIfPresent(Double.self, forKey: .finalScore) ?? 0
        matchSnippet = try container.decodeIfPresent(String.self, forKey: .matchSnippet)
    }

    var relevancePercent: Int {
        Int(finalScore * 100)
    }

    var displaySnippet: String {
        if let matchSnippet, !matchSnippet.isEmpty {
            return matchSnippet
        }
        return String(content.prefix(130)).replacingOccurrences(of: "\n", with: " ")
    }
}

struct FolderStats: Codable {
    let indexed: Bool
    let fileCount: Int
    let chunkCount: Int
    let lastIndexed: String?

    enum CodingKeys: String, CodingKey {
        case indexed
        case fileCount = "file_count"
        case chunkCount = "chunk_count"
        case lastIndexed = "last_indexed"
    }

    init(indexed: Bool, fileCount: Int, chunkCount: Int, lastIndexed: String? = nil) {
        self.indexed = indexed
        self.fileCount = fileCount
        self.chunkCount = chunkCount
        self.lastIndexed = lastIndexed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        indexed = try container.decode(Bool.self, forKey: .indexed)
        fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        chunkCount = try container.decodeIfPresent(Int.self, forKey: .chunkCount) ?? 0
        lastIndexed = try container.decodeIfPresent(String.self, forKey: .lastIndexed)
    }
}

struct IndexStats: Codable {
    let chunks: Int
    let updated: Int
    let removed: Int
    let skipped: Int
    let failed: Int
    let failedSample: [String]

    init(
        chunks: Int,
        updated: Int,
        removed: Int,
        skipped: Int,
        failed: Int = 0,
        failedSample: [String] = []
    ) {
        self.chunks = chunks
        self.updated = updated
        self.removed = removed
        self.skipped = skipped
        self.failed = failed
        self.failedSample = failedSample
    }

    enum CodingKeys: String, CodingKey {
        case chunks, updated, removed, skipped, failed
        case failedSample = "failed_sample"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chunks = try container.decodeIfPresent(Int.self, forKey: .chunks) ?? 0
        updated = try container.decodeIfPresent(Int.self, forKey: .updated) ?? 0
        removed = try container.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        skipped = try container.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        failed = try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        failedSample = try container.decodeIfPresent([String].self, forKey: .failedSample) ?? []
    }
}

struct ExtMeta {
    let tag: String
    let color: Color
}

enum ExtMetaLookup {
    private static let table: [String: (String, Color)] = [
        "pdf": ("PDF", Color(red: 1, green: 0.27, blue: 0.23)),
        "docx": ("DOC", Color(red: 0.04, green: 0.52, blue: 1)),
        "pages": ("PAGES", Color(red: 1, green: 0.62, blue: 0.04)),
        "xlsx": ("XLS", Color(red: 0.19, green: 0.82, blue: 0.35)),
        "pptx": ("PPT", Color(red: 1, green: 0.39, blue: 0.51)),
        "txt": ("TXT", Color(red: 0.6, green: 0.6, blue: 0.62)),
        "md": ("MD", Color(red: 0.39, green: 0.82, blue: 1)),
        "json": ("JSON", Color(red: 1, green: 0.84, blue: 0.04)),
        "py": ("PY", Color(red: 0.37, green: 0.36, blue: 0.9)),
        "swift": ("SWIFT", Color(red: 1, green: 0.45, blue: 0.2)),
        "js": ("JS", Color(red: 0.94, green: 0.86, blue: 0.22)),
        "ts": ("TS", Color(red: 0.24, green: 0.47, blue: 0.85)),
        "tsx": ("TSX", Color(red: 0.24, green: 0.47, blue: 0.85)),
        "jsx": ("JSX", Color(red: 0.38, green: 0.75, blue: 0.9)),
        "html": ("HTML", Color(red: 0.9, green: 0.35, blue: 0.2)),
        "css": ("CSS", Color(red: 0.2, green: 0.55, blue: 0.9)),
        "rs": ("RS", Color(red: 0.85, green: 0.35, blue: 0.2)),
        "go": ("GO", Color(red: 0.3, green: 0.75, blue: 0.85)),
        "java": ("JAVA", Color(red: 0.9, green: 0.45, blue: 0.15)),
        "rb": ("RB", Color(red: 0.8, green: 0.2, blue: 0.2)),
        "sh": ("SH", Color(red: 0.45, green: 0.75, blue: 0.35)),
        "yaml": ("YAML", Color(red: 0.75, green: 0.4, blue: 0.6)),
        "yml": ("YAML", Color(red: 0.75, green: 0.4, blue: 0.6)),
        "toml": ("TOML", Color(red: 0.6, green: 0.5, blue: 0.8)),
        "sql": ("SQL", Color(red: 0.35, green: 0.55, blue: 0.85)),
        "csv": ("CSV", Color(red: 0.19, green: 0.82, blue: 0.35)),
        "log": ("LOG", Color(red: 0.6, green: 0.6, blue: 0.62)),
        "eml": ("EML", Color(red: 0.55, green: 0.55, blue: 0.7)),
        "png": ("IMG", Color(red: 0.75, green: 0.35, blue: 0.95)),
        "jpg": ("IMG", Color(red: 0.75, green: 0.35, blue: 0.95)),
        "jpeg": ("IMG", Color(red: 0.75, green: 0.35, blue: 0.95)),
    ]

    static func meta(for fileName: String) -> ExtMeta {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let entry = table[ext] ?? ("FILE", Color(red: 0.39, green: 0.39, blue: 0.4))
        return ExtMeta(tag: entry.0, color: entry.1)
    }
}
