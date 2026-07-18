import SwiftUI

struct HighlightedText: View {
  let text: String
  let query: String
  var font: Font = .system(size: 12, design: .monospaced)
  var highlightColor: Color = .accentColor

  var body: some View {
    Text(attributedString)
      .font(font)
      .textSelection(.enabled)
  }

  private var attributedString: AttributedString {
    var result = AttributedString(text)
    let terms = query
      .split(whereSeparator: \.isWhitespace)
      .map { String($0) }
      .filter { $0.count >= 2 }

    for term in terms {
      var searchStart = text.startIndex
      while searchStart < text.endIndex,
            let range = text.range(of: term, options: .caseInsensitive, range: searchStart..<text.endIndex),
            let attrRange = Range(range, in: result)
      {
        result[attrRange].backgroundColor = highlightColor.opacity(0.28)
        result[attrRange].foregroundColor = .primary
        searchStart = range.upperBound
      }
    }

    return result
  }
}
