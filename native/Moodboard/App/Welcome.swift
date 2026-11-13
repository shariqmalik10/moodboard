import AppKit
import SwiftUI

/// What the first launch checks and offers, so a new person knows what works before they start.
@Observable
final class WelcomeModel {
  enum Node: Equatable { case checking, ready(String), tooOld(String), missing }
  enum Claude: Equatable { case checking, missing, notAdded, adding, added, failed(String) }
  enum Demo: Equatable { case idle, copying, failed(String) }

  var node = Node.checking
  var claude = Claude.checking
  var demo = Demo.idle

  var canRunProjects: Bool {
    if case .ready = node { return true }
    return false
  }
}

enum Shell {
  /// Runs a command in a login shell, where the person's own PATH finds `node` and `claude`.
  nonisolated static func run(_ command: String, _ arguments: [String] = []) async -> (status: Int32, output: String) {
    await Task.detached {
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(filePath: "/bin/zsh")
      process.arguments = ["-lc", command, "zsh"] + arguments
      process.standardOutput = output
      process.standardError = output
      process.standardInput = FileHandle.nullDevice
      do {
        try process.run()
      } catch {
        return (127, error.localizedDescription)
      }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }.value
  }
}

/// The sheet a new person sees first. It comes back from Help > Welcome to Moodboard.
final class WelcomeController {
  private unowned let app: AppModel
  private let state = WelcomeModel()
  private var panel: NSPanel?
  static let marker = Paths.support.appending(path: "welcomed")
  static let demoFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Moodboard Demo", directoryHint: .isDirectory)

  init(app: AppModel) {
    self.app = app
  }

  /// Shows the sheet on a first launch. Someone who already has things on the wall has started already.
  func showIfFirstLaunch() {
    guard !FileManager.default.fileExists(atPath: Self.marker.path) else { return }
    let hasSomething = app.store?.items.values.contains { $0.isComponent } == true || !ProjectCatalog.projects.isEmpty
    if hasSomething { return markSeen() }
    show()
  }

  func show() {
    guard panel == nil else { return }
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.contentView = NSHostingView(rootView: WelcomeView(
      state: state,
      onDemo: { [weak self] in self?.tryDemo() },
      onConnect: { [weak self] in self?.connectOwn() },
      onClaude: { [weak self] in self?.addToClaude() },
      onNode: { NSWorkspace.shared.open(URL(string: "https://nodejs.org/en/download")!) },
      onStart: { [weak self] in self?.close() }
    ))
    self.panel = panel
    app.window.beginSheet(panel)
    Task { await check() }
  }

  private func close() {
    markSeen()
    guard let panel else { return }
    app.window.endSheet(panel)
    self.panel = nil
  }

  private func markSeen() {
    FileManager.default.createFile(atPath: Self.marker.path, contents: Data())
  }

  private func check() async {
    state.node = .checking
    state.claude = .checking
    switch await NodeCheck.check() {
    case .ready(let version): state.node = .ready(version)
    case .tooOld(let version): state.node = .tooOld(version)
    case .missing: state.node = .missing
    }
    let claude = await Shell.run("command -v claude")
    if claude.status != 0 {
      state.claude = .missing
    } else {
      state.claude = await Shell.run("claude mcp get moodboard").status == 0 ? .added : .notAdded
    }
  }

