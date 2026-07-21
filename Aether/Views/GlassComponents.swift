import SwiftUI

enum GlassMetrics {
  static let panelRadius: CGFloat = 16
  static let controlRadius: CGFloat = 10
  static let rowRadius: CGFloat = 10
}

struct GlassPanel<Content: View>: View {
  var padding: CGFloat = 14
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .glassEffect(.regular, in: .rect(cornerRadius: GlassMetrics.panelRadius))
  }
}

struct AetherSearchField: View {
  enum Style {
    case launcher
    case workspace
  }

  @Binding var text: String
  var placeholder: String
  @FocusState.Binding var focused: Bool
  var style: Style = .workspace

  private var iconSize: CGFloat { style == .launcher ? 20 : 15 }
  private var fontSize: CGFloat { style == .launcher ? 28 : 15 }
  private var fontWeight: Font.Weight { style == .launcher ? .light : .regular }
  private var horizontalPadding: CGFloat { style == .launcher ? 0 : 14 }
  private var fieldHeight: CGFloat? { style == .workspace ? 36 : nil }

  var body: some View {
    HStack(spacing: style == .launcher ? 12 : 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: iconSize, weight: .medium))
        .foregroundStyle(.secondary)

      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: fontSize, weight: fontWeight))
        .focused($focused)

      if style == .workspace, !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .frame(height: fieldHeight)
    .modifier(SearchFieldChrome(style: style))
  }

  private var verticalPadding: CGFloat { style == .launcher ? 0 : 0 }
}

private struct SearchFieldChrome: ViewModifier {
  let style: AetherSearchField.Style

  func body(content: Content) -> some View {
    if style == .workspace {
      content
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: GlassMetrics.controlRadius))
    } else {
      content
    }
  }
}

struct PanelHeader: View {
  let title: String
  var trailing: String? = nil

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
      if let trailing {
        Text(trailing)
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
    }
  }
}

struct EmptyStateView: View {
  let systemImage: String
  let title: String
  var message: String? = nil
  var actionTitle: String? = nil
  var action: (() -> Void)? = nil
  var secondaryActionTitle: String? = nil
  var secondaryAction: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(.tertiary)
        .symbolRenderingMode(.hierarchical)
        .accessibilityHidden(true)

      Text(title)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if let message {
        Text(message)
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 260)
      }

      if actionTitle != nil || secondaryActionTitle != nil {
        HStack(spacing: 8) {
          if let actionTitle, let action {
            Button(actionTitle, action: action)
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
          }
          if let secondaryActionTitle, let secondaryAction {
            Button(secondaryActionTitle, action: secondaryAction)
              .buttonStyle(.bordered)
              .controlSize(.small)
          }
        }
        .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
    .padding(.horizontal, 16)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityValue(message ?? "")
  }
}

struct ToolbarIconButton: View {
  let systemImage: String
  let help: String
  var accessibilityLabelText: String? = nil
  var isActive: Bool = false
  var activeTint: Color? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isActive ? (activeTint ?? .accentColor) : .secondary)
    .help(help)
    .accessibilityLabel(accessibilityLabelText ?? help)
  }
}

struct FileTypeBadge: View {
  let fileName: String

  var body: some View {
    let meta = ExtMetaLookup.meta(for: fileName)
    Text(meta.tag)
      .font(.system(size: 8, weight: .heavy))
      .foregroundStyle(meta.color)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(meta.color.opacity(0.14), in: Capsule())
  }
}
