import Foundation
import AppKit

@MainActor
final class FileWatcherService: @unchecked Sendable {
  private var streams: [FSEventStreamRef] = []
  private var lastIndexed: [String: Date] = [:]
  private let debounce: TimeInterval = 2
  private var onChange: ((String, WatcherEvent) -> Void)?

  enum WatcherEvent {
    case modified
    case deleted
    case moved(from: String, to: String)
  }

  func start(folders: [String], onChange: @escaping (String, WatcherEvent) -> Void) {
    stop()
    self.onChange = onChange

    for folder in folders where FileManager.default.fileExists(atPath: folder) {
      let path = folder as CFString
      var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(self).toOpaque(),
        retain: nil,
        release: nil,
        copyDescription: nil
      )

      let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
      )

      guard let stream = FSEventStreamCreate(
        nil,
        { _, info, numEvents, eventPaths, eventFlags, _ in
          guard let info else { return }
          let service = Unmanaged<FileWatcherService>.fromOpaque(info).takeUnretainedValue()
          Task { @MainActor in
            service.handleEvents(
              numEvents: numEvents,
              paths: eventPaths,
              flags: eventFlags
            )
          }
        },
        &context,
        [path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.3,
        flags
      ) else { continue }

      FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
      FSEventStreamStart(stream)
      streams.append(stream)
    }
  }

  func stop() {
    for stream in streams {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    streams.removeAll()
    onChange = nil
  }

  private func handleEvents(numEvents: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
    guard let onChange else { return }
    let cfPaths = unsafeBitCast(paths, to: NSArray.self)

    for index in 0..<numEvents {
      guard let path = cfPaths[index] as? String else { continue }
      let flag = flags[index]

      if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
        onChange(path, .deleted)
        continue
      }

      if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
        onChange(path, .modified)
        continue
      }

      if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 ||
        flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
      {
        guard shouldIndex(path) else { continue }
        onChange(path, .modified)
      }
    }
  }

  private func shouldIndex(_ path: String) -> Bool {
    let now = Date()
    if let last = lastIndexed[path], now.timeIntervalSince(last) < debounce {
      return false
    }
    lastIndexed[path] = now
    return true
  }
}
