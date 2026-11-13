import AppKit
import SwiftUI

/// The notes of the release a person just updated to, shown once on its first launch. They are the
/// release's description on GitHub, so they are written once, when the release is published.
final class WhatsNewController {
  enum Block: Equatable {
    case heading(String), bullet(String), paragraph(String)
  }

  /// Reads release-note Markdown into the few shapes notes use. Inline Markdown stays for the view.
  static func blocks(_ notes: String) -> [Block] {
    notes.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").compactMap { raw in
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { return nil }
      if line.hasPrefix("#") { return .heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
      if ["- ", "* ", "+ "].contains(where: line.hasPrefix) { return .bullet(String(line.dropFirst(2))) }
      return .paragraph(line)
    }
  }

  private static let seenKey = "MoodboardSeenVersion"
  private let window: NSWindow
  private var panel: NSPanel?

  init(window: NSWindow) {
    self.window = window
  }

  /// Shows the notes on the first launch of a newer version. Someone new gets the welcome instead.
  /// A version counts as seen only once its notes arrive, so a launch without a network tries again next time.
  func showIfUpdated(isNewPerson: Bool) {
    #if !DEBUG
      guard let running = Updater.Version.running, !UserDefaults.standard.bool(forKey: "MoodboardRecording") else { return }
      if isNewPerson { return markSeen(running) }
      if let seen = UserDefaults.standard.string(forKey: Self.seenKey).flatMap(Updater.Version.init), !(seen < running) { return }
      Task {
        guard let release = try? await Updater.Release.fetch("tags/v\(running)") else { return }
        markSeen(running)
        if !release.notes.isEmpty { present(release) }
      }
    #endif
  }

  /// Help > What's New in Moodboard.
  func show() {
    guard panel == nil, let running = Updater.Version.running else { return }
    Task {
      do {
        present(try await Updater.Release.fetch("tags/v\(running)"))
      } catch {
        let alert = NSAlert()
        alert.messageText = "The notes for Moodboard \(running) aren't available."
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window, completionHandler: nil)
      }
    }
  }

  private func markSeen(_ version: Updater.Version) {
    UserDefaults.standard.set(version.description, forKey: Self.seenKey)
  }

  private func present(_ release: Updater.Release) {
    guard panel == nil else { return }
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.contentView = NSHostingView(rootView: WhatsNewView(
      version: release.version.description,
      blocks: Self.blocks(release.notes),
      onPage: { NSWorkspace.shared.open(release.page) },
      onClose: { [weak self] in self?.close() }
    ))
    self.panel = panel
    window.beginSheet(panel)
  }

  private func close() {
    guard let panel else { return }
    window.endSheet(panel)
    self.panel = nil
  }
}

struct WhatsNewView: View {
  let version: String
  let blocks: [WhatsNewController.Block]
  let onPage: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("What's New").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        Text("Moodboard \(version)").font(.system(size: 22, weight: .semibold))
      }
      .padding(EdgeInsets(top: 28, leading: 24, bottom: 20, trailing: 24))
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if blocks.isEmpty {
            Text("This release has no notes.").font(.system(size: 13)).foregroundStyle(.secondary)
          }
          ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            row(block)
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 300)
      Divider()
      HStack {
        Button("Release Page", action: onPage)
        Spacer()
        Button("Continue", action: onClose).keyboardShortcut(.defaultAction)
      }
      .padding(EdgeInsets(top: 14, leading: 24, bottom: 16, trailing: 24))
    }
    .frame(width: 520)
  }

  @ViewBuilder private func row(_ block: WhatsNewController.Block) -> some View {
    switch block {
    case .heading(let text):
      Text(inline(text)).font(.system(size: 14, weight: .semibold)).padding(.top, 4)
    case .bullet(let text):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("•").foregroundStyle(.secondary)
        Text(inline(text)).fixedSize(horizontal: false, vertical: true)
      }
      .font(.system(size: 13))
    case .paragraph(let text):
      Text(inline(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
  }
}
