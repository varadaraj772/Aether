import SwiftUI
import UserNotifications

@main
struct AetherApp: App {
  @StateObject private var appState = AppState()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(appState)
    }
    .defaultSize(width: 1280, height: 820)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Search") {
        Button("Toggle Launcher") { appState.toggleWindow() }
          .keyboardShortcut(" ", modifiers: [.command, .shift])
        Button("Back to Launcher") {
          if appState.isQuickLookOpen {
            appState.closeQuickLook()
          } else {
            appState.openLauncher()
          }
        }
          .keyboardShortcut(.escape, modifiers: [])
        Button("Open Workspace") { appState.openWorkspace() }
          .keyboardShortcut("o", modifiers: [.command, .shift])
        Button("Find Duplicates") { Task { await appState.loadDuplicates() } }
        Button("Privacy") { appState.showPrivacySheet = true }
      }
    }

    Settings {
      SettingsView()
        .environmentObject(appState)
        .onChange(of: appState.autoIndexOnLaunch) { _, value in
          UserDefaults.standard.set(value, forKey: "autoIndexOnLaunch")
        }
        .onChange(of: appState.indexNotificationsEnabled) { _, value in
          UserDefaults.standard.set(value, forKey: "indexNotificationsEnabled")
          if value {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
          }
        }
    }
  }
}
