import AppKit

/// A folder holding several apps, so the person has to say which.
struct SeveralApps: LocalizedError {
  var folder: URL
  var apps: [URL]

  func label(_ app: URL) -> String { String(app.path.dropFirst(folder.standardizedFileURL.resolvingSymlinksInPath().path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
  var errorDescription: String? { "\(folder.lastPathComponent) holds several Next.js apps: \(apps.map(label).joined(separator: ", ")). Connect one of them by its folder." }
}

/// Connecting a project from the window: the folder picker, and the sheets that answer when a folder can't join.
final class ProjectConnector {
  private unowned let app: AppModel

  init(app: AppModel) {
    self.app = app
  }

  /// Opens where the last project was, since the next one is usually beside it.
  func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Connect"
    panel.message = "Choose a Next.js app, a folder inside one, or a monorepo. Its components join the wall, and moving a dial edits their source files."
    if let last = ProjectCatalog.projects.last { panel.directoryURL = URL(filePath: last.root, directoryHint: .isDirectory).deletingLastPathComponent() }
    panel.beginSheetModal(for: app.window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated { self?.connectAsked(url) }
    }
  }

  /// Connects a folder the person picked or dropped, and answers in a sheet when it can't.
  func connectAsked(_ url: URL) {
    Task {
      do {
        let connection = try await app.projects.connect(url)
        if !connection.isNew {
          app.show(.wall, filter: .project(connection.project.slug))
          app.chrome?.say("\(connection.project.name) is already connected.")
        } else if let note = connection.note {
          app.chrome?.say(note)
        }
      } catch let several as SeveralApps {
        pickApp(several)
      } catch {
        explain(error.localizedDescription)
      }
    }
  }

  private func pickApp(_ several: SeveralApps) {
    let alert = NSAlert()
    alert.messageText = "Which app should join the wall?"
    alert.informativeText = "\(several.folder.lastPathComponent) holds \(several.apps.count) Next.js apps. Connect one now, and the others the same way later."
    let shown = Array(several.apps.prefix(3))
    for app in shown { alert.addButton(withTitle: several.label(app)) }
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: app.window) { [weak self] response in
      let at = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
      guard at >= 0, at < shown.count else { return }
      MainActor.assumeIsolated { self?.connectAsked(shown[at]) }
    }
  }

  private func explain(_ problem: String) {
    let alert = NSAlert()
    alert.messageText = "This folder can't join the wall"
    alert.informativeText = problem
    alert.addButton(withTitle: "Choose Another…")
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: app.window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      MainActor.assumeIsolated { self?.choose() }
    }
  }
}
