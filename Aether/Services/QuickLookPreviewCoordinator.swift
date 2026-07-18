import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreviewCoordinator: NSObject, QLPreviewPanelDataSource {
  private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL) {
      previewItemURL = url
      previewItemTitle = url.lastPathComponent
    }
  }

  private var previewItem: PreviewItem?
  private weak var previewPanel: QLPreviewPanel?

  var isOpen: Bool {
    previewPanel?.isVisible == true
  }

  func toggle(path: String) {
    if isOpen {
      close()
      return
    }
    show(path: path)
  }

  func show(path: String) {
    guard FileManager.default.fileExists(atPath: path) else { return }

    previewItem = PreviewItem(url: URL(fileURLWithPath: path))
    guard let panel = QLPreviewPanel.shared() else { return }
    previewPanel = panel
    panel.dataSource = self
    panel.reloadData()
    panel.currentPreviewItemIndex = 0
    panel.makeKeyAndOrderFront(nil)
  }

  func close() {
    previewPanel?.orderOut(nil)
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    previewItem == nil ? 0 : 1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
    precondition(index == 0)
    guard let previewItem else {
      preconditionFailure("Quick Look requested an item before one was configured")
    }
    return previewItem
  }
}
