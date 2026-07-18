import AppKit

@MainActor
final class StatusBarController: NSObject {
  private var statusItem: NSStatusItem?
  private weak var appState: AppState?
  private lazy var menu: NSMenu = makeMenu()

  func install(appState: AppState) {
    self.appState = appState
    guard statusItem == nil else {
      menu = makeMenu()
      return
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      let image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Aether")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "Aether - click for launcher, right-click for menu"
      button.target = self
      button.action = #selector(statusItemActivated(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    statusItem = item
    menu = makeMenu()
  }

  func uninstall() {
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    statusItem = nil
    appState = nil
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(menuItem("Show Launcher", action: #selector(showLauncher)))
    menu.addItem(menuItem("Open Workspace", action: #selector(openWorkspace)))
    menu.addItem(menuItem("Find Duplicates", action: #selector(findDuplicates)))
    menu.addItem(.separator())
    let quit = menuItem("Quit Aether", action: #selector(quitApp))
    quit.keyEquivalent = "q"
    menu.addItem(quit)
    return menu
  }

  private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func statusItemActivated(_ sender: Any?) {
    guard let event = NSApp.currentEvent else {
      appState?.toggleWindow()
      return
    }
    if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
      guard let button = statusItem?.button else { return }
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    } else {
      appState?.toggleWindow()
    }
  }

  @objc private func showLauncher() {
    appState?.openLauncher()
  }

  @objc private func openWorkspace() {
    NSApp.activate(ignoringOtherApps: true)
    appState?.openWorkspace()
    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
  }

  @objc private func findDuplicates() {
    NSApp.activate(ignoringOtherApps: true)
    appState?.openWorkspace()
    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    Task { await appState?.loadDuplicates() }
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }
}
