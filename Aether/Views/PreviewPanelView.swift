import SwiftUI

struct PreviewPanelView: View {
  @EnvironmentObject private var appState: AppState
  @State private var hoveredRelatedID: String?

  var body: some View {
    GlassPanel {
      VStack(alignment: .leading, spacing: 10) {
        header

        Group {
          if let item = appState.selectedResult {
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                Text(item.fileName)
                  .font(.system(size: 15, weight: .semibold))
                  .foregroundStyle(appState.colors.title)
                  .accessibilityAddTraits(.isHeader)

                Text(item.path)
                  .font(.system(size: 10, design: .monospaced))
                  .foregroundStyle(.tertiary)
                  .textSelection(.enabled)
                  .accessibilityLabel("File path")
                  .accessibilityValue(item.path)

                previewBody(for: item)

                if !appState.relatedResults.isEmpty {
                  relatedSection
                }
              }
            }
          } else {
            EmptyStateView(
              systemImage: "doc.text.magnifyingglass",
              title: "No selection",
              message: "Select a result to preview"
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var header: some View {
    HStack {
      Text("Preview")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer()
      if appState.selectedResult != nil {
        HStack(spacing: 2) {
          ToolbarIconButton(
            systemImage: "eye",
            help: "Quick Look · Space"
          ) { appState.toggleQuickLookForSelectedResult() }
          .accessibilityLabel("Quick Look")
          .accessibilityHint("Previews the selected file. Keyboard shortcut: Space")

          ToolbarIconButton(
            systemImage: "arrow.up.forward.square",
            help: "Open file in default app"
          ) { appState.openSelectedResult() }
          .accessibilityLabel("Open in default app")
          ToolbarIconButton(
            systemImage: "folder",
            help: "Reveal in Finder"
          ) { appState.revealSelectedResult() }
          .accessibilityLabel("Reveal in Finder")
          ToolbarIconButton(
            systemImage: "doc.on.doc",
            help: "Copy file path to clipboard"
          ) { appState.copySelectedPath() }
          .accessibilityLabel("Copy file path")
        }
      }
    }
  }

  private var relatedSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("RELATED")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.tertiary)
        .kerning(0.8)

      ForEach(appState.relatedResults) { item in
        Button {
          Task { await appState.selectResult(item) }
        } label: {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.fileName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appState.colors.title)
                .lineLimit(1)
              Text(item.displaySnippet)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(item.relevancePercent)%")
              .font(.system(size: 10))
              .foregroundStyle(.tertiary)
              .monospacedDigit()
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(
            hoveredRelatedID == item.id
              ? Color.primary.opacity(0.08)
              : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: GlassMetrics.rowRadius)
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.fileName), \(item.relevancePercent) percent match")
        .accessibilityHint("Selects this related result for preview")
        .onHover { hovering in
          hoveredRelatedID = hovering ? item.id : (hoveredRelatedID == item.id ? nil : hoveredRelatedID)
        }
      }
    }
    .padding(.top, 4)
  }

  @ViewBuilder
  private func previewBody(for item: SearchResultItem) -> some View {
    let ext = (item.path as NSString).pathExtension.lowercased()
    let isImage = ["png", "jpg", "jpeg"].contains(ext) && FileManager.default.fileExists(atPath: item.path)
    let text = previewText
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    if isImage {
      AsyncImage(url: URL(fileURLWithPath: item.path)) { phase in
        if case .success(let image) = phase {
          image
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
              RoundedRectangle(cornerRadius: 10)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityLabel("Preview of \(item.fileName)")
        }
      }

      if !hasText {
        Text("No text extracted")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .padding(.top, 2)
      }
    }

    if hasText {
      HighlightedText(
        text: text,
        query: appState.searchQuery,
        font: .system(size: 12, design: .monospaced),
        highlightColor: appState.colors.accent
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var previewText: String {
    let content = appState.previewContent.isEmpty
      ? (appState.selectedResult?.content ?? "")
      : appState.previewContent
    return String(content.prefix(8000))
  }
}
