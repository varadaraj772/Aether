import Foundation

enum BackendLocator {
  struct BackendPaths {
    let python: String
    let bridge: String
  }

  static func locate() -> BackendPaths? {
    let fm = FileManager.default
    let env = ProcessInfo.processInfo.environment

    if let customPython = env["AETHER_PYTHON"], fm.isExecutableFile(atPath: customPython),
       let bridge = findBridge(near: customPython) ?? findBridgePath()
    {
      return BackendPaths(python: customPython, bridge: bridge)
    }

    guard let bridge = findBridgePath() else { return nil }

    if let bundledPython = bundledPythonPath(relativeTo: bridge),
       fm.isExecutableFile(atPath: bundledPython)
    {
      return BackendPaths(python: bundledPython, bridge: bridge)
    }

    if let devPython = developmentPythonPath(), fm.isExecutableFile(atPath: devPython) {
      return BackendPaths(python: devPython, bridge: bridge)
    }

    let systemCandidates = [
      "/opt/homebrew/bin/python3",
      "/usr/local/bin/python3",
      "/usr/bin/python3",
    ]
    if let python = systemCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
      return BackendPaths(python: python, bridge: bridge)
    }

    return nil
  }

  static var setupInstructions: String {
    """
    Set up the Python backend once:

    cd \(projectRoot.path)
    ./Scripts/setup-backend.sh

    Then run Aether from Xcode or set:
    AETHER_PYTHON=\(projectRoot.path)/Backend/venv/bin/python3
    """
  }

  private static var projectRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func findBridgePath() -> String? {
    let fm = FileManager.default
    let candidates: [String] = [
      Bundle.main.resourceURL?.appendingPathComponent("Backend/bridge.py").path,
      projectRoot.appendingPathComponent("Backend/bridge.py").path,
      Bundle.main.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("Backend/bridge.py")
        .path,
    ].compactMap { $0 }

    return candidates.first { fm.fileExists(atPath: $0) }
  }

  private static func developmentPythonPath() -> String? {
    projectRoot.appendingPathComponent("Backend/venv/bin/python3").path
  }

  private static func bundledPythonPath(relativeTo bridge: String) -> String? {
    let backendDir = (bridge as NSString).deletingLastPathComponent
    let siblingVenv = (backendDir as NSString).appendingPathComponent("venv/bin/python3")
    if FileManager.default.isExecutableFile(atPath: siblingVenv) {
      return siblingVenv
    }

    let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
    let devVenv = appDir.appendingPathComponent("Backend/venv/bin/python3").path
    return devVenv
  }

  private static func findBridge(near python: String) -> String? {
    let bin = (python as NSString).deletingLastPathComponent
    let venv = (bin as NSString).deletingLastPathComponent
    let backend = (venv as NSString).deletingLastPathComponent
    let bridge = (backend as NSString).appendingPathComponent("bridge.py")
    return FileManager.default.fileExists(atPath: bridge) ? bridge : nil
  }
}
