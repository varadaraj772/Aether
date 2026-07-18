import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
  var appMode: AppMode
  var isDark: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    scheduleConfigure(for: view, mode: appMode, isDark: isDark)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    scheduleConfigure(for: nsView, mode: appMode, isDark: isDark)
  }

  private func scheduleConfigure(for view: NSView, mode: AppMode, isDark: Bool) {
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      configure(window, mode: mode, isDark: isDark)
    }
  }

  private func configure(_ window: NSWindow, mode: AppMode, isDark: Bool) {
    window.isOpaque = false
    window.hasShadow = false
    clearViewBackgrounds(window.contentView)

    switch mode {
    case .launcher:
      window.styleMask = [.borderless, .fullSizeContentView]
      window.level = .floating
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      window.isMovable = false
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.standardWindowButton(.closeButton)?.isHidden = true
      window.standardWindowButton(.miniaturizeButton)?.isHidden = true
      window.standardWindowButton(.zoomButton)?.isHidden = true

      window.backgroundColor = NSColor.black.withAlphaComponent(isDark ? 0.42 : 0.28)

      if let frame = (window.screen ?? NSScreen.main)?.visibleFrame {
        window.setFrame(frame, display: true)
      }

    case .workspace:
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      window.level = .normal
      window.collectionBehavior = [.managed, .participatesInCycle]
      window.isMovable = true
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.isMovableByWindowBackground = true
      window.minSize = NSSize(width: 1100, height: 700)
      window.hasShadow = true
      window.backgroundColor = .clear
      window.standardWindowButton(.closeButton)?.isHidden = false
      window.standardWindowButton(.miniaturizeButton)?.isHidden = false
      window.standardWindowButton(.zoomButton)?.isHidden = false
    }

    clearViewBackgrounds(window.contentView)
  }

  private func clearViewBackgrounds(_ view: NSView?) {
    guard let view else { return }
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    view.subviews.forEach { clearViewBackgrounds($0) }
  }

  final class Coordinator {}
}
