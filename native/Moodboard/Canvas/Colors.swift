import AppKit

extension ComponentStatus {
  /// The words under a card in Grid: its one mark, then whether it has a note.
  static func attributed(_ status: ComponentStatus, in appearance: NSAppearance) -> NSAttributedString? {
    let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    // A text layer doesn't draw in the view's appearance, so it needs the colour already worked out.
    let fixed = { (color: NSColor) -> NSColor in
      var resolved = color
      appearance.performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: color.cgColor) ?? color }
      return resolved
    }
    let text = NSMutableAttributedString()
    if status.hasNote {
      text.append(NSAttributedString(string: status.mark == nil ? "Note" : "Note  ", attributes: [.font: font, .foregroundColor: fixed(.secondaryLabelColor)]))
    }
    if let mark = status.mark {
      text.append(NSAttributedString(string: mark.label, attributes: [.font: font, .foregroundColor: fixed(mark.tone.color)]))
    }
    return text.length == 0 ? nil : text
  }
}

extension ComponentStatus.Tone {
  var color: NSColor {
    switch self {
    case .attention: .systemOrange
    case .accent: .controlAccentColor
    case .done: .systemGreen
    }
  }
}

enum Palette {
  static let wall = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.075, green: 0.082, blue: 0.09, alpha: 1)
      : NSColor(srgbRed: 0.957, green: 0.961, blue: 0.945, alpha: 1)
  }
}
