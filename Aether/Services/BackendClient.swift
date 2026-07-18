import Foundation

extension Notification.Name {
  static let aetherBackendTerminated = Notification.Name("aetherBackendTerminated")
  static let aetherIndexProgress = Notification.Name("aetherIndexProgress")
  static let aetherModelProgress = Notification.Name("aetherModelProgress")
}

struct OKResponse: Codable {
  let ok: Bool
}

enum BackendError: LocalizedError {
  case processUnavailable
  case invalidResponse
  case serverError(String)
  case timedOut

  var errorDescription: String? {
    switch self {
    case .processUnavailable:
      "Python backend is not available.\n\n\(BackendLocator.setupInstructions)"
    case .invalidResponse:
      "Invalid response from backend."
    case .serverError(let message):
      message
    case .timedOut:
      "Backend request timed out. Indexing or model loading may still be running.\n\nUse Retry to restart the backend."
    }
  }
}

actor BackendClient {
  static let shared = BackendClient()

  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var readTask: Task<Void, Never>?
  private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  private var buffer = ""
  private var nextID = 1
  private var recentStderr = ""
  private let maxStderrChars = 4000
  private var intentionalStop = false

  private let defaultTimeout: Duration = .seconds(120)
  private let searchTimeout: Duration = .seconds(30)

  func startIfNeeded() throws {
    if process?.isRunning == true { return }

    guard let paths = BackendLocator.locate() else {
      throw BackendError.processUnavailable
    }

    let proc = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()

    proc.executableURL = URL(fileURLWithPath: paths.python)
    proc.arguments = [paths.bridge]
    proc.standardInput = input
    proc.standardOutput = output
    proc.standardError = error
    proc.currentDirectoryURL = URL(fileURLWithPath: (paths.bridge as NSString).deletingLastPathComponent)

    var env = ProcessInfo.processInfo.environment
    env["PYTHONUNBUFFERED"] = "1"
    env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
    env["HF_HUB_DISABLE_TELEMETRY"] = "1"
    env["TRANSFORMERS_VERBOSITY"] = "error"
    env["TOKENIZERS_PARALLELISM"] = "false"
    // Prefer the local Hugging Face cache; models.py still downloads on first launch.
    if env["HF_HOME"] == nil {
      let hfHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface")
        .path
      env["HF_HOME"] = hfHome
    }
    proc.environment = env

    proc.terminationHandler = { [weak self] _ in
      Task { await self?.handleProcessTermination() }
    }

    try proc.run()

    process = proc
    inputPipe = input
    outputPipe = output
    errorPipe = error

    installOutputReader(output)
    installErrorReader(error)
  }

  func stop() {
    intentionalStop = true
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    readTask?.cancel()
    readTask = nil
    cancelPending(with: BackendError.serverError("Backend stopped."))
    if let process, process.isRunning {
      process.terminate()
    }
    process = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
    buffer = ""
    recentStderr = ""
    intentionalStop = false
  }

  func request<T: Decodable>(_ cmd: String, args: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
    let response = try await sendRequest(cmd: cmd, args: args, timeout: timeout(for: cmd))
    let responseData = try JSONSerialization.data(withJSONObject: response["data"] ?? [:])
    return try JSONDecoder().decode(T.self, from: responseData)
  }

  func requestVoid(_ cmd: String, args: [String: Any] = [:]) async throws {
    _ = try await sendRequest(cmd: cmd, args: args, timeout: timeout(for: cmd))
  }

  func requestValue<T: Decodable>(_ cmd: String, args: [String: Any] = [:]) async throws -> T {
    try await request(cmd, args: args, as: T.self)
  }

  func requestRaw<T: Decodable>(_ cmd: String, args: [String: Any] = [:]) async throws -> T {
    let response = try await sendRequest(cmd: cmd, args: args, timeout: timeout(for: cmd))
    let responseData = try JSONSerialization.data(withJSONObject: response["data"] ?? NSNull())
    return try JSONDecoder().decode(T.self, from: responseData)
  }

  private func sendRequest(cmd: String, args: [String: Any], timeout: Duration) async throws -> [String: Any] {
    try startIfNeeded()

    let id = nextID
    nextID += 1

    let payload: [String: Any] = ["id": id, "cmd": cmd, "args": args]
    let data = try JSONSerialization.data(withJSONObject: payload)
    guard var line = String(data: data, encoding: .utf8) else {
      throw BackendError.invalidResponse
    }
    line.append("\n")

    return try await withThrowingTaskGroup(of: [String: Any].self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
          Task {
            await self.enqueue(id: id, continuation: continuation, line: line)
          }
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw BackendError.timedOut
      }

      do {
        guard let response = try await group.next() else {
          throw BackendError.invalidResponse
        }
        group.cancelAll()

        guard let ok = response["ok"] as? Bool else {
          throw BackendError.invalidResponse
        }
        if !ok {
          throw BackendError.serverError(response["error"] as? String ?? "Unknown backend error")
        }
        return response
      } catch {
        group.cancelAll()
        failPending(id: id, error: error)
        throw error
      }
    }
  }

  private func enqueue(id: Int, continuation: CheckedContinuation<[String: Any], Error>, line: String) {
    pending[id] = continuation
    if let encoded = line.data(using: .utf8) {
      inputPipe?.fileHandleForWriting.write(encoded)
    } else {
      pending.removeValue(forKey: id)
      continuation.resume(throwing: BackendError.invalidResponse)
    }
  }

  private func failPending(id: Int, error: Error) {
    if let continuation = pending.removeValue(forKey: id) {
      continuation.resume(throwing: error)
    }
  }

  private func cancelPending(with error: BackendError) {
    for (_, continuation) in pending {
      continuation.resume(throwing: error)
    }
    pending.removeAll()
  }

  private func timeout(for cmd: String) -> Duration {
    switch cmd {
    case "search", "ping", "preview", "related", "index_status", "index_progress", "cancel_index":
      return searchTimeout
    case "index_folder", "index_all":
      // Async: returns immediately after spawning background worker.
      return .seconds(15)
    case "warmup":
      return .seconds(300)
    case "duplicates":
      return .seconds(600)
    default:
      return defaultTimeout
    }
  }

  private func handleProcessTermination() {
    let detail = recentStderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let message: String
    if detail.isEmpty {
      message = "Python backend exited unexpectedly."
    } else {
      let tail = String(detail.suffix(800))
      message = "Python backend exited unexpectedly.\n\n\(tail)"
    }
    cancelPending(with: BackendError.serverError(message))
    process = nil
    recentStderr = ""
    if !intentionalStop {
      Task { @MainActor in
        NotificationCenter.default.post(name: .aetherBackendTerminated, object: nil)
      }
    }
  }

  private func installOutputReader(_ pipe: Pipe) {
    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { [weak self] fh in
      let chunk = fh.availableData
      if chunk.isEmpty {
        fh.readabilityHandler = nil
        return
      }
      guard let text = String(data: chunk, encoding: .utf8) else { return }
      Task { await self?.appendOutput(text) }
    }
  }

  private func installErrorReader(_ pipe: Pipe) {
    let handle = pipe.fileHandleForReading
    handle.readabilityHandler = { [weak self] fh in
      let chunk = fh.availableData
      if chunk.isEmpty {
        fh.readabilityHandler = nil
        return
      }
      if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
        fputs("[Aether backend] \(text)", stderr)
        Task { await self?.appendStderr(text) }
        Task { @MainActor in
          Self.parseProgressLines(text)
        }
      }
    }
  }

  @MainActor
  private static func parseProgressLines(_ text: String) {
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("MODEL_PROGRESS:") {
        let stage = trimmed
          .dropFirst("MODEL_PROGRESS:".count)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stage.isEmpty else { continue }
        NotificationCenter.default.post(
          name: .aetherModelProgress,
          object: nil,
          userInfo: ["stage": stage]
        )
        continue
      }
      guard trimmed.hasPrefix("AETHER_PROGRESS:") else { continue }
      let json = trimmed.dropFirst("AETHER_PROGRESS:".count)
      guard
        let data = json.data(using: .utf8),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      NotificationCenter.default.post(name: .aetherIndexProgress, object: nil, userInfo: payload)
    }
  }

  private func appendStderr(_ text: String) {
    recentStderr += text
    if recentStderr.count > maxStderrChars {
      recentStderr = String(recentStderr.suffix(maxStderrChars))
    }
  }

  private func appendOutput(_ text: String) {
    buffer += text

    while let range = buffer.range(of: "\n") {
      let line = String(buffer[..<range.lowerBound])
      buffer = String(buffer[range.upperBound...])
      handleLine(line)
    }
  }

  private func handleLine(_ line: String) {
    guard
      let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = json["id"] as? Int,
      let continuation = pending.removeValue(forKey: id)
    else { return }

    continuation.resume(returning: json)
  }
}
