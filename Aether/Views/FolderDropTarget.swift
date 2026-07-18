import SwiftUI
import UniformTypeIdentifiers

struct FolderDropTarget: ViewModifier {
  @EnvironmentObject private var appState: AppState
  @Binding var isTargeted: Bool

  func body(content: Content) -> some View {
    content
      .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
        Task { await appState.addDroppedFolders(providers) }
        return true
      }
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: GlassMetrics.panelRadius)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: GlassMetrics.panelRadius))
            .overlay {
              Label("Drop folder to add", systemImage: "folder.badge.plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
        }
      }
  }
}

extension View {
  func folderDropTarget(isTargeted: Binding<Bool>) -> some View {
    modifier(FolderDropTarget(isTargeted: isTargeted))
  }
}