  /// Copies the Greenhouse demo to the person's home folder, where they can edit it, and connects it.
  private func tryDemo() {
    guard let bundled = Bundle.main.resourceURL?.appending(path: "demo", directoryHint: .isDirectory) else { return }
    state.demo = .copying
    let folder = Self.demoFolder
    Task {
      let copied: String? = await Task.detached {
        let files = FileManager.default
        if files.fileExists(atPath: folder.path) {
          let manifest = (try? Data(contentsOf: folder.appending(path: "package.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
          return manifest?["name"] as? String == "greenhouse" ? nil : "\(folder.path) already exists and isn't the demo. Move it, then try again."
        }
        do {
          try files.copyItem(at: bundled, to: folder)
          return nil
        } catch {
          return error.localizedDescription
        }
      }.value
      if let copied {
        state.demo = .failed(copied)
        return
      }
      do {
        try await app.projects.connect(folder)
        state.demo = .idle
        close()
        app.chrome?.say("Greenhouse is joining the wall. Edit a file in ~/Moodboard Demo/src/components and watch its tile change.")
      } catch {
        state.demo = .failed(error.localizedDescription)
      }
    }
  }

  private func connectOwn() {
    close()
    app.connector.choose()
  }

  private func addToClaude() {
    guard let executable = Bundle.main.executableURL?.path else { return }
    state.claude = .adding
    Task {
      let added = await Shell.run("claude mcp add -s user moodboard -- \"$1\" --mcp", [executable])
      state.claude = added.status == 0 ? .added : .failed(added.output.split(separator: "\n").last.map(String.init) ?? "claude mcp add failed.")
    }
  }
}

struct WelcomeView: View {
  let state: WelcomeModel
  let onDemo: () -> Void
  let onConnect: () -> Void
  let onClaude: () -> Void
  let onNode: () -> Void
  let onStart: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Welcome to Moodboard").font(.system(size: 22, weight: .semibold))
          Text("A wall of your components, running live. Edit the code and its tile changes. Move a dial and the code changes.")
            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        MiniWall().frame(width: 96, height: 64)
      }
      .padding(EdgeInsets(top: 28, leading: 24, bottom: 20, trailing: 24))
      Divider()
      VStack(alignment: .leading, spacing: 18) {
        step(1, "Node", node.detail) { node.trailing }
        step(2, "Something for the wall", "Start with the Greenhouse demo, a small Next.js app copied to ~/Moodboard Demo, or connect one of your own.") {
          EmptyView()
        }
        HStack(spacing: 8) {
          Button(action: onDemo) {
            HStack(spacing: 6) {
              if state.demo == .copying { ProgressView().controlSize(.small) }
              Text("Try the Greenhouse demo")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!state.canRunProjects || state.demo == .copying)
          Button("Connect a project…", action: onConnect).disabled(!state.canRunProjects)
        }
        .padding(.leading, 36)
        if case .failed(let reason) = state.demo {
          Text(reason).font(.system(size: 12)).foregroundStyle(.orange).padding(.leading, 36).fixedSize(horizontal: false, vertical: true)
        }
        step(3, "Claude Code, if you use it", claude.detail) { claude.trailing }
      }
      .padding(24)
      Divider()
      HStack {
        Text("Paper is optional too. With a file open in Paper, import frames from the bar.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Button("Start", action: onStart).keyboardShortcut(.defaultAction)
      }
      .padding(EdgeInsets(top: 14, leading: 24, bottom: 16, trailing: 24))
    }
    .frame(width: 560)
  }

  private func step(_ number: Int, _ title: String, _ detail: String, @ViewBuilder trailing: () -> some View) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .frame(width: 24, height: 24)
        .background(Circle().fill(.quaternary))
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      trailing()
    }
  }

  private var node: (detail: String, trailing: AnyView) {
    switch state.node {
    case .checking:
      return ("Looking for Node…", AnyView(ProgressView().controlSize(.small)))
    case .ready(let version):
      return ("Node \(version) runs your projects.", AnyView(Mark(ok: true)))
    case .tooOld(let version):
      return ("Node \(version) is too old. Projects need 20.19 or newer.", AnyView(Button("Get Node", action: onNode)))
    case .missing:
      return ("Moodboard runs projects with Node 20.19 or newer, and couldn't find it.", AnyView(Button("Get Node", action: onNode)))
    }
  }

  private var claude: (detail: String, trailing: AnyView) {
    switch state.claude {
    case .checking:
      return ("Looking for Claude Code…", AnyView(ProgressView().controlSize(.small)))
    case .missing:
      return ("Install Claude Code to ask for changes by name, and to send a tuned component back to your code.", AnyView(EmptyView()))
    case .notAdded:
      return ("Lets Claude Code see the wall, open components and set their dials.", AnyView(Button("Add to Claude Code", action: onClaude)))
    case .adding:
      return ("Adding Moodboard to Claude Code…", AnyView(ProgressView().controlSize(.small)))
    case .added:
      return ("Claude Code can see the wall.", AnyView(Mark(ok: true)))
    case .failed(let reason):
      return (reason, AnyView(Button("Try again", action: onClaude)))
    }
  }
}

private struct Mark: View {
  let ok: Bool
  var body: some View {
    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
      .font(.system(size: 18))
      .foregroundStyle(ok ? .green : .orange)
      .accessibilityLabel(ok ? "Ready" : "Needs attention")
  }
}

/// Six tiles settling into three columns, the way the wall forms as you scroll onto it.
private struct MiniWall: View {
  @State private var formed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let columns: [[CGFloat]] = [[30, 26], [20, 36], [34, 22]]

  var body: some View {
    HStack(alignment: .top, spacing: 4) {
      ForEach(columns.indices, id: \.self) { column in
        VStack(spacing: 4) {
          ForEach(columns[column].indices, id: \.self) { row in
            RoundedRectangle(cornerRadius: 4)
              .fill(.tertiary)
              .frame(height: columns[column][row])
              .opacity(formed ? 1 : 0)
              .scaleEffect(formed ? 1 : 0.86)
              .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0).delay(Double(column * 2 + row) * 0.08), value: formed)
          }
        }
      }
    }
    .onAppear { formed = true }
    .accessibilityHidden(true)
  }
}
