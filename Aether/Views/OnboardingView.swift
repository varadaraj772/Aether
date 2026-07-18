import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var appState: AppState

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 14) {
        Image(systemName: "sparkle.magnifyingglass")
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 48, height: 48)
          .background(.primary.opacity(0.06), in: Circle())

        VStack(alignment: .leading, spacing: 4) {
          Text("Welcome to Aether")
            .font(.title2.bold())
          Text("Local semantic search for your files. Nothing leaves your Mac.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 16) {
        onboardingStep("1", "Add folders", "Drop folders into the sidebar or use Add folder.")
        onboardingStep("2", "Index", "Aether reads file content locally to enable meaning-based search.")
        onboardingStep("3", "Search", "Press ⌘⇧Space for the launcher, or type in the workspace search bar.")
      }
      .padding(.vertical, 4)

      VStack(alignment: .leading, spacing: 6) {
        Toggle("Automatically index new folders on launch", isOn: $appState.autoIndexOnLaunch)
          .toggleStyle(.switch)

        Text("You can change this later in Settings.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      HStack {
        Button("Add a folder") {
          appState.completeOnboarding()
          appState.addFolder()
        }
        .buttonStyle(.bordered)

        Spacer()

        Button("Get started") {
          appState.completeOnboarding()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
      .padding(.top, 4)
    }
    .padding(32)
    .frame(width: 500)
  }

  private func onboardingStep(_ number: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(number)
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .background(.primary.opacity(0.06), in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
        Text(detail)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var appState: AppState

  private static let lastIndexedFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  var body: some View {
    Form {
      Section {
        Toggle("Automatically index new folders on launch", isOn: $appState.autoIndexOnLaunch)
        Text("When enabled, Aether indexes any folders that are not yet indexed after startup.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Indexing")
      }

      Section {
        if appState.folderStore.folders.isEmpty {
          Text("Add a folder in the workspace to see index health.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(appState.folderStore.folders, id: \.self) { folder in
            folderHealthRow(folder)
          }
        }

        Button {
          Task { await appState.refreshFolderHealth() }
        } label: {
          if appState.isRefreshingFolderHealth {
            Label("Refreshing…", systemImage: "arrow.triangle.2.circlepath")
          } else {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        }
        .disabled(appState.isRefreshingFolderHealth || !appState.backendReady)
      } header: {
        Text("Index health")
      } footer: {
        Text("Shows whether each folder is indexed, plus file/chunk counts and last index time when available.")
      }

      Section {
        ForEach(appState.excludedDirNames, id: \.self) { name in
          HStack {
            Text(name)
              .font(.system(.body, design: .monospaced))
            Spacer()
            Button(role: .destructive) {
              appState.removeExcludePath(name)
            } label: {
              Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove exclude")
          }
        }

        HStack {
          TextField("Directory name or path suffix", text: $appState.newExcludeDraft)
            .onSubmit { appState.addExcludePath(appState.newExcludeDraft) }
          Button("Add") {
            appState.addExcludePath(appState.newExcludeDraft)
          }
          .disabled(appState.newExcludeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Button("Restore defaults") {
          appState.restoreDefaultExcludes()
        }
      } header: {
        Text("Excluded paths")
      } footer: {
        Text("Skip directories whose name matches, or whose path ends with, these values during browse and indexing.")
      }

      Section {
        Toggle("Notify when indexing completes", isOn: $appState.indexNotificationsEnabled)
        Text("Shows a system notification when a folder finishes indexing.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Notifications")
      }

      Section("Backend") {
        if appState.searchReady {
          Label("Search ready", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else if appState.isStartingBackend {
          Label(appState.statusMessage, systemImage: "arrow.triangle.2.circlepath")
        } else {
          Label("Backend unavailable", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Button("Retry backend") {
            Task { await appState.recoverBackend() }
          }
        }

        Text(BackendLocator.setupInstructions)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Section("Privacy") {
        Text("All indexing and search runs locally. Data is stored in ~/.aether")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 480, idealWidth: 520, minHeight: 560)
  }

  @ViewBuilder
  private func folderHealthRow(_ folder: String) -> some View {
    let stats = appState.folderStats[folder]
    let indexed = stats?.indexed == true
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(appState.folderStore.displayName(for: folder))
          .font(.headline)
        Spacer()
        Text(indexed ? "Indexed" : "Not indexed")
          .font(.caption.weight(.semibold))
          .foregroundStyle(indexed ? .green : .orange)
      }
      Text(folder)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      HStack(spacing: 12) {
        Label("\(stats?.fileCount ?? 0) files", systemImage: "doc")
        Label("\(stats?.chunkCount ?? 0) chunks", systemImage: "square.stack.3d.up")
        if let formatted = formatLastIndexed(stats?.lastIndexed) {
          Label(formatted, systemImage: "clock")
        }
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 2)
  }

  private func formatLastIndexed(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
      return Self.lastIndexedFormatter.string(from: date)
    }
    return raw
  }
}
